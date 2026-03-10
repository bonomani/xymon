#!/usr/bin/env python3
"""Discover Docker container images and BSD/macOS VM artifacts in one catalog."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
CONTAINER_INTENT = ROOT / "ci" / "deps" / "platform-intent.yaml"
PLATFORM_CATALOG = ROOT / "ci" / "deps" / "platform-catalog.yaml"
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
DEFAULT_RUNNER_CAPABILITIES = {
    "linux": {
        "native_platforms": ["linux"],
        "container_platforms": ["linux"],
    },
    "macos": {
        "native_platforms": ["macos"],
        "container_platforms": [],
    },
}


def as_map(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SystemExit(f"{context} must be a mapping")
    return value


def as_str(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{context} must be a non-empty string")
    return value.strip()


def as_list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise SystemExit(f"{context} must be a list")
    return value


def field_map(parent: dict[str, Any], key: str, context: str) -> dict[str, Any]:
    return as_map(parent.get(key), f"{context}.{key}")


def field_str(parent: dict[str, Any], key: str, context: str) -> str:
    return as_str(parent.get(key), f"{context}.{key}")


def field_list(parent: dict[str, Any], key: str, context: str) -> list[Any]:
    return as_list(parent.get(key), f"{context}.{key}")


def relative_to_root(path: Path) -> str:
    return str(path.relative_to(ROOT))


def load_yaml(path: Path, context: str) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"Missing {context}: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return as_map(data, context)


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


def normalize_declared_architecture(value: str) -> str:
    normalized = value.strip().lower()
    aliases = {
        "x64": "amd64",
        "x86-64": "amd64",
        "amd64": "amd64",
        "arm64": "arm64",
    }
    return aliases.get(normalized, normalized)


def image_repository_and_tag(image: str) -> tuple[str, str]:
    repository, separator, tag = image.partition(":")
    if not separator:
        raise SystemExit(f"Container image '{image}' is missing a tag")
    if "/" not in repository:
        repository = f"library/{repository}"
    return repository, tag


def repository_url(repository: str) -> str:
    if repository.startswith("library/"):
        return f"https://hub.docker.com/_/{repository.split('/', 1)[1]}"
    return f"https://hub.docker.com/r/{repository}"


def platform_version_for(entry: dict[str, Any], context: str, tag: str) -> str:
    raw_value = entry.get("platform_version")
    if raw_value is None:
        return tag
    return as_str(raw_value, f"{context}.platform_version")


def version_key(value: str) -> tuple[int, tuple[int, ...], str]:
    numbers = tuple(int(part) for part in re.findall(r"\d+", value))
    return (1 if numbers else 0, numbers, value)


def preference_key(image: str, preferred_tokens: list[str]) -> int:
    lowered = image.lower()
    for index, token in enumerate(preferred_tokens):
        if token.lower() in lowered:
            return len(preferred_tokens) - index
    return 0


def load_active_lane_arches(lanes_glob: str) -> dict[str, list[str]]:
    lane_arches: dict[str, list[str]] = {}
    for path in sorted(ROOT.glob(lanes_glob)):
        data = load_yaml(path, f"lane definition in {path}")
        include = field_list(data, "include", str(path))
        for index, raw_entry in enumerate(include):
            entry = as_map(raw_entry, f"{path}.include[{index}]")
            platform_id = field_str(entry, "platform_id", f"{path}.include[{index}]")
            raw_arch = str(entry.get("architecture") or entry.get("defaults") or "amd64")
            arch = normalize_declared_architecture(raw_arch)
            lane_arches.setdefault(platform_id, [])
            if arch not in lane_arches[platform_id]:
                lane_arches[platform_id].append(arch)
    return lane_arches


def load_static_platform_catalog() -> dict[str, dict[str, Any]]:
    data = load_yaml(PLATFORM_CATALOG, f"platform catalog in {PLATFORM_CATALOG}")
    platforms = field_map(data, "platforms", str(PLATFORM_CATALOG))
    normalized: dict[str, dict[str, Any]] = {}
    for platform_id, raw_entry in platforms.items():
        entry = as_map(raw_entry, f"{PLATFORM_CATALOG}.platforms.{platform_id}")
        normalized[str(platform_id)] = entry
    return normalized


def runtime_preferences_for(
    rules: dict[str, Any], platform_os: str
) -> list[str]:
    runtime_preferences = field_map(rules, "runtime_preference", str(CONTAINER_INTENT))
    overrides = runtime_preferences.get("overrides")
    if isinstance(overrides, dict):
        override = overrides.get(platform_os)
        if isinstance(override, list):
            return [str(value) for value in override]
    return [str(value) for value in field_list(runtime_preferences, "default", str(CONTAINER_INTENT))]


def load_container_intent() -> list[dict[str, Any]]:
    rules = load_yaml(CONTAINER_INTENT, f"platform intent rules in {CONTAINER_INTENT}")
    selection = field_map(rules, "selection", str(CONTAINER_INTENT))
    preferred_tokens = [str(value) for value in field_list(selection, "prefer_image_tokens", str(CONTAINER_INTENT))]
    runtime = field_str(selection, "runtime", str(CONTAINER_INTENT))
    group_by = field_str(selection, "group_by", str(CONTAINER_INTENT))
    lanes_glob = field_str(selection, "lanes_glob", str(CONTAINER_INTENT))
    platform_family = field_str(selection, "platform_family", str(CONTAINER_INTENT))
    active_lane_arches = load_active_lane_arches(lanes_glob)
    platform_catalog = load_static_platform_catalog()

    grouped_candidates: dict[str, list[dict[str, Any]]] = {}
    for platform_id, entry in platform_catalog.items():
        if str(entry.get("runtime", "")).lower() != runtime:
            continue
        if platform_id not in active_lane_arches:
            continue
        deps = field_map(entry, "deps", f"{PLATFORM_CATALOG}.platforms.{platform_id}")
        if group_by != "deps.os":
            raise SystemExit(f"Unsupported group_by rule '{group_by}' in {CONTAINER_INTENT}")
        group = field_str(deps, "os", f"{PLATFORM_CATALOG}.platforms.{platform_id}.deps").lower()
        image = field_str(entry, "image", f"{PLATFORM_CATALOG}.platforms.{platform_id}")
        repository, tag = image_repository_and_tag(image)
        grouped_candidates.setdefault(group, []).append(
            {
                "platform_id": platform_id,
                "platform_os": group,
                "platform_family": platform_family,
                "platform_version": platform_version_for(
                    entry, f"{PLATFORM_CATALOG}.platforms.{platform_id}", tag
                ),
                "image": image,
                "repository": repository,
                "repository_url": repository_url(repository),
                "tag": tag,
                "deps": deps,
                "arches": active_lane_arches[platform_id],
                "runtime_preference": runtime_preferences_for(rules, group),
            }
        )

    normalized_families: list[dict[str, Any]] = []
    for group, candidates in grouped_candidates.items():
        selected = max(
            candidates,
            key=lambda candidate: (
                version_key(candidate["platform_version"]),
                preference_key(candidate["image"], preferred_tokens),
                candidate["platform_id"],
            ),
        )
        normalized_families.append(
            {
                "family": group,
                "repository": selected["repository"],
                "repository_url": selected["repository_url"],
                "runtime_preference": selected["runtime_preference"],
                "releases": [
                    {
                        "platform_id": selected["platform_id"],
                        "tag": selected["tag"],
                        "platform_version": selected["platform_version"],
                        "deps": selected["deps"],
                        "platform_os": selected["platform_os"],
                        "platform_family": selected["platform_family"],
                        "arches": selected["arches"],
                    }
                ],
            }
        )
    return sorted(normalized_families, key=lambda family: family["family"])


def load_bsd_sources() -> dict[str, dict[str, Any]]:
    data = load_yaml(BSD_SOURCES, f"BSD sources in {BSD_SOURCES}")
    return field_map(data, "sources", f"{BSD_SOURCES}")


def normalize_runner_architecture(runner: dict[str, Any]) -> str:
    arch = runner.get("arch")
    if not isinstance(arch, str):
        return ""
    return HOST_ARCH_TO_ARCH.get(arch, arch)


def runner_capabilities(runner: dict[str, Any]) -> dict[str, Any]:
    machine_family = field_str(runner, "machine_family", f"runner {runner['label']}")
    capabilities = runner.get("capabilities")
    if capabilities is None:
        default = DEFAULT_RUNNER_CAPABILITIES.get(machine_family)
        if default is None:
            raise SystemExit(f"Unsupported machine_family '{machine_family}' for runner {runner['label']}")
        return default
    return as_map(capabilities, f"runner {runner['label']}.capabilities")


def runner_supports(runner: dict[str, Any], capability_key: str, platform_family: str) -> bool:
    capabilities = runner_capabilities(runner)
    values = [str(value) for value in field_list(capabilities, capability_key, "capabilities")]
    return platform_family in values


def build_runner_indexes(runners: list[dict[str, Any]]) -> dict[str, dict[str, dict[str, list[str]]]]:
    indexes: dict[str, dict[str, dict[str, list[str]]]] = {}
    for runner in runners:
        arch = normalize_runner_architecture(runner)
        if not arch:
            continue
        capabilities = runner_capabilities(runner)
        for mode, capability_key in (("direct", "native_platforms"), ("container", "container_platforms")):
            for platform_family in [str(value) for value in field_list(capabilities, capability_key, "capabilities")]:
                indexes.setdefault(platform_family, {}).setdefault(mode, {}).setdefault(arch, []).append(
                    runner["label"]
                )
    return indexes


def build_host_support(
    runtime_preference: list[str],
    arches: list[str],
    runner_indexes: dict[str, dict[str, dict[str, list[str]]]],
    platform_family: str,
) -> dict[str, dict[str, Any]]:
    family_indexes = runner_indexes.get(platform_family, {})
    direct_index = family_indexes.get("direct", {})
    container_index = family_indexes.get("container", {})
    host_support: dict[str, dict[str, Any]] = {}
    for arch in arches:
        direct_labels = direct_index.get(arch, [])
        container_labels = container_index.get(arch, [])
        record: dict[str, Any] = {
            "runtime_preference": list(runtime_preference),
            "direct_runner_labels": direct_labels,
        }
        if container_labels != direct_labels:
            record["container_runner_labels"] = container_labels
        host_support[arch] = record
    return host_support


def load_host_runners() -> list[dict[str, Any]]:
    data = load_yaml(HOST_RUNNERS, f"host runner catalog in {HOST_RUNNERS}")
    runners = field_list(data, "runners", f"{HOST_RUNNERS}")
    normalized: list[dict[str, Any]] = []
    for idx, runner in enumerate(runners):
        entry_ctx = f"{HOST_RUNNERS} runners[{idx}]"
        entry = as_map(runner, entry_ctx)
        field_str(entry, "label", entry_ctx)
        field_str(entry, "machine_family", entry_ctx)
        field_str(entry, "platform_os", entry_ctx)
        field_str(entry, "platform_version", entry_ctx)
        field_str(entry, "arch", entry_ctx)
        capabilities = runner_capabilities(entry)
        field_list(capabilities, "native_platforms", f"{entry_ctx}.capabilities")
        field_list(capabilities, "container_platforms", f"{entry_ctx}.capabilities")
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
    runner_indexes = build_runner_indexes(host_runners)

    intent_meta = {
        "container_intent": relative_to_root(CONTAINER_INTENT),
        "bsd_sources": relative_to_root(BSD_SOURCES),
        "host_runner_catalog": relative_to_root(HOST_RUNNERS),
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
                    "host_support": build_host_support(
                        family["runtime_preference"],
                        release["arches"],
                        runner_indexes,
                        release["platform_family"],
                    ),
                },
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
