#!/usr/bin/env python3

from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

import yaml
from github_actions_runs import format_resolved_via, load_latest_workflow_run, load_run_from_selector
from lane_outcome_artifacts import load_lane_outcome_artifacts
from lane_categories import (
    CATEGORY_ORDER,
    build_category_counts,
    effective_lane_conclusion,
    classify_lane_category,
    total_fail_count,
)
from lane_registry import build_lane_registry
from lane_utils import DEFAULT_LANE_VARIANTS, LaneSpecError, expand_generated_lanes

API_VERSION = "2022-11-28"
DEFAULT_WORKFLOW = "pipeline-select-run-lanes.yml"
FAIL_CONCLUSIONS = {"failure", "timed_out", "action_required", "startup_failure"}
GROUP_STATE_ORDER = [
    "normal_passing",
    "normal_failing",
    "masked_ready_to_reset",
    "masked_still_failing",
]


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def normalize_job_name(name: str) -> str:
    cleaned = " ".join((name or "").strip().split())
    if not cleaned:
        return "<unnamed>"
    pieces = [piece.strip() for piece in cleaned.split(" / ") if piece.strip()]
    if len(pieces) >= 2 and pieces[0] == pieces[-1]:
        return pieces[-1]
    return cleaned


def append_details_section(markdown_lines: list[str], title: str, items: list[str]) -> None:
    if not items:
        return
    markdown_lines.extend(["", f"<details><summary>{title}</summary>", ""])
    markdown_lines.extend(items)
    markdown_lines.extend(["", "</details>"])


def normalize_variant_name(value: object, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context} must be a non-empty string")
    return value.strip()


def extract_entry_variant_specs(entry: dict, lane_file: str, include_index: int) -> dict[str, object]:
    if "variant" in entry:
        variant = normalize_variant_name(
            entry.get("variant"),
            f"{lane_file}#{include_index}.variant",
        )
        return {
            "single_variant": True,
            "had_variants_key": False,
            "specs": [
                {
                    "variant": variant,
                    "raw": dict(entry),
                }
            ],
        }

    raw_variants = entry.get("variants")
    had_variants_key = raw_variants is not None
    if raw_variants is None:
        raw_variants = list(DEFAULT_LANE_VARIANTS)
    if not isinstance(raw_variants, list) or not raw_variants:
        raise ValueError(f"{lane_file}#{include_index}.variants must be a non-empty list")

    seen_variants: set[str] = set()
    specs: list[dict[str, object]] = []
    for variant_index, raw_variant in enumerate(raw_variants):
        context = f"{lane_file}#{include_index}.variants[{variant_index}]"
        if isinstance(raw_variant, str):
            variant = normalize_variant_name(raw_variant, context)
        elif isinstance(raw_variant, dict):
            variant = normalize_variant_name(raw_variant.get("variant"), f"{context}.variant")
        else:
            raise ValueError(f"{context} must be a string or mapping")
        if variant in seen_variants:
            raise ValueError(f"{lane_file}#{include_index} defines duplicate variant '{variant}'")
        seen_variants.add(variant)
        specs.append({"variant": variant, "raw": raw_variant})

    return {
        "single_variant": False,
        "had_variants_key": had_variants_key,
        "specs": specs,
    }


def render_variant_item(
    raw_variant: object,
    variant: str,
    allow_failure: bool,
    *,
    inherit_from_entry: bool,
) -> object:
    if isinstance(raw_variant, str):
        if inherit_from_entry or not allow_failure:
            return variant
        return {"variant": variant, "allow_failure": True}

    item_data = dict(raw_variant) if isinstance(raw_variant, dict) else {"variant": variant}
    item_data.pop("variant", None)
    if inherit_from_entry:
        item_data.pop("allow_failure", None)
    elif allow_failure:
        item_data["allow_failure"] = True
    else:
        item_data.pop("allow_failure", None)

    item = {"variant": variant}
    item.update(item_data)
    if set(item.keys()) == {"variant"}:
        return variant
    return item


