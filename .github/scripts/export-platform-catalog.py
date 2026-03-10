#!/usr/bin/env python3
"""Discover Docker container images and BSD/macOS VM artifacts in one catalog."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
CONTAINER_INTENT = ROOT / "ci" / "deps" / "platform-intent.yaml"
BSD_SOURCES = ROOT / "ci" / "deps" / "platform-bsd-sources.yaml"
HOST_RUNNERS = ROOT / "ci" / "deps" / "platform-host-runners.yaml"
OUTPUT = ROOT / ".github" / "data" / "platform-catalog-discovered.yml"
REGISTRY_BASE = "https://registry-1.docker.io"
TOKEN_URL = "https://auth.docker.io/token"
MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
USER_AGENT = "xymon-platform-catalog-export/1.0"
ARCH_NORMALIZATION = {
    ("amd64", None): "amd64",
    ("arm64", None): "arm64",
    ("arm64", "v8"): "arm64",
    ("arm", "v7"): "arm32v7",
    ("ppc64le", None): "ppc64le",
    ("riscv64", None): "riscv64",
    ("s390x", None): "s390x",
}
HOST_ARCH_TO_ARCH = {"x64": "amd64", "amd64": "amd64", "arm64": "arm64"}


def require_mapping(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SystemExit(f"{context} must be a mapping")
    return value


def require_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{context} must be a non-empty string")
    return value.strip()


def require_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise SystemExit(f"{context} must be a list")
    return value


def load_yaml(path: Path, context: str) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"Missing {context}: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return require_mapping(data, context)


def github_request(path: str) -> dict[str, Any]:
    url = f"https://api.github.com{path}"
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
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


def fetch_registry_token(repository: str) -> str:
    query = urlencode(
        {
            "service": "registry.docker.io",
            "scope": f"repository:{repository}:pull",
        }
    )
    with urlopen(f"{TOKEN_URL}?{query}") as response:
        payload = json.load(response)
    token = payload.get("token")
    if not isinstance(token, str) or not token:
        raise SystemExit(f"Unable to obtain registry token for {repository}")
    return token


def fetch_manifest_index(repository: str, tag: str, token: str) -> tuple[str, str, str, dict[str, Any]]:
    manifest_url = f"{REGISTRY_BASE}/v2/{repository}/manifests/{tag}"
    request = Request(
        manifest_url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": MANIFEST_ACCEPT,
            "User-Agent": USER_AGENT,
        },
    )
    with urlopen(request) as response:
        content_type = response.headers.get("Content-Type", "")
        digest = response.headers.get("docker-content-digest", "")
        payload = json.load(response)
    return manifest_url, content_type, digest, payload


def normalize_manifest_architecture(platform: Any) -> str | None:
    if not isinstance(platform, dict):
        return None
    if platform.get("os") != "linux":
        return None
    key = (platform.get("architecture"), platform.get("variant"))
    return ARCH_NORMALIZATION.get(key)


def extract_architectures(payload: dict[str, Any]) -> list[str]:
    manifests = payload.get("manifests")
    if not isinstance(manifests, list):
        return []
    archs: list[str] = []
    for manifest in manifests:
        arch = normalize_manifest_architecture(manifest.get("platform"))
        if arch is None or arch in archs:
            continue
        archs.append(arch)
    return archs


def load_container_intent() -> list[dict[str, Any]]:
    data = load_yaml(CONTAINER_INTENT, f"platform intent in {CONTAINER_INTENT}")
    families = require_mapping(data.get("families"), f"{CONTAINER_INTENT} families")
    normalized_families: list[dict[str, Any]] = []
    for name, raw in families.items():
        family = require_mapping(raw, f"{CONTAINER_INTENT} families.{name}")
        repository = require_string(
            family.get("repository"), f"{CONTAINER_INTENT} families.{name}.repository"
        )
        repository_url = require_string(
            family.get("repository_url"),
            f"{CONTAINER_INTENT} families.{name}.repository_url",
        )
        runtime_preference = require_list(
            family.get("runtime_preference"),
            f"{CONTAINER_INTENT} families.{name}.runtime_preference",
        )
        releases = require_list(
            family.get("releases"),
            f"{CONTAINER_INTENT} families.{name}.releases",
        )
        normalized_releases: list[dict[str, Any]] = []
        for index, raw_release in enumerate(releases):
            entry = require_mapping(
                raw_release,
                f"{CONTAINER_INTENT} families.{name}.releases[{index}]",
            )
            deps = require_mapping(
                entry.get("deps"),
                f"{CONTAINER_INTENT} families.{name}.releases[{index}].deps",
            )
            platform_os = require_string(
                deps.get("os"),
                f"{CONTAINER_INTENT} families.{name}.releases[{index}].deps.os",
            ).lower()
            normalized_releases.append(
                {
                    "platform_id": require_string(
                        entry.get("platform_id"),
                        f"{CONTAINER_INTENT} families.{name}.releases[{index}].platform_id",
                    ),
                    "tag": require_string(
                        entry.get("tag"),
                        f"{CONTAINER_INTENT} families.{name}.releases[{index}].tag",
                    ),
                    "platform_version": require_string(
                        entry.get("platform_version"),
                        f"{CONTAINER_INTENT} families.{name}.releases[{index}].platform_version",
                    ),
                    "deps": deps,
                    "platform_os": platform_os,
                    "arches": require_list(
                        entry.get("arches"),
                        f"{CONTAINER_INTENT} families.{name}.releases[{index}].arches",
                    ),
                }
            )
        normalized_families.append(
            {
                "family": name,
                "repository": repository,
                "repository_url": repository_url,
                "runtime_preference": [str(v) for v in runtime_preference],
                "releases": normalized_releases,
            }
        )
    return normalized_families


def load_bsd_sources() -> dict[str, dict[str, Any]]:
    data = load_yaml(BSD_SOURCES, f"BSD sources in {BSD_SOURCES}")
    return require_mapping(data.get("sources"), f"{BSD_SOURCES} sources")


def load_host_runners() -> list[dict[str, Any]]:
    data = load_yaml(HOST_RUNNERS, f"host runner catalog in {HOST_RUNNERS}")
    runners = require_list(data.get("runners"), f"{HOST_RUNNERS} runners")
    normalized: list[dict[str, Any]] = []
    for idx, runner in enumerate(runners):
        entry = require_mapping(runner, f"{HOST_RUNNERS} runners[{idx}]")
        require_string(entry.get("label"), f"{HOST_RUNNERS} runners[{idx}].label")
        require_string(entry.get("platform_os"), f"{HOST_RUNNERS} runners[{idx}].platform_os")
        require_string(
            entry.get("platform_version"),
            f"{HOST_RUNNERS} runners[{idx}].platform_version",
        )
        require_string(entry.get("arch"), f"{HOST_RUNNERS} runners[{idx}].arch")
        normalized.append(entry.copy())
    return normalized


def render_yaml(intent_meta: dict[str, Any], containers: list[dict[str, Any]], vms: list[dict[str, Any]], runners: list[dict[str, Any]]) -> str:
    payload = {
        "source": intent_meta,
        "platforms": {
            "containers": containers,
            "vms": vms,
            "runners": runners,
        },
    }
    return yaml.safe_dump(payload, sort_keys=False)


def export_catalog():
    container_intent = load_container_intent()
    bsd_sources = load_bsd_sources()
    host_runners = load_host_runners()

    intent_meta = {
        "container_intent": str(CONTAINER_INTENT),
        "bsd_sources": str(BSD_SOURCES),
        "host_runner_catalog": str(HOST_RUNNERS),
        "registry_base": REGISTRY_BASE,
        "token_service": TOKEN_URL,
    }

    containers: list[dict[str, Any]] = []
    for family in container_intent:
        token = fetch_registry_token(family["repository"])
        for release in family["releases"]:
            manifest_url, content_type, digest, payload = fetch_manifest_index(
                family["repository"], release["tag"], token
            )
            discovered_arches = extract_architectures(payload)
            containers.append(
                {
                    "family": family["family"],
                    "repository": family["repository"],
                    "repository_url": family["repository_url"],
                    "platform_id": release["platform_id"],
                    "platform_os": release["platform_os"],
                    "platform_version": release["platform_version"],
                    "image": f"{family['repository']}:{release['tag']}",
                    "deps": release["deps"],
                    "intended_arches": [arch for arch in release["arches"]],
                    "manifest_url": manifest_url,
                    "content_type": content_type,
                    "digest": digest,
                    "discovered_arches": discovered_arches,
                    "host_support": {
                        arch: {
                            "runtime_preference": list(family["runtime_preference"]),
                            "runner": None,
                        }
                        for arch in release["arches"]
                    },
                }
            )

    vms: list[dict[str, Any]] = []
    for platform_id, entry in bsd_sources.items():
        record = {
            "platform_id": platform_id,
            "os": entry["os"],
            "version": entry["version"],
            "arch": entry["arch"],
            "provider": entry.get("provider", "cross-platform-actions"),
        }
        if "repo" in entry:
            repo = entry["repo"]
            release = fetch_latest_release(repo)
            asset_name = f"{entry['os']}-{entry['version']}-{entry['arch']}.qcow2"
            assets = release.get("assets", [])
            asset = next(
                (a for a in assets if a.get("name") == asset_name), None
            )
            if not asset:
                raise SystemExit(
                    f"No asset named '{asset_name}' in release {release.get('tag_name')} for {repo}"
                )
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
        if "runner_label" in entry:
            record["runner_label"] = entry["runner_label"]
        vms.append(record)

    runners = [dict(runner) for runner in host_runners]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(render_yaml(intent_meta, containers, vms, runners), encoding="utf-8")


if __name__ == "__main__":
    export_catalog()
