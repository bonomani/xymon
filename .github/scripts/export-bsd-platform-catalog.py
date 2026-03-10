#!/usr/bin/env python3
"""Export discovered metadata for BSD/macOS VM platforms."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

INTENT_PATH = Path("ci/deps/platform-bsd-sources.yaml")
PLATFORM_CATALOG_PATH = Path("ci/deps/platform-catalog.yaml")
HOST_RUNNERS_PATH = Path(".github/data/github-host-runners.yml")
OUTPUT_PATH = Path(".github/data/bsd-platform-catalog.yml")
GITHUB_API = "https://api.github.com"
MANIFEST_ACCEPT = "application/vnd.github+json"
USER_AGENT = "xymon-bsd-platform-export/1.0"


def require_mapping(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SystemExit(f"{context} must be a mapping")
    return value


def require_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{context} must be a non-empty string")
    return value.strip()


def load_yaml(path: Path, context: str) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"Missing {context}: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return require_mapping(data, context)


def github_request(path: str) -> dict[str, Any]:
    url = f"{GITHUB_API}{path}"
    headers = {"User-Agent": USER_AGENT, "Accept": MANIFEST_ACCEPT}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"token {token}"
    try:
        req = Request(url, headers=headers)
        with urlopen(req) as response:
            return json.load(response)
    except HTTPError as exc:
        raise SystemExit(f"Failed to fetch {url}: {exc}") from exc


def fetch_latest_release(repo: str) -> dict[str, Any]:
    return github_request(f"/repos/{repo}/releases/latest")


def build_host_runner_index() -> dict[str, dict]:
    data = load_yaml(HOST_RUNNERS_PATH, f"GitHub host runner catalog in {HOST_RUNNERS_PATH}")
    runners = data.get("runners")
    if not isinstance(runners, list):
        raise SystemExit(f"{HOST_RUNNERS_PATH} runners must be a list")
    index: dict[str, dict] = {}
    for idx, raw in enumerate(runners):
        entry = require_mapping(raw, f"{HOST_RUNNERS_PATH} runners[{idx}]")
        label = require_string(entry.get("label"), f"{HOST_RUNNERS_PATH} runners[{idx}].label")
        platform_os = require_string(entry.get("platform_os"), f"{HOST_RUNNERS_PATH} runners[{idx}].platform_os").lower()
        platform_version = require_string(entry.get("platform_version"), f"{HOST_RUNNERS_PATH} runners[{idx}].platform_version")
        arch = require_string(entry.get("arch"), f"{HOST_RUNNERS_PATH} runners[{idx}].arch").lower()
        front_key = f"{platform_os}:{platform_version}:{arch}"
        index[front_key] = {"label": label, "arch": arch, "platform_os": platform_os, "platform_version": platform_version}
        for alias in entry.get("aliases", []):
            alias_label = require_string(alias, f"{HOST_RUNNERS_PATH} runners[{idx}].aliases element")
            # alias might map to same version string; store under alias_label as pseudo-version.
            index[f"{platform_os}:{alias_label}:{arch}"] = {"label": label, "arch": arch, "platform_os": platform_os, "platform_version": platform_version}
    return index


def find_runner(label: str, arch: str, host_index: dict[str, dict]) -> str | None:
    key = f"macos:{label}:{arch}"
    entry = host_index.get(key)
    if entry:
        return entry["label"]
    # fall back to best effort - match label or alias presence
    for candidate in host_index.values():
        if candidate["arch"] == arch and candidate["label"] == label:
            return candidate["label"]
    return None


def export():
    intent = load_yaml(INTENT_PATH, f"BSDS sources in {INTENT_PATH}")
    source_entries = require_mapping(intent.get("sources"), f"{INTENT_PATH} sources")
    host_index = build_host_runner_index()
    records: list[dict[str, Any]] = []
    for platform_id, raw in source_entries.items():
        entry = require_mapping(raw, f"{INTENT_PATH} sources.{platform_id}")
        os_name = require_string(entry.get("os"), f"{INTENT_PATH} sources.{platform_id}.os").lower()
        version = require_string(entry.get("version"), f"{INTENT_PATH} sources.{platform_id}.version")
        arch = require_string(entry.get("arch"), f"{INTENT_PATH} sources.{platform_id}.arch").lower()
        provider = entry.get("provider") or "cross-platform-actions"
        record: dict[str, Any] = {
            "platform_id": platform_id,
            "os": os_name,
            "version": version,
            "arch": arch,
            "provider": provider,
        }
        if provider == "cross-platform-actions":
            repo = require_string(entry.get("repo"), f"{INTENT_PATH} sources.{platform_id}.repo")
            release = fetch_latest_release(repo)
            asset_name = f"{os_name}-{version}-{arch}.qcow2"
            assets = release.get("assets", [])
            asset = next((a for a in assets if a.get("name") == asset_name), None)
            if not asset:
                raise SystemExit(f"No asset matching '{asset_name}' in release {release.get('tag_name')} for {repo}")
            record.update(
                {
                    "repo": repo,
                    "release_tag": release.get("tag_name"),
                    "release_url": release.get("html_url"),
                    "asset_name": asset.get("name"),
                    "asset_url": asset.get("browser_download_url"),
                    "asset_size": asset.get("size"),
                    "asset_updated_at": asset.get("updated_at"),
                }
            )
        elif provider == "github-actions":
            runner_label = require_string(entry.get("runner_label"), f"{INTENT_PATH} sources.{platform_id}.runner_label")
            runner = find_runner(runner_label, arch, host_index)
            if runner is None:
                raise SystemExit(f"Runner '{runner_label}' for platform {platform_id} not found in {HOST_RUNNERS_PATH}")
            record["runner_label"] = runner
        records.append(record)

    meta = {
        "source": {
            "platform_catalog": str(PLATFORM_CATALOG_PATH),
            "bsd_sources": str(INTENT_PATH),
            "host_runner_catalog": str(HOST_RUNNERS_PATH),
            "github_api": GITHUB_API,
        },
        "platforms": records,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        yaml.safe_dump(meta, sort_keys=False), encoding="utf-8"
    )


if __name__ == "__main__":
    export()
