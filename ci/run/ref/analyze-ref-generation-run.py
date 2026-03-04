#!/usr/bin/env python3

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter, defaultdict
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
DEPENDENCY_ARTIFACT_PREFIXES = ("deps_", "deps_valid_")
DEPENDENCY_ARTIFACT_TOP_N = 20


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def coerce_int(value: object, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


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


def build_headers(repo: str, token: str, accept: str = "application/vnd.github+json") -> dict[str, str]:
    return {
        "Accept": accept,
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": f"{repo}/ref-generation-analysis",
    }


def api_get(repo: str, token: str, path: str, params: dict[str, str] | None = None) -> dict:
    base_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    url = f"{base_url}{path}"
    if params:
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
        if query:
            url = f"{url}?{query}"
    request = urllib.request.Request(
        url,
        headers=build_headers(repo, token),
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Prevent automatic redirect following so signed URLs can be fetched without repo auth."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def resolve_artifact_redirect_url(repo: str, token: str, url: str) -> str:
    request = urllib.request.Request(
        url,
        headers=build_headers(repo, token, accept="application/vnd.github+json"),
    )
    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        with opener.open(request) as response:
            location = str(response.headers.get("Location", "")).strip()
            if location:
                return location
            return response.geturl()
    except urllib.error.HTTPError as exc:
        if exc.code not in (301, 302, 303, 307, 308):
            raise
        location = str(exc.headers.get("Location", "")).strip()
        if not location:
            raise ValueError("artifact download redirect missing Location header") from exc
        return location


def download_artifact_archive(repo: str, token: str, archive_url: str) -> bytes:
    signed_url = resolve_artifact_redirect_url(repo, token, archive_url)
    request = urllib.request.Request(
        signed_url,
        headers={
            "Accept": "application/octet-stream",
            "User-Agent": f"{repo}/ref-generation-analysis",
        },
    )
    with urllib.request.urlopen(request) as response:
        return response.read()


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


def load_artifacts(repo: str, token: str, run_id: int) -> list[dict]:
    artifacts: list[dict] = []
    page = 1
    while True:
        payload = api_get(
            repo,
            token,
            f"/repos/{repo}/actions/runs/{run_id}/artifacts",
            params={"per_page": "100", "page": str(page)},
        )
        page_artifacts = payload.get("artifacts", [])
        if not page_artifacts:
            break
        artifacts.extend(page_artifacts)
        if len(page_artifacts) < 100:
            break
        page += 1
    return artifacts


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


def is_dependency_artifact_name(name: str) -> bool:
    return any(name.startswith(prefix) for prefix in DEPENDENCY_ARTIFACT_PREFIXES)


def parse_dependency_artifact_name(name: str) -> dict[str, str]:
    artifact_kind = "unknown"
    body = name
    if name.startswith("deps_valid_"):
        artifact_kind = "validation"
        body = name[len("deps_valid_") :]
    elif name.startswith("deps_"):
        artifact_kind = "generation"
        body = name[len("deps_") :]

    artifact_arch = ""
    lane_name = ""
    if "__" in body:
        body, *suffix_parts = body.split("__")
        if suffix_parts:
            first_suffix = suffix_parts[0].strip()
            if first_suffix in {"amd64", "arm64"}:
                artifact_arch = first_suffix
                lane_name = "__".join(part for part in suffix_parts[1:] if part)
            else:
                lane_name = "__".join(part for part in suffix_parts if part)

    build_tool = ""
    platform_id = ""
    variant = ""
    if "_" in body:
        build_tool, remainder = body.split("_", 1)
        if "_" in remainder:
            platform_id, variant = remainder.rsplit("_", 1)
        else:
            platform_id = remainder

    return {
        "artifact_kind": artifact_kind,
        "build_tool": build_tool,
        "platform_id": platform_id,
        "variant": variant,
        "artifact_arch": artifact_arch,
        "lane_name": lane_name,
    }


def extract_dependency_report_from_archive(archive_bytes: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        report_members = sorted(
            name
            for name in archive.namelist()
            if name == "deps-report.json" or name.endswith("/deps-report.json")
        )
        if not report_members:
            raise ValueError("deps-report.json not found in artifact archive")
        payload = json.loads(archive.read(report_members[0]).decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("deps-report.json payload is not a JSON object")
    return payload


def count_from_report(report: dict, key: str) -> int:
    counts = report.get("counts")
    if isinstance(counts, dict) and key in counts:
        return coerce_int(counts.get(key), default=0)
    values = report.get(key)
    if isinstance(values, list):
        return len(values)
    return 0


def build_frequency_list(counter: Counter[str]) -> list[dict[str, object]]:
    return [
        {"package": package, "count": count}
        for package, count in sorted(counter.items(), key=lambda item: (-item[1], item[0]))
    ]


def empty_dependency_report(status: str, lane_job_count: int, error: str = "") -> dict:
    return {
        "status": status,
        "error": error,
        "coverage": {
            "lane_job_count": lane_job_count,
            "artifact_count": 0,
            "parsed_report_count": 0,
            "unreadable_artifact_count": 0,
            "jobs_without_artifact_estimate": lane_job_count,
            "jobs_without_parsed_report_estimate": lane_job_count,
            "parsed_coverage_percent": 0.0,
        },
        "reports": [],
        "unreadable_artifacts": [],
        "aggregate": {
            "requested_newly_installed_frequency": [],
            "indirect_newly_installed_frequency": [],
        },
    }


def build_dependency_report(repo: str, token: str, run_id: int, lane_jobs: list[dict]) -> dict:
    lane_job_count = len(lane_jobs)
    artifacts = load_artifacts(repo, token, run_id)
    dependency_artifacts = [
        artifact for artifact in artifacts if is_dependency_artifact_name(str(artifact.get("name", "")).strip())
    ]

    if not dependency_artifacts:
        return empty_dependency_report("none", lane_job_count)

    parsed_reports: list[dict] = []
    unreadable_artifacts: list[dict[str, object]] = []
    direct_counter: Counter[str] = Counter()
    indirect_counter: Counter[str] = Counter()

    for artifact in dependency_artifacts:
        artifact_name = str(artifact.get("name", "")).strip() or "<unnamed>"
        artifact_meta = parse_dependency_artifact_name(artifact_name)

        if artifact.get("expired"):
            unreadable_artifacts.append({"name": artifact_name, "reason": "artifact expired"})
            continue

        archive_url = str(artifact.get("archive_download_url", "")).strip()
        if not archive_url:
            unreadable_artifacts.append({"name": artifact_name, "reason": "missing archive_download_url"})
            continue

        try:
            archive_bytes = download_artifact_archive(repo, token, archive_url)
            report_payload = extract_dependency_report_from_archive(archive_bytes)
        except Exception as exc:  # pragma: no cover - best-effort artifact aggregation
            unreadable_artifacts.append({"name": artifact_name, "reason": str(exc)})
            continue

        requested_new = sorted(str(item) for item in report_payload.get("requested_newly_installed", []) if item)
        indirect_new = sorted(str(item) for item in report_payload.get("indirect_newly_installed", []) if item)
        direct_counter.update(requested_new)
        indirect_counter.update(indirect_new)

        parsed_reports.append(
            {
                "artifact_name": artifact_name,
                "artifact_id": artifact.get("id"),
                "artifact_kind": artifact_meta["artifact_kind"],
                "artifact_size_in_bytes": coerce_int(artifact.get("size_in_bytes"), default=0),
                "artifact_created_at": artifact.get("created_at"),
                "artifact_updated_at": artifact.get("updated_at"),
                "artifact_expires_at": artifact.get("expires_at"),
                "build_tool": artifact_meta["build_tool"],
                "platform_id": artifact_meta["platform_id"],
                "variant": artifact_meta["variant"] or str(report_payload.get("variant", "")),
                "report_mode": str(report_payload.get("mode", "")),
                "report_status": str(report_payload.get("status", "")),
                "family": str(report_payload.get("family", "")),
                "os": str(report_payload.get("os", "")),
                "version": str(report_payload.get("version", "")),
                "package_manager": str(report_payload.get("package_manager", "")),
                "requested_packages_count": count_from_report(report_payload, "requested_packages"),
                "requested_already_present_count": count_from_report(report_payload, "requested_already_present"),
                "requested_missing_before_count": count_from_report(report_payload, "requested_missing_before"),
                "requested_newly_installed_count": count_from_report(report_payload, "requested_newly_installed"),
                "requested_missing_after_count": count_from_report(report_payload, "requested_missing_after"),
                "all_newly_installed_count": count_from_report(report_payload, "all_newly_installed"),
                "indirect_newly_installed_count": count_from_report(report_payload, "indirect_newly_installed"),
                "requested_newly_installed": requested_new,
                "indirect_newly_installed": indirect_new,
            }
        )

    parsed_reports.sort(
        key=lambda entry: (
            str(entry.get("artifact_kind", "")),
            str(entry.get("build_tool", "")),
            str(entry.get("platform_id", "")),
            str(entry.get("variant", "")),
            str(entry.get("artifact_name", "")),
        )
    )
    unreadable_artifacts.sort(key=lambda entry: str(entry.get("name", "")))

    parsed_report_count = len(parsed_reports)
    artifact_count = len(dependency_artifacts)
    unreadable_count = len(unreadable_artifacts)
    coverage_percent = round((parsed_report_count / lane_job_count) * 100, 1) if lane_job_count else 0.0

    return {
        "status": "available",
        "error": "",
        "coverage": {
            "lane_job_count": lane_job_count,
            "artifact_count": artifact_count,
            "parsed_report_count": parsed_report_count,
            "unreadable_artifact_count": unreadable_count,
            "jobs_without_artifact_estimate": max(lane_job_count - artifact_count, 0),
            "jobs_without_parsed_report_estimate": max(lane_job_count - parsed_report_count, 0),
            "parsed_coverage_percent": coverage_percent,
        },
        "reports": parsed_reports,
        "unreadable_artifacts": unreadable_artifacts,
        "aggregate": {
            "requested_newly_installed_frequency": build_frequency_list(direct_counter),
            "indirect_newly_installed_frequency": build_frequency_list(indirect_counter),
        },
    }


def append_dependency_markdown(markdown: str, dependency_report: dict) -> str:
    if dependency_report.get("status") == "skipped":
        return markdown

    lines = markdown.rstrip("\n").splitlines()
    lines.extend(["", "## Dependency Reports", ""])

    status = str(dependency_report.get("status", "unknown"))
    if status == "unavailable":
        lines.append(
            f"- Dependency report aggregation was unavailable: `{dependency_report.get('error') or 'unknown error'}`"
        )
        return "\n".join(lines) + "\n"
    if status == "none":
        lines.append("- No dependency report artifacts were found for this run.")
        return "\n".join(lines) + "\n"

    coverage = dependency_report.get("coverage", {})
    parsed_count = coerce_int(coverage.get("parsed_report_count"), default=0)
    lane_job_count = coerce_int(coverage.get("lane_job_count"), default=0)
    artifact_count = coerce_int(coverage.get("artifact_count"), default=0)
    jobs_without_artifact = coerce_int(coverage.get("jobs_without_artifact_estimate"), default=0)
    unreadable_count = coerce_int(coverage.get("unreadable_artifact_count"), default=0)
    coverage_percent = coverage.get("parsed_coverage_percent", 0.0)

    lines.append(f"- Dependency report artifacts found: `{artifact_count}`")
    lines.append(
        f"- Parsed reports: `{parsed_count}` of `{lane_job_count}` lane jobs (`{coverage_percent}%` coverage)"
    )
    if jobs_without_artifact:
        lines.append(f"- Lane jobs without dependency artifact (estimated): `{jobs_without_artifact}`")
    if unreadable_count:
        lines.append(f"- Unreadable dependency artifacts: `{unreadable_count}`")

    unreadable_artifacts = dependency_report.get("unreadable_artifacts", [])
    if unreadable_artifacts:
        lines.extend(["", "### Unreadable Dependency Artifacts", ""])
        for entry in unreadable_artifacts:
            lines.append(f"- `{entry.get('name', '<unnamed>')}`: {entry.get('reason', 'unknown error')}")

    reports = dependency_report.get("reports", [])
    if reports:
        lines.extend(
            [
                "",
                f"### Per-Lane Summary ({len(reports)})",
                "",
                "| Artifact | Platform | Variant | Pkg mgr | Status | Requested | Present | New | Indirect |",
                "| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: |",
            ]
        )
        for entry in reports:
            platform = str(entry.get("platform_id") or "").strip()
            if not platform:
                platform = " ".join(
                    part for part in [str(entry.get("os", "")).strip(), str(entry.get("version", "")).strip()] if part
                ).strip()
            lines.append(
                "| "
                + " | ".join(
                    [
                        f"`{entry.get('artifact_name', '')}`",
                        f"`{platform or '<unknown>'}`",
                        f"`{entry.get('variant', '') or '<unknown>'}`",
                        f"`{entry.get('package_manager', '') or '<unknown>'}`",
                        f"`{entry.get('report_status', '') or '<unknown>'}`",
                        str(coerce_int(entry.get("requested_packages_count"), default=0)),
                        str(coerce_int(entry.get("requested_already_present_count"), default=0)),
                        str(coerce_int(entry.get("requested_newly_installed_count"), default=0)),
                        str(coerce_int(entry.get("indirect_newly_installed_count"), default=0)),
                    ]
                )
                + " |"
            )

    for heading, key in [
        ("Most Common Requested Installs", "requested_newly_installed_frequency"),
        ("Most Common Indirect Installs", "indirect_newly_installed_frequency"),
    ]:
        frequency = dependency_report.get("aggregate", {}).get(key, [])
        if not frequency:
            continue
        lines.extend(["", f"### {heading}", ""])
        for entry in frequency[:DEPENDENCY_ARTIFACT_TOP_N]:
            lines.append(f"- `{entry['package']}`: {entry['count']} lane(s)")

    return "\n".join(lines) + "\n"


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
    dependency = report.get("dependency_reports", {})
    dependency_coverage = dependency.get("coverage", {})
    with Path(path).open("a", encoding="utf-8") as handle:
        handle.write(f"run_id={report['workflow']['run_id']}\n")
        handle.write(f"run_url={report['workflow']['html_url']}\n")
        handle.write(f"lane_job_count={report['analysis']['lane_job_count']}\n")
        handle.write(f"control_job_count={report['analysis']['control_job_count']}\n")
        handle.write(f"dependency_report_status={dependency.get('status', 'skipped')}\n")
        handle.write(
            f"dependency_report_count={coerce_int(dependency_coverage.get('parsed_report_count'), default=0)}\n"
        )
        handle.write(
            f"dependency_artifact_count={coerce_int(dependency_coverage.get('artifact_count'), default=0)}\n"
        )
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
    if fixture_mode:
        dependency_report = empty_dependency_report("skipped", len(lane_jobs))
    else:
        try:
            dependency_report = build_dependency_report(args.repo, token, int(run["id"]), lane_jobs)
        except Exception as exc:  # pragma: no cover - degrade gracefully when artifact aggregation fails
            dependency_report = empty_dependency_report("unavailable", len(lane_jobs), error=str(exc))
    markdown, report = build_report(args.repo, run, lane_jobs, control_jobs, resolved_via)
    report["dependency_reports"] = dependency_report
    markdown = append_dependency_markdown(markdown, dependency_report)

    if args.markdown_output:
        write_text(args.markdown_output, markdown)
    if args.json_output:
        write_json(args.json_output, report)
    if args.github_output:
        write_github_output(args.github_output, report)

    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
