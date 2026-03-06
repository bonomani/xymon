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
from github_actions_runs import load_latest_workflow_run, load_run_from_selector
from lane_registry import build_lane_registry

API_VERSION = "2022-11-28"
DEFAULT_WORKFLOW = "pipeline-select-run-lanes.yml"
FAIL_CONCLUSIONS = {"failure", "timed_out", "action_required", "startup_failure"}


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


def load_run(repo: str, token: str, workflow: str, run_id: str, branch: str, event: str) -> tuple[dict, str]:
    if run_id:
        try:
            return load_run_from_selector(api_get, repo, token, workflow, run_id)
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
    parser.add_argument("--run-id", default="")
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


def classify_category(conclusion: str, allow_failure: bool) -> str:
    if conclusion == "success":
        return "success_with_allow_failure" if allow_failure else "success"
    return "fails"


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
        run, resolved_via = load_run(args.repo, token, args.workflow, args.run_id, args.branch, event)
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
    category_counts = {
        "success": 0,
        "success_with_allow_failure": 0,
        "fails": 0,
    }

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
                    "category": "fails" if conclusion != "success" else "success",
                    "mapped": False,
                    "html_url": job.get("html_url"),
                }
            )
            continue

        entry_key = (record.lane_file, record.include_index)
        entry_conclusions[entry_key].add(conclusion)
        entry_lane_names[entry_key].append(normalized_name)
        category = classify_category(conclusion, record.allow_failure)
        category_counts[category] += 1
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

    docs = load_lane_file_docs(repo_root, {record.lane_file for record in registry.values()})
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

        if desired == current:
            continue

        if desired:
            entry["allow_failure"] = True
        else:
            entry.pop("allow_failure", None)

        touched_files.add(lane_file)
        proposed_changes.append(
            {
                "lane_file": lane_file,
                "include_index": include_index,
                "lane_names": sorted(set(entry_lane_names[entry_key])),
                "conclusions": sorted(conclusions),
                "from_allow_failure": current,
                "to_allow_failure": desired,
            }
        )

    if args.apply:
        for lane_file in sorted(touched_files):
            write_lane_file(docs[lane_file]["path"], docs[lane_file]["data"])

    set_count = sum(1 for change in proposed_changes if change["to_allow_failure"])
    reset_count = sum(1 for change in proposed_changes if not change["to_allow_failure"])

    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_url = run.get("html_url") or f"{server_url}/{args.repo}/actions/runs/{run.get('id')}"
    workflow_name = run.get("name") or args.workflow
    run_conclusion = str(run.get("conclusion") or run.get("status") or "unknown").strip().lower()

    markdown_lines = [
        "# Allow-Failure Reconciliation",
        "",
        f"- Workflow: `{workflow_name}`",
        f"- Run: [{run.get('id')}]({run_url})",
        f"- Resolved via: `{resolved_via}`",
        f"- Branch: `{run.get('head_branch') or ''}`",
        f"- Event: `{run.get('event') or ''}`",
        f"- Workflow conclusion: `{run_conclusion}`",
        f"- Apply mode: `{'on' if args.apply else 'off (dry-run)'}`",
        "",
        "## Categories",
        "",
        "| Category | Count |",
        "| --- | ---: |",
        f"| Success | {category_counts['success']} |",
        f"| Success with allow_failure | {category_counts['success_with_allow_failure']} |",
        f"| Fails | {category_counts['fails']} |",
        "",
        "## Reconciliation",
        "",
        f"- Lane jobs analyzed: `{len(lane_jobs)}`",
        f"- Mapped lane jobs: `{sum(1 for job in lane_jobs if job.get('mapped'))}`",
        f"- Unmapped lane jobs: `{len(unmapped_jobs)}`",
        f"- Proposed `allow_failure=true`: `{set_count}`",
        f"- Proposed `allow_failure` reset: `{reset_count}`",
        f"- Files touched: `{len(touched_files)}`",
    ]

    if unmapped_jobs:
        markdown_lines.extend(["", "## Unmapped Lanes", ""])
        for job in sorted(unmapped_jobs, key=lambda item: item["name"].lower()):
            if job.get("html_url"):
                markdown_lines.append(f"- [{job['name']}]({job['html_url']}) (`{job['conclusion']}`)")
            else:
                markdown_lines.append(f"- {job['name']} (`{job['conclusion']}`)")

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
        markdown_lines.extend(["", "## Proposed Changes", "", "- No allow_failure updates required."])

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
            "category_counts": category_counts,
            "proposed_set_count": set_count,
            "proposed_reset_count": reset_count,
            "proposed_change_count": len(proposed_changes),
            "touched_files_count": len(touched_files),
            "apply": args.apply,
        },
        "lane_jobs": lane_jobs,
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
            handle.write(f"success_lane_count={category_counts['success']}\n")
            handle.write(f"success_allow_failure_lane_count={category_counts['success_with_allow_failure']}\n")
            handle.write(f"fails_lane_count={category_counts['fails']}\n")
            handle.write(f"proposed_set_count={set_count}\n")
            handle.write(f"proposed_reset_count={reset_count}\n")
            handle.write(f"proposed_change_count={len(proposed_changes)}\n")
            handle.write(f"touched_files_count={len(touched_files)}\n")
            handle.write(f"apply_mode={'true' if args.apply else 'false'}\n")

    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