def apply_entry_lane_states(
    entry: dict,
    variant_specs: dict[str, object],
    desired_by_variant: dict[str, bool],
) -> None:
    specs = list(variant_specs["specs"])
    if not specs:
        return

    if variant_specs["single_variant"]:
        desired = desired_by_variant[specs[0]["variant"]]
        if desired:
            entry["allow_failure"] = True
        else:
            entry.pop("allow_failure", None)
        return

    entry.pop("allow_failure", None)
    desired_values = {desired_by_variant[spec["variant"]] for spec in specs}
    if len(desired_values) == 1:
        shared_allow_failure = desired_values.pop()

        rendered_variants = [
            render_variant_item(
                spec["raw"],
                spec["variant"],
                shared_allow_failure,
                inherit_from_entry=False,
            )
            for spec in specs
        ]
        if rendered_variants == list(DEFAULT_LANE_VARIANTS):
            entry.pop("variants", None)
        else:
            entry["variants"] = rendered_variants
        return

    entry["variants"] = [
        render_variant_item(
            spec["raw"],
            spec["variant"],
            desired_by_variant[spec["variant"]],
            inherit_from_entry=False,
        )
        for spec in specs
    ]


def classify_entry_state(entry_lanes: list[dict]) -> str:
    has_normal_failure = any((not lane["current_allow_failure"]) and lane["has_non_success"] for lane in entry_lanes)
    has_masked_failure = any(lane["current_allow_failure"] and lane["has_non_success"] for lane in entry_lanes)
    has_masked_success = any(lane["current_allow_failure"] and lane["all_success"] for lane in entry_lanes)
    if has_normal_failure:
        return "normal_failing"
    if has_masked_failure:
        return "masked_still_failing"
    if has_masked_success:
        return "masked_ready_to_reset"
    return "normal_passing"


def load_token(token_env: str) -> str:
    for env_name in [token_env, "GH_TOKEN", "GITHUB_TOKEN"]:
        if not env_name:
            continue
        token = os.environ.get(env_name, "").strip()
        if token:
            return token
    die(
        "Missing GitHub token. Set one of the following environment variables: "
        f"{token_env}, GH_TOKEN, GITHUB_TOKEN"
    )


def build_headers(repo: str, token: str) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": f"{repo}/allow-failure-reconcile",
    }


def api_get(repo: str, token: str, path: str, params: dict[str, str] | None = None) -> dict:
    base_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    url = f"{base_url}{path}"
    if params:
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
        if query:
            url = f"{url}?{query}"
    request = urllib.request.Request(url, headers=build_headers(repo, token))
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def load_run(repo: str, token: str, workflow: str, run_selector: str, branch: str, event: str) -> tuple[dict, str]:
    if run_selector:
        try:
            return load_run_from_selector(api_get, repo, token, workflow, run_selector)
        except ValueError as exc:
            die(str(exc))

    try:
        return load_latest_workflow_run(api_get, repo, token, workflow, branch, event), "latest"
    except ValueError as exc:
        die(str(exc))


def load_jobs(repo: str, token: str, run_id: int) -> list[dict]:
    jobs: list[dict] = []
    page = 1
    while True:
        payload = api_get(
            repo,
            token,
            f"/repos/{repo}/actions/runs/{run_id}/jobs",
            params={"per_page": "100", "page": str(page)},
        )
        page_jobs = payload.get("jobs", [])
        if not page_jobs:
            break
        jobs.extend(page_jobs)
        if len(page_jobs) < 100:
            break
        page += 1
    return jobs


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Reconcile lane allow_failure flags from a selector run: "
            "set allow_failure=true for failing lanes and clear it for lanes that are all-success."
        )
    )
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--run-selector", dest="run_selector", default="")
    parser.add_argument("--run-id", dest="run_selector", help=argparse.SUPPRESS)
    parser.add_argument("--branch", default="")
    parser.add_argument("--event", default="workflow_dispatch")
    parser.add_argument("--token-env", default="GH_TOKEN")
    parser.add_argument("--manifest", default="ci/run/ref/ref-families.yml")
    parser.add_argument("--platform-catalog", default="ci/deps/platform-catalog.yaml")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--markdown-output", default="")
    parser.add_argument("--json-output", default="")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument("--run-json", default="")
    parser.add_argument("--jobs-json", default="")
    return parser.parse_args()


