from __future__ import annotations

import io
import json
import os
import urllib.error
import urllib.request
import zipfile

API_VERSION = "2022-11-28"
OUTCOME_ARTIFACT_PREFIX = "lane_outcome__"


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_headers(repo: str, token: str, accept: str = "application/vnd.github+json") -> dict[str, str]:
    return {
        "Accept": accept,
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": f"{repo}/lane-outcome-artifacts",
    }


def load_artifacts(api_get, repo: str, token: str, run_id: int) -> list[dict]:
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


def is_lane_outcome_artifact_name(name: str) -> bool:
    return str(name or "").strip().startswith(OUTCOME_ARTIFACT_PREFIX)


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
            "User-Agent": f"{repo}/lane-outcome-artifacts",
        },
    )
    with urllib.request.urlopen(request) as response:
        return response.read()


def extract_lane_outcome_from_archive(archive_bytes: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        members = sorted(
            name
            for name in archive.namelist()
            if (
                name == "lane-outcome.json"
                or name.endswith("/lane-outcome.json")
                or name.startswith("lane-outcome-")
                or "/lane-outcome-" in name
            )
        )
        if not members:
            raise ValueError("lane outcome JSON not found in artifact archive")
        payload = json.loads(archive.read(members[0]).decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("lane-outcome.json payload is not a JSON object")
    lane_name = str(payload.get("lane_name") or "").strip()
    lane_outcome = str(payload.get("lane_outcome") or "").strip()
    if not lane_name:
        raise ValueError("lane-outcome.json missing lane_name")
    if not lane_outcome:
        raise ValueError("lane-outcome.json missing lane_outcome")
    return payload


def load_lane_outcome_artifacts(api_get, repo: str, token: str, run_id: int) -> dict:
    artifacts = load_artifacts(api_get, repo, token, run_id)
    lane_outcomes: dict[str, dict] = {}
    unreadable: list[dict[str, str]] = []
    outcome_artifact_count = 0

    for artifact in artifacts:
        artifact_name = str(artifact.get("name", "")).strip()
        if not is_lane_outcome_artifact_name(artifact_name):
            continue
        outcome_artifact_count += 1

        if artifact.get("expired"):
            unreadable.append({"name": artifact_name, "reason": "artifact expired"})
            continue

        archive_url = str(artifact.get("archive_download_url", "")).strip()
        if not archive_url:
            unreadable.append({"name": artifact_name, "reason": "missing archive_download_url"})
            continue

        try:
            archive_bytes = download_artifact_archive(repo, token, archive_url)
            payload = extract_lane_outcome_from_archive(archive_bytes)
        except Exception as exc:  # pragma: no cover - best effort
            unreadable.append({"name": artifact_name, "reason": str(exc)})
            continue

        lane_name = str(payload["lane_name"]).strip()
        lane_outcomes[lane_name] = payload

    return {
        "artifact_count": outcome_artifact_count,
        "records": lane_outcomes,
        "unreadable_artifacts": unreadable,
    }
