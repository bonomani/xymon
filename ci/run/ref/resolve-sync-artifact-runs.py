#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

from github_actions_runs import load_run_from_selector

API_VERSION = "2022-11-28"


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve workflow run IDs that have downloadable ref_* artifacts."
    )
    parser.add_argument("--repo", required=True)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--branch", default="")
    parser.add_argument("--run-selector", default="")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument(
        "--if-not-found",
        choices=("error", "empty"),
        default="error",
        help="Whether to fail or emit no output when no downloadable ref_* artifacts are found.",
    )
    return parser.parse_args()


def load_token() -> str:
    for env_name in ("GH_TOKEN", "GITHUB_TOKEN"):
        token = os.environ.get(env_name, "").strip()
        if token:
            return token
    die("Missing GitHub token in GH_TOKEN or GITHUB_TOKEN")


def build_headers(repo: str, token: str) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": f"{repo}/pipeline-sync-artifacts",
    }


def api_get(repo: str, token: str, path: str, params: dict[str, str] | None = None) -> dict:
    url = f"https://api.github.com{path}"
    if params:
        query = urllib.parse.urlencode({key: value for key, value in params.items() if value})
        if query:
            url = f"{url}?{query}"
    request = urllib.request.Request(url, headers=build_headers(repo, token))
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def has_ref_artifacts(repo: str, token: str, run_id: str) -> bool:
    payload = api_get(
        repo,
        token,
        f"/repos/{repo}/actions/runs/{run_id}/artifacts",
        params={"per_page": "100"},
    )
    artifacts = payload.get("artifacts", [])
    return any(str(artifact.get("name", "")).startswith("ref_") for artifact in artifacts)


def resolve_selector(repo: str, token: str, workflow: str, selector: str) -> str:
    normalized = " ".join((selector or "").strip().split())
    if not normalized:
        return ""
    try:
        run, _resolved_via = load_run_from_selector(
            api_get,
            repo,
            token,
            workflow,
            normalized,
        )
    except urllib.error.HTTPError as exc:
        if exc.code != 404 or not normalized.isdigit():
            raise
        run, _resolved_via = load_run_from_selector(
            api_get,
            repo,
            token,
            workflow,
            f"#{normalized}",
        )

    run_id = str(run.get("id", "")).strip()
    if run_id and has_ref_artifacts(repo, token, run_id):
        return run_id
    return ""


def iter_recent_successful_runs(repo: str, token: str, workflow: str, branch: str, limit: int):
    page = 1
    remaining = max(limit, 0)
    workflow_path = urllib.parse.quote(workflow, safe="")
    while remaining > 0:
        per_page = min(100, remaining)
        payload = api_get(
            repo,
            token,
            f"/repos/{repo}/actions/workflows/{workflow_path}/runs",
            params={
                "per_page": str(per_page),
                "page": str(page),
                "status": "completed",
                "branch": branch,
            }
            if branch
            else {
                "per_page": str(per_page),
                "page": str(page),
                "status": "completed",
            },
        )
        workflow_runs = payload.get("workflow_runs", [])
        if not workflow_runs:
            return
        for run in workflow_runs:
            if str(run.get("conclusion", "")).strip() != "success":
                continue
            yield str(run.get("id", "")).strip()
        if len(workflow_runs) < per_page:
            return
        remaining -= per_page
        page += 1


def main() -> None:
    args = parse_args()
    token = load_token()

    requested = str(args.run_selector or "").strip()
    if requested:
        seen: set[str] = set()
        resolved: list[str] = []
        for raw_selector in requested.replace(",", "\n").splitlines():
            run_id = resolve_selector(args.repo, token, args.workflow, raw_selector)
            if not run_id:
                if args.if_not_found == "empty":
                    return
                die(f"Requested run selector has no downloadable ref_* artifacts: {raw_selector.strip()}")
            if run_id not in seen:
                seen.add(run_id)
                resolved.append(run_id)
        if not resolved:
            if args.if_not_found == "empty":
                return
            die("No requested runs resolved to downloadable ref_* artifacts")
        print("\n".join(resolved))
        return

    for run_id in iter_recent_successful_runs(
        args.repo,
        token,
        args.workflow,
        str(args.branch or "").strip(),
        args.limit,
    ):
        if run_id and has_ref_artifacts(args.repo, token, run_id):
            print(run_id)
            return

    branch_suffix = f" on branch {args.branch}" if args.branch else ""
    if args.if_not_found == "empty":
        return

    die(
        f"No successful run found for {args.workflow}{branch_suffix} "
        "with downloadable ref_* artifacts"
    )


if __name__ == "__main__":
    main()