def load_lane_file_docs(repo_root: Path, lane_files: set[str]) -> dict[str, dict]:
    docs: dict[str, dict] = {}
    for lane_file_rel in sorted(lane_files):
        path = repo_root / lane_file_rel
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if isinstance(data, dict) and "generated" in data:
            generated = data.get("generated")
            if not isinstance(generated, dict):
                raise ValueError(f"Lane file generated section must be a mapping: {lane_file_rel}")

            generated_copy = copy.deepcopy(generated)
            platforms = generated_copy.get("platforms")
            if not isinstance(platforms, list):
                raise ValueError(f"Lane file generated.platforms must be a list: {lane_file_rel}")

            for index, platform_entry in enumerate(platforms):
                if not isinstance(platform_entry, dict):
                    raise ValueError(
                        f"Lane file generated.platforms[{index}] must be a mapping: {lane_file_rel}"
                    )
                platform_entry["__generated_platform_index"] = index
                secondary_overrides = platform_entry.get("secondary_overrides")
                if secondary_overrides is None:
                    secondary_overrides = {}
                    platform_entry["secondary_overrides"] = secondary_overrides
                if not isinstance(secondary_overrides, dict):
                    raise ValueError(
                        f"Lane file generated.platforms[{index}].secondary_overrides must be a mapping: {lane_file_rel}"
                    )
                secondary_overrides["__generated_platform_index"] = index
                secondary_overrides["__generated_secondary"] = True

            try:
                expanded = expand_generated_lanes(generated_copy, path, generated_overrides={})
            except LaneSpecError as exc:
                raise ValueError(str(exc)) from exc

            include = []
            original_platforms = data["generated"]["platforms"]
            for expanded_entry in expanded:
                if not isinstance(expanded_entry, dict):
                    raise ValueError(f"Expanded lane entry must be a mapping: {lane_file_rel}")
                platform_index = expanded_entry.pop("__generated_platform_index", None)
                is_secondary = bool(expanded_entry.pop("__generated_secondary", False))
                if not isinstance(platform_index, int):
                    raise ValueError(
                        f"Expanded generated lane entry missing platform index metadata: {lane_file_rel}"
                    )
                source_platform = original_platforms[platform_index]
                target = source_platform
                if is_secondary:
                    target = source_platform.setdefault("secondary_overrides", {})
                    if not isinstance(target, dict):
                        raise ValueError(
                            f"Lane file generated.platforms[{platform_index}].secondary_overrides "
                            f"must be a mapping: {lane_file_rel}"
                        )
                include.append(
                    {
                        "entry": expanded_entry,
                        "generated": True,
                        "target": target,
                        "platform": source_platform,
                        "is_secondary": is_secondary,
                    }
                )
        else:
            include = None
            if isinstance(data, dict):
                include = data.get("include", data.get("lanes"))
            elif isinstance(data, list):
                include = data
            if not isinstance(include, list):
                raise ValueError(f"Lane file include section must be a list: {lane_file_rel}")
            include = [{"entry": entry, "generated": False, "target": entry} for entry in include]
        docs[lane_file_rel] = {"path": path, "data": data, "include": include}
    return docs


def write_lane_file(path: Path, data: object) -> None:
    rendered = yaml.safe_dump(data, sort_keys=False)
    path.write_text(rendered, encoding="utf-8")


