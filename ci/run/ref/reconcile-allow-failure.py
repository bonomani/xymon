#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

import yaml
from github_actions_runs import format_resolved_via, load_latest_workflow_run, load_run_from_selector
from lane_categories import (
    CATEGORY_LABELS,
    CATEGORY_ORDER,
    build_category_counts,
    classify_lane_category,
    total_fail_count,
)
from lane_registry import build_lane_registry

API_VERSION = "2022-11-28"
DEFAULT_WORKFLOW = "pipeline-select-run-lanes.yml"
FAIL_CONCLUSIONS = {"failure", "timed_out", "action_required", "startup_failure"}
GROUP_STATE_ORDER = [
    "normal_passing",
    "normal_failing",
    "masked_ready_to_reset",
    "masked_still_failing",
]
GROUP_STATE_LABELS = {
    "normal_passing": "Normal lane groups passing",
    "normal_failing": "Normal lane groups failing and eligible to mask",
    "masked_ready_to_reset": "Masked lane groups ready to reset",
    "masked_still_failing": "Masked lane groups still failing",
}


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
        include = None
        if isinstance(data, dict):
            include = data.get("include", data.get("lanes"))
        elif isinstance(data, list):
            include = data
        if not isinstance(include, list):
            raise ValueError(f"Lane file include section must be a list: {lane_file_rel}")
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
    else:
        token = load_token(args.token_env)
        event = "" if args.event == "all" else args.event
        run, resolved_via = load_run(args.repo, token, args.workflow, args.run_selector, args.branch, event)
        jobs = load_jobs(args.repo, token, int(run["id"]))

    repo_root = Path(__file__).resolve().parents[3]
    registry = build_lane_registry(
        repo_root / args.manifest,
        repo_root / args.platform_catalog,
    )

    lane_jobs: list[dict] = []
    entry_conclusions: dict[tuple[str, int], set[str]] = defaultdict(set)
    entry_lane_names: dict[tuple[str, int], list[str]] = defaultdict(list)
    unmapped_jobs: list[dict] = []
    categorized: dict[str, list[dict]] = defaultdict(list)
    for key in CATEGORY_ORDER:
        categorized.setdefault(key, [])

    for job in jobs:
        normalized_name = normalize_job_name(str(job.get("name", "")))
        if normalized_name in {"build-matrix", "redispatch-selected-ref"}:
            continue

        conclusion = str(job.get("conclusion") or job.get("status") or "unknown").strip().lower() or "unknown"
        record = registry.get(normalized_name)
        if record is None:
            unmapped_jobs.append(
                {
                    "name": normalized_name,
                    "conclusion": conclusion,
                    "html_url": job.get("html_url"),
                }
            )
            lane_jobs.append(
                {
                    "name": normalized_name,
                    "conclusion": conclusion,
                    "allow_failure": False,
                    "category": classify_lane_category(conclusion, allow_failure=False),
                    "mapped": False,
                    "html_url": job.get("html_url"),
                }
            )
            categorized[lane_jobs[-1]["category"]].append(lane_jobs[-1])
            continue

        entry_key = (record.lane_file, record.include_index)
        entry_conclusions[entry_key].add(conclusion)
        entry_lane_names[entry_key].append(normalized_name)
        category = classify_lane_category(conclusion, record.allow_failure)
        lane_jobs.append(
            {
                "name": normalized_name,
                "conclusion": conclusion,
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
    group_states: list[dict] = []
    group_state_counts = {key: 0 for key in GROUP_STATE_ORDER}
    proposed_changes: list[dict] = []
    touched_files: set[str] = set()

    for entry_key, conclusions in sorted(entry_conclusions.items()):
        lane_file, include_index = entry_key
        include = docs[lane_file]["include"]
        entry = include[include_index]
        if not isinstance(entry, dict):
            continue
        current = bool(entry.get("allow_failure") is True)

        has_failure = any(conclusion in FAIL_CONCLUSIONS for conclusion in conclusions)
        all_success = bool(conclusions) and all(conclusion == "success" for conclusion in conclusions)
        desired = current
        if has_failure:
            desired = True
        elif all_success:
            desired = False

        if current:
            group_state = "masked_still_failing" if has_failure else "masked_ready_to_reset"
        else:
            group_state = "normal_failing" if has_failure else "normal_passing"
        group_state_counts[group_state] += 1

        group_record = {
            "lane_file": lane_file,
            "include_index": include_index,
            "lane_names": sorted(set(entry_lane_names[entry_key])),
            "conclusions": sorted(conclusions),
            "current_allow_failure": current,
            "desired_allow_failure": desired,
            "group_state": group_state,
            "has_failure": has_failure,
            "all_success": all_success,
        }
        group_states.append(group_record)

        if desired == current:
            continue

        if desired:
            entry["allow_failure"] = True
        else:
            entry.pop("allow_failure", None)

        touched_files.add(lane_file)
        proposed_changes.append(
            {
                "lane_file": group_record["lane_file"],
                "include_index": group_record["include_index"],
                "lane_names": group_record["lane_names"],
                "conclusions": group_record["conclusions"],
                "from_allow_failure": current,
                "to_allow_failure": desired,
            }
        )

    if args.apply:
        for lane_file in sorted(touched_files):
            write_lane_file(docs[lane_file]["path"], docs[lane_file]["data"])

    set_count = sum(1 for change in proposed_changes if change["to_allow_failure"])
    reset_count = sum(1 for change in proposed_changes if not change["to_allow_failure"])
    reset_candidates = [
        group for group in group_states if group["current_allow_failure"] and group["all_success"]
    ]
    still_masked_failures = [
        group for group in group_states if group["current_allow_failure"] and group["has_failure"]
    ]
    new_mask_candidates = [
        group for group in group_states if (not group["current_allow_failure"]) and group["has_failure"]
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
        f"- Hard failures: `{category_counts_with_legacy['fails_hard']}` jobs across `{group_state_counts['normal_failing']}` lane groups",
        f"- Masked failures: `{category_counts_with_legacy['fails_with_allow_failure']}` jobs across `{group_state_counts['masked_still_failing']}` lane groups",
        f"- Ready to reset: `{len(reset_candidates)}` masked lane groups",
        f"- Eligible to mask: `{len(new_mask_candidates)}` normal lane groups",
        "",
        "## Actions",
        "",
        f"- Set `allow_failure=true`: `{set_count}` lane groups",
        f"- Reset `allow_failure`: `{reset_count}` lane groups",
        f"- Lane groups analyzed: `{len(group_states)}`",
        f"- Lane jobs analyzed: `{len(lane_jobs)}`",
        f"- Unmapped lane jobs: `{len(unmapped_jobs)}`",
        f"- Files touched: `{len(touched_files)}`",
    ]

    if unmapped_jobs:
        unmapped_lines: list[str] = []
        for job in sorted(unmapped_jobs, key=lambda item: item["name"].lower()):
            if job.get("html_url"):
                unmapped_lines.append(f"- [{job['name']}]({job['html_url']}) (`{job['conclusion']}`)")
            else:
                unmapped_lines.append(f"- {job['name']} (`{job['conclusion']}`)")
        append_details_section(markdown_lines, f"Unmapped lanes ({len(unmapped_jobs)})", unmapped_lines)

    if proposed_changes:
        markdown_lines.extend(["", "## Proposed Changes", ""])
        for change in proposed_changes:
            lane_list = ", ".join(change["lane_names"])
            markdown_lines.append(
                "- "
                f"`{change['lane_file']}#{change['include_index']}` "
                f"`{change['from_allow_failure']}` -> `{change['to_allow_failure']}` "
                f"(conclusions: {', '.join(change['conclusions'])})"
            )
            markdown_lines.append(f"  lanes: {lane_list}")
    else:
        no_change_message = "- No allow_failure updates required."
        if still_masked_failures and not new_mask_candidates:
            no_change_message += (
                f" {category_counts['fails_with_allow_failure']} failing jobs map to "
                f"{len(still_masked_failures)} masked lane groups, all already marked `allow_failure`."
            )
        markdown_lines.extend(["", "## Proposed Changes", "", no_change_message])

    reset_lines: list[str] = []
    for group in reset_candidates:
        lane_list = ", ".join(group["lane_names"])
        reset_lines.append(
            f"- `{group['lane_file']}#{group['include_index']}` "
            f"(all jobs passed; would reset `allow_failure`) : {lane_list}"
        )
    append_details_section(markdown_lines, f"Reset candidates ({len(reset_candidates)})", reset_lines)

    new_mask_lines: list[str] = []
    for group in new_mask_candidates:
        lane_list = ", ".join(group["lane_names"])
        new_mask_lines.append(
            f"- `{group['lane_file']}#{group['include_index']}` "
            f"(contains failures; would set `allow_failure=true`) : {lane_list}"
        )
    append_details_section(markdown_lines, f"New mask candidates ({len(new_mask_candidates)})", new_mask_lines)

    still_masked_lines: list[str] = []
    for group in still_masked_failures:
        lane_list = ", ".join(group["lane_names"])
        still_masked_lines.append(
            f"- `{group['lane_file']}#{group['include_index']}` "
            f"(conclusions: {', '.join(group['conclusions'])}) : {lane_list}"
        )
    append_details_section(
        markdown_lines,
        f"Still masked failures ({len(still_masked_failures)} lane groups)",
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
            "lane_group_count": len(group_states),
            "category_counts": category_counts_with_legacy,
            "group_state_counts": group_state_counts,
            "proposed_set_count": set_count,
            "proposed_reset_count": reset_count,
            "proposed_change_count": len(proposed_changes),
            "touched_files_count": len(touched_files),
            "apply": args.apply,
        },
        "lane_jobs": lane_jobs,
        "lane_groups": group_states,
        "unmapped_lane_jobs": unmapped_jobs,
        "proposed_changes": proposed_changes,
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
            handle.write(f"lane_group_count={len(group_states)}\n")
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
            handle.write(f"proposed_change_count={len(proposed_changes)}\n")
            handle.write(f"touched_files_count={len(touched_files)}\n")
            handle.write(f"apply_mode={'true' if args.apply else 'false'}\n")

    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
