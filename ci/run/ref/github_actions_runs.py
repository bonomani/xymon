from __future__ import annotations

import re
import urllib.parse
from typing import Callable

ApiGet = Callable[[str, str, str, dict[str, str] | None], dict]

RUN_URL_RE = re.compile(r"/actions/runs/(?P<run_id>\d+)")
RUN_NUMBER_RE = re.compile(r"#(?P<run_number>\d+)\s*$")


def normalize_run_selector(run_selector: str) -> str:
    return " ".join((run_selector or "").strip().split())


def format_resolved_via(resolved_via: str) -> str:
    labels = {
        "fixture": "fixture",
        "latest": "latest completed run matching filters",
        "run_id": "explicit run ID",
        "run_number": "explicit run-number selector",
    }
    return labels.get(resolved_via, resolved_via)


def extract_run_id(run_selector: str) -> int | None:
    selector = normalize_run_selector(run_selector)
    if not selector:
        return None
    if selector.isdigit():
        return int(selector)
    match = RUN_URL_RE.search(selector)
    if match is None:
        return None
    return int(match.group("run_id"))


def extract_run_number(run_selector: str) -> int | None:
    selector = normalize_run_selector(run_selector)
    if not selector:
        return None
    match = RUN_NUMBER_RE.search(selector)
    if match is None:
        return None
    return int(match.group("run_number"))


def load_run_from_selector(
    api_get: ApiGet,
    repo: str,
    token: str,
    workflow: str,
    run_selector: str,
) -> tuple[dict, str]:
    selector = normalize_run_selector(run_selector)
    if not selector:
        raise ValueError("run selector is empty")

    run_id = extract_run_id(selector)
    if run_id is not None:
        return api_get(repo, token, f"/repos/{repo}/actions/runs/{run_id}"), "run_id"

    run_number = extract_run_number(selector)
    if run_number is None:
        raise ValueError(
            "Unsupported run selector. Use a numeric run ID, an Actions run URL, "
            "or a label ending with '#<run_number>'."
        )

    page = 1
    while True:
        payload = api_get(
            repo,
            token,
            f"/repos/{repo}/actions/workflows/{urllib.parse.quote(workflow, safe='')}/runs",
            params={"per_page": "100", "page": str(page), "status": "completed"},
        )
        workflow_runs = payload.get("workflow_runs", [])
        if not workflow_runs:
            break
        for run in workflow_runs:
            try:
                current_run_number = int(run.get("run_number"))
            except (TypeError, ValueError):
                continue
            if current_run_number == run_number:
                return run, "run_number"
        if len(workflow_runs) < 100:
            break
        page += 1

    raise ValueError(f"No completed workflow run found for selector: {selector}")


def load_latest_workflow_run(
    api_get: ApiGet,
    repo: str,
    token: str,
    workflow: str,
    branch: str,
    event: str,
) -> dict:
    params = {"per_page": "1", "status": "completed"}
    if branch:
        params["branch"] = branch
    if event:
        params["event"] = event
    payload = api_get(
        repo,
        token,
        f"/repos/{repo}/actions/workflows/{urllib.parse.quote(workflow, safe='')}/runs",
        params=params,
    )
    runs = payload.get("workflow_runs", [])
    if not runs:
        selector = workflow
        if branch:
            selector = f"{selector} on branch {branch}"
        if event:
            selector = f"{selector} for event {event}"
        raise ValueError(f"No completed workflow runs found for {selector}")
    return runs[0]