def load_fixture(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def load_fixture_jobs(path: str) -> list[dict]:
    payload = load_fixture(path)
    if isinstance(payload, dict) and "jobs" in payload:
        payload = payload["jobs"]
    if not isinstance(payload, list):
        die(f"Jobs fixture is not a list: {path}")
    return payload


def main() -> None:
    args = parse_args()
    if not args.repo:
        die("Missing --repo and GITHUB_REPOSITORY is not set")

    fixture_mode = bool(args.run_json or args.jobs_json)
    if fixture_mode and not (args.run_json and args.jobs_json):
        die("Fixture mode requires both --run-json and --jobs-json")

    if fixture_mode:
        run = load_fixture(args.run_json)
        jobs = load_fixture_jobs(args.jobs_json)
        resolved_via = "fixture"
        lane_outcome_report = {"artifact_count": 0, "records": {}, "unreadable_artifacts": []}
    else:
        token = load_token(args.token_env)
        event = "" if args.event == "all" else args.event
        run, resolved_via = load_run(args.repo, token, args.workflow, args.run_selector, args.branch, event)
        jobs = load_jobs(args.repo, token, int(run["id"]))
        try:
            lane_outcome_report = load_lane_outcome_artifacts(api_get, args.repo, token, int(run["id"]))
        except Exception:
            lane_outcome_report = {"artifact_count": 0, "records": {}, "unreadable_artifacts": []}

    repo_root = Path(__file__).resolve().parents[3]
    registry = build_lane_registry(
        repo_root / args.manifest,
        repo_root / args.platform_catalog,
    )
    normalized_lane_outcomes = {
        normalize_job_name(name): payload
        for name, payload in lane_outcome_report["records"].items()
    }
    entry_registry: dict[tuple[str, int], list[object]] = defaultdict(list)
    for record in registry.values():
        entry_registry[(record.lane_file, record.include_index)].append(record)

    lane_jobs: list[dict] = []
    lane_conclusions_by_name: dict[str, set[str]] = defaultdict(set)
    lane_urls_by_name: dict[str, str] = {}
    unmapped_jobs: list[dict] = []
    categorized: dict[str, list[dict]] = defaultdict(list)
    masked_outcome_missing_count = 0
    for key in CATEGORY_ORDER:
        categorized.setdefault(key, [])

    for job in jobs:
        normalized_name = normalize_job_name(str(job.get("name", "")))
        if normalized_name in {"build-matrix", "redispatch-selected-ref"}:
            continue

        github_conclusion = str(job.get("conclusion") or job.get("status") or "unknown").strip().lower() or "unknown"
        record = registry.get(normalized_name)
        if record is None:
            unmapped_jobs.append(
                {
                    "name": normalized_name,
                    "conclusion": github_conclusion,
                    "html_url": job.get("html_url"),
                }
            )
            lane_jobs.append(
                {
                    "name": normalized_name,
                    "conclusion": github_conclusion,
                    "allow_failure": False,
                    "category": classify_lane_category(github_conclusion, allow_failure=False),
                    "mapped": False,
                    "html_url": job.get("html_url"),
                }
            )
            categorized[lane_jobs[-1]["category"]].append(lane_jobs[-1])
            continue

        lane_outcome_record = normalized_lane_outcomes.get(normalized_name)
        effective_conclusion, used_recorded_outcome = effective_lane_conclusion(
            github_conclusion,
            allow_failure=record.allow_failure,
            recorded_outcome=(
                str(lane_outcome_record.get("lane_outcome", "")) if lane_outcome_record else ""
            ),
        )
        if record.allow_failure and lane_outcome_record is None and github_conclusion == "success":
            masked_outcome_missing_count += 1

        lane_conclusions_by_name[normalized_name].add(effective_conclusion)
        if job.get("html_url"):
            lane_urls_by_name[normalized_name] = str(job["html_url"])
        category = classify_lane_category(effective_conclusion, record.allow_failure)
        lane_jobs.append(
            {
                "name": normalized_name,
                "conclusion": effective_conclusion,
                "github_conclusion": github_conclusion,
                "recorded_lane_outcome": (
                    str(lane_outcome_record.get("lane_outcome", "")) if lane_outcome_record else ""
                ),
                "used_recorded_outcome": used_recorded_outcome,
                "allow_failure": record.allow_failure,
                "category": category,
                "mapped": True,
                "lane_file": record.lane_file,
                "include_index": record.include_index,
                "platform_id": record.platform_id,
                "variant": record.variant,
                "html_url": job.get("html_url"),
            }
        )
        categorized[category].append(lane_jobs[-1])

    category_counts = build_category_counts(categorized)
    category_counts_with_legacy = dict(category_counts)
    category_counts_with_legacy["fails"] = total_fail_count(category_counts)

    docs = load_lane_file_docs(repo_root, {record.lane_file for record in registry.values()})
    lane_states: list[dict] = []
    lanes_by_entry: dict[tuple[str, int], list[dict]] = defaultdict(list)
    group_state_counts = {key: 0 for key in GROUP_STATE_ORDER}
    proposed_lane_changes: list[dict] = []
    proposed_entry_changes: list[dict] = []
    touched_entries: set[tuple[str, int]] = set()
    touched_files: set[str] = set()

    for lane_name, conclusions in sorted(lane_conclusions_by_name.items()):
        record = registry[lane_name]
        has_failure = any(conclusion in FAIL_CONCLUSIONS for conclusion in conclusions)
        has_non_success = any(conclusion != "success" for conclusion in conclusions)
        all_success = bool(conclusions) and all(conclusion == "success" for conclusion in conclusions)
        current = bool(record.allow_failure)
        desired = current
        if has_failure:
            desired = True
        elif all_success:
            desired = False

        lane_state = {
            "name": lane_name,
            "lane_file": record.lane_file,
            "include_index": record.include_index,
            "variant": record.variant,
            "platform_id": record.platform_id,
            "conclusions": sorted(conclusions),
            "current_allow_failure": current,
            "desired_allow_failure": desired,
            "has_failure": has_failure,
            "has_non_success": has_non_success,
            "all_success": all_success,
            "html_url": lane_urls_by_name.get(lane_name, ""),
        }
        lane_states.append(lane_state)
        lanes_by_entry[(record.lane_file, record.include_index)].append(lane_state)

    for entry_key, entry_lanes in sorted(lanes_by_entry.items()):
        lane_file, include_index = entry_key
        include = docs[lane_file]["include"]
        include_record = include[include_index]
        entry = include_record["entry"]
        if not isinstance(entry, dict):
            continue

        group_state = classify_entry_state(entry_lanes)
        group_state_counts[group_state] += 1

        variant_specs = extract_entry_variant_specs(entry, lane_file, include_index)
        desired_by_variant = {}
        current_by_variant = {}
        lane_name_by_variant = {}

        for record in entry_registry[entry_key]:
            if record.variant in current_by_variant:
                raise ValueError(
                    f"Duplicate variant '{record.variant}' detected for {lane_file}#{include_index}"
                )
            current_by_variant[record.variant] = bool(record.allow_failure)
            lane_name_by_variant[record.variant] = record.name

        for spec in variant_specs["specs"]:
            variant = spec["variant"]
            desired_by_variant[variant] = current_by_variant.get(variant, False)

        for lane in entry_lanes:
            desired_by_variant[lane["variant"]] = lane["desired_allow_failure"]

        entry_changes = {"set": [], "reset": []}
        for variant, desired in desired_by_variant.items():
            current = current_by_variant.get(variant, False)
            if desired == current:
                continue
            lane_name = lane_name_by_variant.get(variant, variant)
            change_record = {
                "name": lane_name,
                "lane_file": lane_file,
                "include_index": include_index,
                "variant": variant,
                "from_allow_failure": current,
                "to_allow_failure": desired,
                "conclusions": next(
                    (
                        lane["conclusions"]
                        for lane in entry_lanes
                        if lane["variant"] == variant
                    ),
                    [],
                ),
            }
            proposed_lane_changes.append(change_record)
            entry_changes["set" if desired else "reset"].append(lane_name)

        if not entry_changes["set"] and not entry_changes["reset"]:
            continue

        apply_entry_lane_states(include_record["target"], variant_specs, desired_by_variant)
        if include_record["generated"] and include_record["is_secondary"]:
            target = include_record["target"]
            if isinstance(target, dict) and not target:
                include_record["platform"].pop("secondary_overrides", None)
        touched_entries.add(entry_key)
        touched_files.add(lane_file)
        proposed_entry_changes.append(
            {
                "lane_file": lane_file,
                "include_index": include_index,
                "set_lanes": sorted(entry_changes["set"]),
                "reset_lanes": sorted(entry_changes["reset"]),
            }
        )

    if args.apply:
        for lane_file in sorted(touched_files):
            write_lane_file(docs[lane_file]["path"], docs[lane_file]["data"])

    set_count = sum(1 for change in proposed_lane_changes if change["to_allow_failure"])
    reset_count = sum(1 for change in proposed_lane_changes if not change["to_allow_failure"])
    reset_candidates = [
        lane for lane in lane_states if lane["current_allow_failure"] and lane["all_success"]
    ]
    still_masked_failures = [
        lane for lane in lane_states if lane["current_allow_failure"] and lane["has_non_success"]
    ]
    new_mask_candidates = [
        lane for lane in lane_states if (not lane["current_allow_failure"]) and lane["has_failure"]
    ]

    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_number = run.get("run_number")
    run_url = run.get("html_url") or f"{server_url}/{args.repo}/actions/runs/{run.get('id')}"
    workflow_name = run.get("name") or args.workflow
    run_conclusion = str(run.get("conclusion") or run.get("status") or "unknown").strip().lower()
    resolved_via_label = format_resolved_via(resolved_via)

    markdown_lines = [
        "# Allow-Failure Reconciliation",
        "",
        f"- Workflow: `{workflow_name}`",
        f"- Run: [{run.get('id')}]({run_url})",
        f"- Run number: `#{run_number}`" if run_number is not None else "- Run number: `<unknown>`",
        f"- Resolved via: `{resolved_via_label}`",
        f"- Branch: `{run.get('head_branch') or ''}`",
        f"- Event: `{run.get('event') or ''}`",
        f"- Workflow conclusion: `{run_conclusion}`",
        f"- Apply mode: `{'on' if args.apply else 'off (dry-run)'}`",
        "",
        "## Outcome",
        "",
        f"- Hard failures: `{category_counts_with_legacy['fails_hard']}` jobs",
        f"- Masked failures: `{category_counts_with_legacy['fails_with_allow_failure']}` jobs",
        f"- Ready to reset: `{len(reset_candidates)}` masked lanes",
        f"- Eligible to mask: `{len(new_mask_candidates)}` normal lanes",
        "",
        "## Actions",
        "",
        f"- Set `allow_failure=true`: `{set_count}` lanes",
        f"- Reset `allow_failure`: `{reset_count}` lanes",
        f"- Source entries touched: `{len(touched_entries)}`",
        f"- Source entries analyzed: `{len(lanes_by_entry)}`",
        f"- Lane jobs analyzed: `{len(lane_jobs)}`",
        f"- Concrete lanes analyzed: `{len(lane_states)}`",
        f"- Unmapped lane jobs: `{len(unmapped_jobs)}`",
        f"- Files touched: `{len(touched_files)}`",
    ]
    if masked_outcome_missing_count:
        markdown_lines.extend(
            [
                "",
                f"- Masked lanes without recorded outcome artifact: `{masked_outcome_missing_count}`",
                "  Treated conservatively as non-success to avoid false resets.",
            ]
        )
    unreadable_lane_outcomes = lane_outcome_report.get("unreadable_artifacts", [])
    if unreadable_lane_outcomes:
        markdown_lines.extend(
            [
                "",
                f"- Unreadable masked lane outcome artifacts: `{len(unreadable_lane_outcomes)}`",
            ]
        )

    if unmapped_jobs:
        unmapped_lines: list[str] = []
        for job in sorted(unmapped_jobs, key=lambda item: item["name"].lower()):
            if job.get("html_url"):
                unmapped_lines.append(f"- [{job['name']}]({job['html_url']}) (`{job['conclusion']}`)")
            else:
                unmapped_lines.append(f"- {job['name']} (`{job['conclusion']}`)")
        append_details_section(markdown_lines, f"Unmapped lanes ({len(unmapped_jobs)})", unmapped_lines)

    if proposed_entry_changes:
        markdown_lines.extend(["", "## Proposed Changes", ""])
        for change in proposed_entry_changes:
            fragments: list[str] = []
            if change["set_lanes"]:
                fragments.append(
                    "set `allow_failure=true` on " + ", ".join(change["set_lanes"])
                )
            if change["reset_lanes"]:
                fragments.append(
                    "reset `allow_failure` on " + ", ".join(change["reset_lanes"])
                )
            markdown_lines.append(
                f"- `{change['lane_file']}#{change['include_index']}` : " + "; ".join(fragments)
            )
    else:
        no_change_message = "- No allow_failure updates required."
        if still_masked_failures and not new_mask_candidates:
            no_change_message += (
                f" {category_counts['fails_with_allow_failure']} failing jobs map to "
                f"{len(still_masked_failures)} masked lanes, all already marked `allow_failure`."
            )
        markdown_lines.extend(["", "## Proposed Changes", "", no_change_message])

    reset_lines: list[str] = []
    for lane in reset_candidates:
        reset_lines.append(
            f"- `{lane['name']}` (`{lane['lane_file']}#{lane['include_index']}` / `{lane['variant']}`)"
        )
    append_details_section(markdown_lines, f"Reset candidates ({len(reset_candidates)} lanes)", reset_lines)

    new_mask_lines: list[str] = []
    for lane in new_mask_candidates:
        new_mask_lines.append(
            f"- `{lane['name']}` (`{lane['lane_file']}#{lane['include_index']}` / `{lane['variant']}`; conclusions: {', '.join(lane['conclusions'])})"
        )
    append_details_section(markdown_lines, f"New mask candidates ({len(new_mask_candidates)} lanes)", new_mask_lines)

    still_masked_lines: list[str] = []
    for lane in still_masked_failures:
        still_masked_lines.append(
            f"- `{lane['name']}` (`{lane['lane_file']}#{lane['include_index']}` / `{lane['variant']}`; conclusions: {', '.join(lane['conclusions'])})"
        )
    append_details_section(
        markdown_lines,
        f"Still masked failures ({len(still_masked_failures)} lanes)",
        still_masked_lines,
    )

    markdown = "\n".join(markdown_lines) + "\n"
    report = {
        "workflow": {
            "name": workflow_name,
            "run_id": run.get("id"),
            "run_number": run.get("run_number"),
            "event": run.get("event"),
            "branch": run.get("head_branch"),
            "head_sha": run.get("head_sha"),
            "conclusion": run_conclusion,
            "html_url": run_url,
            "resolved_via": resolved_via,
        },
        "analysis": {
            "lane_job_count": len(lane_jobs),
            "mapped_lane_job_count": sum(1 for job in lane_jobs if job.get("mapped")),
            "unmapped_lane_job_count": len(unmapped_jobs),
            "lane_group_count": len(lanes_by_entry),
            "source_entry_count": len(lanes_by_entry),
            "touched_entry_count": len(touched_entries),
            "category_counts": category_counts_with_legacy,
            "group_state_counts": group_state_counts,
            "masked_outcome_missing_count": masked_outcome_missing_count,
            "lane_outcome_artifact_count": lane_outcome_report.get("artifact_count", 0),
            "lane_outcome_record_count": len(lane_outcome_report.get("records", {})),
            "lane_outcome_unreadable_count": len(unreadable_lane_outcomes),
            "proposed_set_count": set_count,
            "proposed_reset_count": reset_count,
            "proposed_change_count": len(proposed_lane_changes),
            "proposed_entry_change_count": len(proposed_entry_changes),
            "touched_files_count": len(touched_files),
            "apply": args.apply,
        },
        "lane_jobs": lane_jobs,
        "lane_groups": list(lanes_by_entry.values()),
        "lane_states": lane_states,
        "unmapped_lane_jobs": unmapped_jobs,
        "proposed_changes": proposed_lane_changes,
        "proposed_entry_changes": proposed_entry_changes,
        "touched_files": sorted(touched_files),
    }

    if args.markdown_output:
        Path(args.markdown_output).write_text(markdown, encoding="utf-8")
    if args.json_output:
        Path(args.json_output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.github_output:
        with Path(args.github_output).open("a", encoding="utf-8") as handle:
            handle.write(f"run_id={run.get('id')}\n")
            handle.write(f"run_url={run_url}\n")
            handle.write(f"lane_job_count={len(lane_jobs)}\n")
            handle.write(f"mapped_lane_job_count={sum(1 for job in lane_jobs if job.get('mapped'))}\n")
            handle.write(f"unmapped_lane_job_count={len(unmapped_jobs)}\n")
            handle.write(f"lane_group_count={len(lanes_by_entry)}\n")
            handle.write(f"source_entry_count={len(lanes_by_entry)}\n")
            handle.write(f"touched_entry_count={len(touched_entries)}\n")
            handle.write(f"success_lane_count={category_counts['success']}\n")
            handle.write(f"success_allow_failure_lane_count={category_counts['success_with_allow_failure']}\n")
            handle.write(
                f"fails_allow_failure_lane_count={category_counts_with_legacy['fails_with_allow_failure']}\n"
            )
            handle.write(f"fails_hard_lane_count={category_counts_with_legacy['fails_hard']}\n")
            handle.write(f"fails_lane_count={category_counts_with_legacy['fails']}\n")
            handle.write(
                f"normal_passing_group_count={group_state_counts['normal_passing']}\n"
            )
            handle.write(
                f"normal_failing_group_count={group_state_counts['normal_failing']}\n"
            )
            handle.write(
                f"masked_ready_to_reset_group_count={group_state_counts['masked_ready_to_reset']}\n"
            )
            handle.write(
                f"masked_still_failing_group_count={group_state_counts['masked_still_failing']}\n"
            )
            handle.write(f"proposed_set_count={set_count}\n")
            handle.write(f"proposed_reset_count={reset_count}\n")
            handle.write(f"proposed_change_count={len(proposed_lane_changes)}\n")
            handle.write(f"proposed_entry_change_count={len(proposed_entry_changes)}\n")
            handle.write(f"touched_files_count={len(touched_files)}\n")
            handle.write(f"apply_mode={'true' if args.apply else 'false'}\n")

    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
