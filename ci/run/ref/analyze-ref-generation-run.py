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

API_VERSION = "2022-11-28"
DEFAULT_WORKFLOW = "ref-make-select.yml"
CONTROL_JOB_NAMES = frozenset({"build-matrix", "redispatch-selected-ref"})
CONCLUSION_ORDER = [
    "success",
    "failure",
    "cancelled",
    "timed_out",
    "action_required",
    "startup_failure",
    "skipped",
    "neutral",
    "stale",
    "unknown",
]
CONCLUSION_LABELS = {
    "success": "Passed",
    "failure": "Failed",
    "cancelled": "Cancelled",
    "timed_out": "Timed Out",
    "action_required": "Action Required",
    "startup_failure": "Startup Failure",
    "skipped": "Skipped",
    "neutral": "Neutral",
    "stale": "Stale",
    "unknown": "Unknown",
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


def api_get(repo: str, token: str, path: str, params: dict[str, str] | None = None) -> dict:
    base_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    url = f"{base_url}{path}"
    if params:
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
        if query:
            url = f"{url}?{query}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": f"{repo}/ref-generation-analysis",
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def load_run(repo: str, token: str, workflow: str, run_id: str, branch: str, event: str) -> tuple[dict, str]:
    if run_id:
        run = api_get(repo, token, f"/repos/{repo}/actions/runs/{run_id}")
        return run, "run_id"

    params = {"per_page": "1", "status": "completed"}
    if branch:
        params["branch"] = branch
    if event:
        params["event"] = event
    runs = api_get(
        repo,
        token,
        f"/repos/{repo}/actions/workflows/{urllib.parse.quote(workflow, safe='')}/runs",
        params=params,
    ).get("workflow_runs", [])
    if not runs:
        selector = workflow
        if branch:
            selector = f"{selector} on branch {branch}"
        if event:
            selector = f"{selector} for event {event}"
        die(f"No completed workflow runs found for {selector}")
    return runs[0], "latest"


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


def load_fixture(path: str) -> dict:
    return json.loads(Path(path).read_text())


def load_fixture_jobs(path: str) -> list[dict]:
    payload = load_fixture(path)
    if isinstance(payload, dict) and "jobs" in payload:
        payload = payload["jobs"]
    if not isinstance(payload, list):
        die(f"Jobs fixture is not a list: {path}")
    return payload


def classify_jobs(jobs: list[dict]) -> tuple[list[dict], list[dict]]:
    lane_jobs: list[dict] = []
    control_jobs: list[dict] = []
    for job in jobs:
        normalized_name = normalize_job_name(str(job.get("name", "")))
        enriched = dict(job)
        enriched["normalized_name"] = normalized_name
        conclusion = str(job.get("conclusion") or job.get("status") or "unknown").strip().lower()
        enriched["normalized_conclusion"] = conclusion or "unknown"
        if normalized_name in CONTROL_JOB_NAMES:
            control_jobs.append(enriched)
        else:
            lane_jobs.append(enriched)
    return lane_jobs, control_jobs


def build_report(repo: str, run: dict, lane_jobs: list[dict], control_jobs: list[dict], resolved_via: str) -> tuple[str, dict]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for job in lane_jobs:
        grouped[job["normalized_conclusion"]].append(job)
    for jobs in grouped.values():
        jobs.sort(key=lambda job: job["normalized_name"].lower())

    counts = {key: len(grouped.get(key, [])) for key in CONCLUSION_ORDER}
    control_names = sorted(job["normalized_name"] for job in control_jobs)
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    run_id = run.get("id")
    run_url = run.get("html_url") or f"{server_url}/{repo}/actions/runs/{run_id}"
    run_conclusion = str(run.get("conclusion") or run.get("status") or "unknown").strip().lower()
    workflow_name = run.get("name") or "Reference Generation - Select Family"
    head_sha = str(run.get("head_sha") or "")
    short_sha = head_sha[:12] if head_sha else ""

    lines = [
        "# Reference Generation Analysis",
        "",
        f"- Workflow: `{workflow_name}`",
        f"- Run: [{run_id}]({run_url})",
        f"- Resolved via: `{resolved_via}`",
        f"- Branch: `{run.get('head_branch') or ''}`",
        f"- Event: `{run.get('event') or ''}`",
        f"- Workflow conclusion: `{run_conclusion}`",
        f"- Commit: `{short_sha}`" if short_sha else "- Commit: `<unknown>`",
        f"- Lane jobs analyzed: `{len(lane_jobs)}`",
        f"- Control jobs ignored: `{len(control_jobs)}`",
        "",
        "## Counts",
        "",
        "| Conclusion | Count |",
        "| --- | ---: |",
    ]
    for key in CONCLUSION_ORDER:
        lines.append(f"| {CONCLUSION_LABELS.get(key, key)} | {counts[key]} |")

    if control_names:
        lines.extend(["", f"- Ignored control jobs: {', '.join(control_names)}"])

    if not lane_jobs:
        lines.extend(
            [
                "",
                "## Notes",
                "",
                "- No lane jobs were found in this run. This usually means a redispatch-only run or an early failure before matrix expansion.",
            ]
        )
    else:
        for key in CONCLUSION_ORDER:
            jobs = grouped.get(key, [])
            if not jobs:
                continue
            lines.extend(["", f"## {CONCLUSION_LABELS.get(key, key)} ({len(jobs)})", ""])
            for job in jobs:
                job_name = job["normalized_name"]
                job_url = job.get("html_url")
                if job_url:
                    lines.append(f"- [{job_name}]({job_url})")
                else:
                    lines.append(f"- {job_name}")

    report = {
        "workflow": {
            "name": workflow_name,
            "run_id": run_id,
            "run_number": run.get("run_number"),
            "event": run.get("event"),
            "branch": run.get("head_branch"),
            "head_sha": head_sha,
            "conclusion": run_conclusion,
            "html_url": run_url,
            "resolved_via": resolved_via,
        },
        "analysis": {
            "lane_job_count": len(lane_jobs),
            "control_job_count": len(control_jobs),
            "counts": counts,
        },
        "lane_jobs": [
            {
                "name": job["normalized_name"],
                "raw_name": job.get("name"),
                "conclusion": job["normalized_conclusion"],
                "status": job.get("status"),
                "html_url": job.get("html_url"),
                "started_at": job.get("started_at"),
                "completed_at": job.get("completed_at"),
            }
            for job in lane_jobs
        ],
        "control_jobs": [
            {
                "name": job["normalized_name"],
                "raw_name": job.get("name"),
                "conclusion": job["normalized_conclusion"],
                "status": job.get("status"),
                "html_url": job.get("html_url"),
            }
            for job in control_jobs
        ],
    }
    return "\n".join(lines) + "\n", report


def write_text(path: str, content: str) -> None:
    Path(path).write_text(content)


def write_json(path: str, payload: dict) -> None:
    Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def write_github_output(path: str, report: dict) -> None:
    counts = report["analysis"]["counts"]
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(f"run_id={report['workflow']['run_id']}\n")
        handle.write(f"run_url={report['workflow']['html_url']}\n")
        handle.write(f"lane_job_count={report['analysis']['lane_job_count']}\n")
        handle.write(f"control_job_count={report['analysis']['control_job_count']}\n")
        for key in CONCLUSION_ORDER:
            handle.write(f"{key}_count={counts.get(key, 0)}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze a Reference Generation workflow run and group lane jobs by conclusion."
    )
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--branch", default="")
    parser.add_argument("--event", default="workflow_dispatch")
    parser.add_argument("--token-env", default="GH_TOKEN")
    parser.add_argument("--markdown-output", default="")
    parser.add_argument("--json-output", default="")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument("--run-json", default="")
    parser.add_argument("--jobs-json", default="")
    return parser.parse_args()


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

    lane_jobs, control_jobs = classify_jobs(jobs)
    markdown, report = build_report(args.repo, run, lane_jobs, control_jobs, resolved_via)

    if args.markdown_output:
        write_text(args.markdown_output, markdown)
    if args.json_output:
        write_json(args.json_output, report)
    if args.github_output:
        write_github_output(args.github_output, report)

    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
