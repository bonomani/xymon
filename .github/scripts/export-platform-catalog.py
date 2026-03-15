#!/usr/bin/env python3
"""Export raw Docker availability and repo-scoped platform availability."""

from __future__ import annotations

import json
import os
import re
import argparse
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
CONTAINER_INTENT = ROOT / "ci" / "deps" / "platform-intent.yaml"
PLATFORM_CATALOG = ROOT / "ci" / "deps" / "platform-catalog.yaml"
PLATFORM_RELEASE_OVERRIDES = ROOT / "ci" / "deps" / "platform-release-overrides.yaml"
BSD_SOURCES = ROOT / "ci" / "deps" / "platform-bsd-sources.yaml"
HOST_RUNNERS = ROOT / "ci" / "deps" / "platform-host-runners.yaml"
DISCOVERED_RELEASES_OUTPUT = ROOT / ".github" / "data" / "platform-releases-discovered.yml"
HOST_RUNNERS_DISCOVERED = ROOT / ".github" / "data" / "host-runners-discovered.yml"
DOCKER_AVAILABILITY_OUTPUT = ROOT / ".github" / "data" / "docker-availability-raw.yml"
PLATFORM_AVAILABILITY_OUTPUT = ROOT / ".github" / "data" / "platform-availability.yml"
REGISTRY_BASE = "https://registry-1.docker.io"
TOKEN_URL = "https://auth.docker.io/token"
DOCKER_HUB_TAG_API = "https://hub.docker.com/v2/namespaces/{namespace}/repositories/{repository}/tags/{tag}"
DOCKER_HUB_TAGS_API = "https://hub.docker.com/v2/namespaces/{namespace}/repositories/{repository}/tags?page_size=100&page={page}"
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
        "container_emulated_arches": [],
    },
    "macos": {
        "native_platforms": ["macos"],
        "container_platforms": [],
        "container_emulated_arches": [],
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


def optional_field_str_list(parent: dict[str, Any], key: str, context: str) -> list[str]:
    raw_value = parent.get(key, [])
    values = as_list(raw_value, f"{context}.{key}")
    return [as_str(value, f"{context}.{key}[]") for value in values]


def relative_to_root(path: Path) -> str:
    return str(path.relative_to(ROOT))


def load_yaml(path: Path, context: str) -> dict[str, Any]:
    if not path.exists():
        raise SystemExit(f"Missing {context}: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return as_map(data, context)


def load_existing_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        return {}
    return data


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


def fetch_tag_metadata(repository: str, tag: str) -> tuple[str, str, str, dict[str, Any]]:
    namespace, image = repository.split("/", 1)
    tag_url = DOCKER_HUB_TAG_API.format(namespace=namespace, repository=image, tag=tag)
    request = Request(tag_url, headers={"User-Agent": USER_AGENT})
    with urlopen(request) as response:
        payload = json.load(response)
    digest = str(payload.get("digest") or "")
    return (
        tag_url,
        str(payload.get("content_type") or ""),
        digest,
        payload,
    )


def fetch_repository_tags(repository: str) -> list[dict[str, Any]]:
    namespace, image = repository.split("/", 1)
    page = 1
    results: list[dict[str, Any]] = []
    while True:
        tags_url = DOCKER_HUB_TAGS_API.format(
            namespace=namespace, repository=image, page=page
        )
        request = Request(tags_url, headers={"User-Agent": USER_AGENT})
        with urlopen(request) as response:
            payload = json.load(response)
        page_results = payload.get("results")
        if not isinstance(page_results, list) or not page_results:
            break
        for entry in page_results:
            if isinstance(entry, dict):
                results.append(entry)
        next_url = payload.get("next")
        if not next_url:
            break
        page += 1
    return results


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


def extract_architectures_from_tag_metadata(payload: dict[str, Any]) -> list[str]:
    images = payload.get("images")
    if not isinstance(images, list):
        return []
    archs: list[str] = []
    for image in images:
        if not isinstance(image, dict):
            continue
        arch = normalize_manifest_architecture(image)
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


def optional_alias_of(entry: dict[str, Any], context: str) -> str | None:
    raw_value = entry.get("alias_of")
    if raw_value is None:
        return None
    return as_str(raw_value, f"{context}.alias_of")


def version_key(value: str) -> tuple[int, tuple[int, ...], str]:
    numbers = tuple(int(part) for part in re.findall(r"\d+", value))
    return (1 if numbers else 0, numbers, value)


def infer_platform_os(platform_id: str) -> str:
    platform_id = str(platform_id).strip()
    if platform_id.startswith("opensuse-tumbleweed"):
        return "opensuse_tumbleweed"
    if platform_id.startswith("opensuse-leap-"):
        return "opensuse_leap"
    return platform_id.split("-", 1)[0]


def load_static_platform_catalog() -> dict[str, dict[str, Any]]:
    data = load_yaml(PLATFORM_CATALOG, f"platform catalog in {PLATFORM_CATALOG}")
    platforms = field_map(data, "platforms", str(PLATFORM_CATALOG))
    normalized: dict[str, dict[str, Any]] = {}
    for platform_id, raw_entry in platforms.items():
        entry = as_map(raw_entry, f"{PLATFORM_CATALOG}.platforms.{platform_id}")
        normalized[str(platform_id)] = entry
    return normalized


def load_platform_releases() -> dict[str, dict[str, Any]]:
    data = load_yaml(
        PLATFORM_RELEASE_OVERRIDES,
        f"platform release overrides in {PLATFORM_RELEASE_OVERRIDES}",
    )
    platforms = field_map(data, "platforms", str(PLATFORM_RELEASE_OVERRIDES))
    normalized: dict[str, dict[str, Any]] = {}
    for platform_id, raw_entry in platforms.items():
        entry = as_map(raw_entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}")
        normalized[str(platform_id)] = entry
    return normalized


def load_bsd_sources() -> dict[str, dict[str, Any]]:
    data = load_yaml(BSD_SOURCES, f"BSD sources in {BSD_SOURCES}")
    sources = field_map(data, "sources", str(BSD_SOURCES))
    normalized: dict[str, dict[str, Any]] = {}
    for platform_id, raw_entry in sources.items():
        entry = as_map(raw_entry, f"{BSD_SOURCES}.sources.{platform_id}")
        normalized[str(platform_id)] = entry
    return normalized


def load_selection_policy() -> dict[str, dict[str, set[str]]]:
    data = load_yaml(CONTAINER_INTENT, f"platform intent in {CONTAINER_INTENT}")
    policy: dict[str, dict[str, set[str]]] = {}
    for section in ("containers", "vms", "hosts"):
        raw_section = data.get(section, {})
        if not isinstance(raw_section, dict):
            continue
        selection = raw_section.get("selection", {})
        if not isinstance(selection, dict):
            continue
        include_ids = selection.get("include_platform_ids", [])
        exclude_ids = selection.get("exclude_platform_ids", [])
        if include_ids is None:
            include_ids = []
        if exclude_ids is None:
            exclude_ids = []
        include_set = {
            as_str(value, f"{CONTAINER_INTENT}.{section}.selection.include_platform_ids[]")
            for value in as_list(include_ids, f"{CONTAINER_INTENT}.{section}.selection.include_platform_ids")
        } if include_ids != [] else set()
        exclude_set = {
            as_str(value, f"{CONTAINER_INTENT}.{section}.selection.exclude_platform_ids[]")
            for value in as_list(exclude_ids, f"{CONTAINER_INTENT}.{section}.selection.exclude_platform_ids")
        } if exclude_ids != [] else set()
        tag_patterns = {}
        raw_patterns = selection.get("tag_patterns", {})
        if raw_patterns not in (None, {}):
            raw_patterns = as_map(
                raw_patterns, f"{CONTAINER_INTENT}.{section}.selection.tag_patterns"
            )
            for platform_os, patterns in raw_patterns.items():
                os_key = as_str(
                    platform_os,
                    f"{CONTAINER_INTENT}.{section}.selection.tag_patterns key",
                )
                compiled = [
                    re.compile(
                        as_str(
                            pattern,
                            f"{CONTAINER_INTENT}.{section}.selection.tag_patterns.{os_key}[]",
                        )
                    )
                    for pattern in as_list(
                        patterns,
                        f"{CONTAINER_INTENT}.{section}.selection.tag_patterns.{os_key}",
                    )
                ]
                tag_patterns[os_key] = compiled
        policy[section] = {
            "include": include_set,
            "exclude": exclude_set,
            "tag_patterns": tag_patterns,
        }
    return policy


def selection_allows(
    policy: dict[str, dict[str, set[str]]],
    section: str,
    platform_id: str,
) -> bool:
    section_policy = policy.get(section, {})
    include_ids = section_policy.get("include", set())
    exclude_ids = section_policy.get("exclude", set())
    if platform_id in exclude_ids:
        return False
    if include_ids and platform_id not in include_ids:
        return False
    return True


def selection_section_for_runtime(runtime: str) -> str | None:
    normalized = str(runtime).strip().lower()
    if normalized == "docker":
        return "containers"
    if normalized == "vm":
        return "vms"
    if normalized == "host":
        return "hosts"
    return None


def tag_allowed(
    policy: dict[str, dict[str, set[str]]],
    section: str,
    platform_os: str,
    tag: str,
) -> bool:
    section_policy = policy.get(section, {})
    tag_patterns = section_policy.get("tag_patterns", {})
    patterns = tag_patterns.get(platform_os, [])
    if not patterns:
        return True
    return any(pattern.match(tag) for pattern in patterns)


def derive_platform_id(platform_os: str, tag: str) -> str:
    if platform_os == "opensuse_tumbleweed" and tag == "latest":
        return "opensuse-tumbleweed"
    if platform_os == "opensuse_leap":
        return f"opensuse-leap-{tag.replace('.', '_')}"
    return f"{platform_os}-{tag.replace('.', '_')}"


def discover_docker_releases(
    platform_catalog: dict[str, dict[str, Any]],
    selection_policy: dict[str, dict[str, set[str]]],
) -> dict[str, dict[str, Any]]:
    discovered: dict[str, dict[str, Any]] = {}
    for platform_os, entry in sorted(platform_catalog.items()):
        if str(entry.get("runtime", "")).lower() != "docker":
            continue
        repository = field_str(entry, "repository", f"{PLATFORM_CATALOG}.platforms.{platform_os}")
        for raw_tag_entry in fetch_repository_tags(repository):
            tag = str(raw_tag_entry.get("name") or "").strip()
            if not tag:
                continue
            if not tag_allowed(selection_policy, "containers", platform_os, tag):
                continue
            platform_id = derive_platform_id(platform_os, tag)
            record = {
                "runtime": "docker",
                "platform_os": platform_os,
                "platform_version": tag,
                "image": f"{repository.split('/', 1)[1] if repository.startswith('library/') else repository}:{tag}",
            }
            discovered[platform_id] = record
    return discovered


def discover_vm_releases(
    platform_catalog: dict[str, dict[str, Any]],
    bsd_sources: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    vm_platform_oses = {
        platform_os
        for platform_os, entry in platform_catalog.items()
        if str(entry.get("runtime", "")).strip().lower() == "vm"
    }
    discovered: dict[str, dict[str, Any]] = {}
    for platform_id, entry in sorted(bsd_sources.items()):
        platform_os = field_str(entry, "os", f"{BSD_SOURCES}.sources.{platform_id}")
        if platform_os not in vm_platform_oses:
            continue
        version = field_str(entry, "version", f"{BSD_SOURCES}.sources.{platform_id}")
        repo = field_str(entry, "repo", f"{BSD_SOURCES}.sources.{platform_id}")
        source_arch = field_str(entry, "arch", f"{BSD_SOURCES}.sources.{platform_id}")
        discovered[platform_id] = {
            "runtime": "vm",
            "platform_os": platform_os,
            "platform_version": version,
            "provider": "cross-platform-actions",
            "repo": repo,
            "source_arch": source_arch,
        }
    return discovered


def discover_host_releases(
    platform_catalog: dict[str, dict[str, Any]],
    host_runners: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    host_platform_oses = {
        platform_os
        for platform_os, entry in platform_catalog.items()
        if str(entry.get("runtime", "")).strip().lower() == "host"
    }
    discovered: dict[str, dict[str, Any]] = {}
    for runner in host_runners:
        platform_os = field_str(runner, "platform_os", f"{HOST_RUNNERS} runner {runner}")
        if platform_os not in host_platform_oses:
            continue
        runner_label = field_str(runner, "label", f"{HOST_RUNNERS} runner {runner}")
        version = field_str(runner, "platform_version", f"{HOST_RUNNERS} runner {runner}")
        discovered[runner_label] = {
            "runtime": "host",
            "platform_os": platform_os,
            "platform_version": version,
            "provider": "github-actions",
            "runner": runner_label,
            "deps": {"key": version},
        }
        raw_aliases = runner.get("aliases", [])
        if raw_aliases is None:
            continue
        aliases = as_list(raw_aliases, f"{HOST_RUNNERS} runner {runner_label}.aliases")
        for alias in aliases:
            alias_label = as_str(alias, f"{HOST_RUNNERS} runner {runner_label}.aliases[]")
            discovered[alias_label] = {
                "runtime": "host",
                "platform_os": platform_os,
                "platform_version": alias_label.rsplit("-", 1)[-1],
                "provider": "github-actions",
                "runner": alias_label,
                "alias_of": runner_label,
                "deps": {"key": alias_label.rsplit("-", 1)[-1]},
            }
    return discovered


def select_platform_releases(
    platform_releases: dict[str, dict[str, Any]],
    selection_policy: dict[str, dict[str, set[str]]],
) -> dict[str, dict[str, Any]]:
    selected: dict[str, dict[str, Any]] = {}
    for platform_id, entry in sorted(platform_releases.items()):
        section = selection_section_for_runtime(entry.get("runtime", ""))
        if section and not selection_allows(selection_policy, section, platform_id):
            continue
        selected[platform_id] = entry
    return selected


def load_docker_platform_entries(
    platform_releases: dict[str, dict[str, Any]],
    platform_catalog: dict[str, dict[str, Any]],
    selection_policy: dict[str, dict[str, set[str]]],
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for platform_id, entry in sorted(platform_releases.items()):
        if str(entry.get("runtime", "")).lower() != "docker":
            continue
        if not selection_allows(selection_policy, "containers", platform_id):
            continue
        platform_os = str(entry.get("platform_os") or infer_platform_os(platform_id)).lower()
        catalog_entry = as_map(
            platform_catalog.get(platform_os),
            f"{PLATFORM_CATALOG}.platforms.{platform_os}",
        )
        deps = dict(field_map(catalog_entry, "deps", f"{PLATFORM_CATALOG}.platforms.{platform_os}"))
        release_deps = entry.get("deps")
        if release_deps is not None:
            deps.update(
                as_map(
                    release_deps,
                    f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}.deps",
                )
            )
        image = field_str(
            entry, "image", f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
        )
        repository, tag = image_repository_and_tag(image)
        entries.append(
            {
                "platform_id": platform_id,
                "platform_os": platform_os,
                "platform_family": "linux",
                "platform_version": platform_version_for(
                    entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}", tag
                ),
                "image": image,
                "repository": repository,
                "repository_url": repository_url(repository),
                "tag": tag,
                "deps": deps,
                "alias_of": optional_alias_of(
                    entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
                ),
            }
        )
    return entries


def load_vm_release_entries(
    platform_releases: dict[str, dict[str, Any]],
    _platform_catalog: dict[str, dict[str, Any]],
    selection_policy: dict[str, dict[str, set[str]]],
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    release_lookup = platform_releases
    for platform_id, entry in sorted(platform_releases.items()):
        if str(entry.get("runtime", "")).lower() != "vm":
            continue
        if not selection_allows(selection_policy, "vms", platform_id):
            continue
        alias_of = None
        resolved_version = None
        alias_of = optional_alias_of(
            entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
        )
        if alias_of:
            alias_entry = release_lookup.get(alias_of, {})
            if isinstance(alias_entry, dict):
                alias_deps = alias_entry.get("deps")
                if isinstance(alias_deps, dict):
                    alias_version = alias_deps.get("key")
                    if isinstance(alias_version, (str, int, float)):
                        resolved_version = str(alias_version)
        source_arch = field_str(
            entry, "source_arch", f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
        )
        selected.append(
            {
                "platform_id": platform_id,
                "os": field_str(
                    entry,
                    "platform_os",
                    f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}",
                ),
                "version": field_str(
                    entry,
                    "platform_version",
                    f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}",
                ),
                "provider": str(entry.get("provider", "cross-platform-actions")),
                "source_arch": source_arch,
                "discovered_arches": [normalize_declared_architecture(source_arch)],
                "repo": entry.get("repo"),
                "runner_label": entry.get("runner_label"),
                "alias_of": alias_of,
                "resolved_version": resolved_version,
            }
        )
    return selected


def load_host_release_entries(
    platform_releases: dict[str, dict[str, Any]],
    selection_policy: dict[str, dict[str, set[str]]],
) -> dict[str, dict[str, Any]]:
    selected: dict[str, dict[str, Any]] = {}
    for platform_id, entry in sorted(platform_releases.items()):
        if str(entry.get("runtime", "")).lower() != "host":
            continue
        if not selection_allows(selection_policy, "hosts", platform_id):
            continue
        selected[platform_id] = {
            "provider": field_str(
                entry, "provider", f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
            ),
            "runner": field_str(
                entry, "runner", f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
            ),
            **(
                {
                    "alias_of": optional_alias_of(
                        entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
                    )
                }
                if optional_alias_of(
                    entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
                )
                else {}
            ),
        }
    return selected


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


def runner_container_emulated_arches(runner: dict[str, Any]) -> list[str]:
    capabilities = runner_capabilities(runner)
    return optional_field_str_list(
        capabilities,
        "container_emulated_arches",
        "capabilities",
    )


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


def unique_preserving_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def exact_direct_runner_labels(
    runners: list[dict[str, Any]],
    *,
    platform_family: str,
    platform_os: str,
    platform_version: str,
    arch: str,
) -> list[str]:
    labels: list[str] = []
    for runner in runners:
        if normalize_runner_architecture(runner) != arch:
            continue
        if field_str(runner, "machine_family", f"runner {runner['label']}") != platform_family:
            continue
        if not runner_supports(runner, "native_platforms", platform_family):
            continue
        if field_str(runner, "platform_os", f"runner {runner['label']}") != platform_os:
            continue
        if field_str(runner, "platform_version", f"runner {runner['label']}") != platform_version:
            continue
        labels.append(runner["label"])
    return labels


def build_host_support(
    arches: list[str],
    *,
    runners: list[dict[str, Any]],
    runner_indexes: dict[str, dict[str, dict[str, list[str]]]],
    platform_family: str,
    platform_os: str,
    platform_version: str,
) -> dict[str, dict[str, Any]]:
    family_indexes = runner_indexes.get(platform_family, {})
    container_index = family_indexes.get("container", {})
    host_support: dict[str, dict[str, Any]] = {}
    for arch in arches:
        direct_labels = exact_direct_runner_labels(
            runners,
            platform_family=platform_family,
            platform_os=platform_os,
            platform_version=platform_version,
            arch=arch,
        )
        emulated_container_labels = [
            runner["label"]
            for runner in runners
            if field_str(runner, "machine_family", f"runner {runner['label']}")
            == platform_family
            and runner_supports(runner, "container_platforms", platform_family)
            and arch in runner_container_emulated_arches(runner)
        ]
        container_labels = unique_preserving_order(
            list(container_index.get(arch, [])) + emulated_container_labels
        )
        record: dict[str, Any] = {"direct_runner_labels": direct_labels}
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
        optional_field_str_list(
            capabilities,
            "container_emulated_arches",
            f"{entry_ctx}.capabilities",
        )
        normalized.append(entry.copy())
    return normalized


def render_mapping_yaml(intent_meta: dict[str, Any], platforms: dict[str, Any]) -> str:
    payload = {
        "source": intent_meta,
        "platforms": platforms,
    }
    return yaml.safe_dump(payload, sort_keys=False)


def build_cached_container_index(existing_catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    platforms = existing_catalog.get("platforms")
    if not isinstance(platforms, dict):
        return {}

    cached: dict[str, dict[str, Any]] = {}
    for raw_entry in platforms.values():
        if not isinstance(raw_entry, dict):
            continue
        image = raw_entry.get("image")
        if not isinstance(image, str) or not image:
            continue
        discovered_arches = raw_entry.get("discovered_arches")
        if not isinstance(discovered_arches, list) or not discovered_arches:
            continue
        cached[image] = raw_entry
    return cached


def build_cached_vm_index(existing_catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    platforms = existing_catalog.get("platforms")
    if not isinstance(platforms, dict):
        return {}

    cached: dict[str, dict[str, Any]] = {}
    for platform_id, raw_entry in platforms.items():
        if not isinstance(raw_entry, dict):
            continue
        if str(raw_entry.get("runtime", "")).strip().lower() != "vm":
            continue
        cached[str(platform_id)] = raw_entry
    return cached


def build_host_discovery_index(existing_catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    runners = existing_catalog.get("runners")
    if not isinstance(runners, dict):
        return {}
    return {
        str(label): entry
        for label, entry in runners.items()
        if isinstance(label, str) and isinstance(entry, dict)
    }


def normalize_host_discovery_capabilities(discovery: dict[str, Any]) -> dict[str, Any]:
    container = discovery.get("container", {})
    virtualization = discovery.get("virtualization", {})
    tools = discovery.get("tools", {})

    def tool_present(name: str) -> bool:
        entry = tools.get(name, {})
        return isinstance(entry, dict) and bool(entry.get("present"))

    dev_kvm_exists = bool(virtualization.get("dev_kvm_exists"))
    dev_kvm_readable = bool(virtualization.get("dev_kvm_readable"))
    dev_kvm_writable = bool(virtualization.get("dev_kvm_writable"))
    nested_state = str(virtualization.get("nested", "")).strip().lower()

    return {
        "container_runtime_available": bool(container.get("docker_socket")),
        "binfmt_misc_available": bool(container.get("binfmt_misc_mounted")),
        "container_tooling": {
            "docker": tool_present("docker"),
            "podman": tool_present("podman"),
        },
        "emulation_tooling": {
            "qemu_system_x86_64": tool_present("qemu-system-x86_64"),
            "qemu_aarch64_static": tool_present("qemu-aarch64-static"),
        },
        "virtualization": {
            "kvm_device_present": dev_kvm_exists,
            "kvm_accessible": dev_kvm_exists and dev_kvm_readable and dev_kvm_writable,
            "nested_state": nested_state or "unknown",
            "nested_enabled": nested_state == "enabled",
        },
    }


def build_host_runner_lookup(runners: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    lookup: dict[str, dict[str, Any]] = {}
    for runner in runners:
        label = field_str(runner, "label", f"runner {runner}")
        lookup[label] = runner
        raw_aliases = runner.get("aliases", [])
        if raw_aliases is None:
            continue
        aliases = as_list(raw_aliases, f"runner {label}.aliases")
        for alias in aliases:
            alias_label = as_str(alias, f"runner {label}.aliases[]")
            lookup.setdefault(alias_label, runner)
    return lookup


def build_platform_availability(
    platform_releases: dict[str, dict[str, Any]],
    docker_platforms: dict[str, dict[str, Any]],
    vm_entries: list[dict[str, Any]],
    host_entries: dict[str, dict[str, Any]],
    host_runners: list[dict[str, Any]],
    host_runner_discovery: dict[str, dict[str, Any]],
    runner_indexes: dict[str, dict[str, dict[str, list[str]]]],
) -> dict[str, dict[str, Any]]:
    vm_by_platform_id = {entry["platform_id"]: entry for entry in vm_entries}
    host_runner_lookup = build_host_runner_lookup(host_runners)
    availability: dict[str, dict[str, Any]] = {}

    for platform_id, entry in sorted(platform_releases.items()):
        runtime = str(entry.get("runtime", "")).strip().lower()
        if runtime == "docker":
            docker_entry = docker_platforms.get(platform_id)
            if docker_entry is None:
                raise SystemExit(
                    f"Missing docker availability entry for platform '{platform_id}'"
                )
            availability[platform_id] = {
                "runtime": "docker",
                "platform_os": docker_entry["platform_os"],
                "platform_version": docker_entry["platform_version"],
                "image": docker_entry["image"],
                "digest": docker_entry["digest"],
                "discovered_arches": list(docker_entry["discovered_arches"]),
                "host_support": build_host_support(
                    list(docker_entry["discovered_arches"]),
                    runners=host_runners,
                    runner_indexes=runner_indexes,
                    platform_family="linux",
                    platform_os=docker_entry["platform_os"],
                    platform_version=docker_entry["platform_version"],
                ),
                **(
                    {"alias_of": docker_entry["alias_of"]}
                    if docker_entry.get("alias_of")
                    else {}
                ),
            }
            continue

        if runtime == "vm":
            vm_entry = vm_by_platform_id.get(platform_id)
            if vm_entry is None:
                raise SystemExit(
                    f"Missing VM availability entry for platform '{platform_id}'"
                )
            record = {
                "runtime": "vm",
                "platform_os": vm_entry["os"],
                "provider": vm_entry["provider"],
                "os": vm_entry["os"],
                "version": vm_entry["version"],
                "source_arch": vm_entry["source_arch"],
                "discovered_arches": list(vm_entry["discovered_arches"]),
            }
            for key in (
                "repo",
                "release_tag",
                "release_url",
                "asset_name",
                "asset_url",
                "asset_size",
                "asset_updated_at",
                "runner_label",
                "alias_of",
                "resolved_version",
            ):
                if vm_entry.get(key) not in (None, ""):
                    record[key] = vm_entry[key]
            availability[platform_id] = record
            continue

        if runtime == "host":
            host_entry = host_entries.get(platform_id)
            if host_entry is None:
                raise SystemExit(
                    f"Missing host release entry for platform '{platform_id}'"
                )
            provider = field_str(host_entry, "provider", f"platform releases '{platform_id}'")
            runner_label = field_str(host_entry, "runner", f"platform releases '{platform_id}'")
            runner = host_runner_lookup.get(runner_label)
            if runner is None:
                raise SystemExit(
                    f"Missing host runner metadata for platform '{platform_id}' runner '{runner_label}'"
                )
            record = {
                "runtime": "host",
                "provider": provider,
                "runner_label": runner_label,
                "resolved_runner_label": field_str(
                    runner, "label", f"runner {runner_label}"
                ),
                "platform_os": field_str(runner, "platform_os", f"runner {runner_label}"),
                "platform_version": field_str(
                    runner, "platform_version", f"runner {runner_label}"
                ),
                "discovered_arches": [normalize_runner_architecture(runner)],
            }
            for key in ("availability", "resources", "source"):
                if runner.get(key) is not None:
                    record[key] = runner.get(key)
            discovered_runner = host_runner_discovery.get(runner_label, {})
            if discovered_runner:
                raw_discovery = dict(discovered_runner)
                raw_discovery.pop("capabilities", None)
                record["capabilities"] = normalize_host_discovery_capabilities(
                    discovered_runner
                )
                record["discovery"] = raw_discovery
            alias_of = optional_alias_of(
                host_entry, f"{PLATFORM_RELEASE_OVERRIDES}.platforms.{platform_id}"
            )
            if alias_of:
                record["alias_of"] = alias_of
            availability[platform_id] = record
            continue

        raise SystemExit(f"Unsupported runtime '{runtime}' for platform '{platform_id}'")

    return availability


def export_catalog(*, refresh_container_manifests: bool = False):
    platform_catalog = load_static_platform_catalog()
    selection_policy = load_selection_policy()
    static_platform_releases = load_platform_releases()
    bsd_sources = load_bsd_sources()
    host_runners = load_host_runners()
    discovered_docker_releases = discover_docker_releases(platform_catalog, selection_policy)
    discovered_vm_releases = discover_vm_releases(platform_catalog, bsd_sources)
    discovered_host_releases = discover_host_releases(platform_catalog, host_runners)
    all_platform_releases = {
        **discovered_vm_releases,
        **discovered_host_releases,
        **discovered_docker_releases,
    }
    discovered_docker_by_image = {
        str(entry.get("image")): platform_id
        for platform_id, entry in all_platform_releases.items()
        if str(entry.get("runtime", "")).lower() == "docker"
        and isinstance(entry.get("image"), str)
        and str(entry.get("image"))
    }
    for platform_id, entry in static_platform_releases.items():
        if str(entry.get("runtime", "")).lower() != "docker":
            continue
        if platform_id in all_platform_releases:
            merged_entry = dict(all_platform_releases[platform_id])
            merged_entry.update(entry)
            all_platform_releases[platform_id] = merged_entry
            continue
        image = entry.get("image")
        if not isinstance(image, str) or not image:
            continue
        discovered_platform_id = discovered_docker_by_image.get(image)
        if discovered_platform_id is None:
            continue
        merged_entry = dict(all_platform_releases[discovered_platform_id])
        merged_entry.update(entry)
        all_platform_releases[platform_id] = merged_entry
        del all_platform_releases[discovered_platform_id]
    platform_releases = select_platform_releases(all_platform_releases, selection_policy)
    docker_entries = load_docker_platform_entries(
        platform_releases, platform_catalog, selection_policy
    )
    vm_entries = load_vm_release_entries(
        platform_releases, platform_catalog, selection_policy
    )
    host_entries = load_host_release_entries(platform_releases, selection_policy)
    runner_indexes = build_runner_indexes(host_runners)
    existing_platform_availability = load_existing_yaml(PLATFORM_AVAILABILITY_OUTPUT)
    host_runner_discovery = build_host_discovery_index(
        load_existing_yaml(HOST_RUNNERS_DISCOVERED)
    )
    cached_containers = build_cached_container_index(
        load_existing_yaml(DOCKER_AVAILABILITY_OUTPUT)
    )
    cached_vm_platforms = build_cached_vm_index(existing_platform_availability)

    docker_availability_meta = {
        "platform_catalog": relative_to_root(PLATFORM_CATALOG),
        "platform_release_overrides": relative_to_root(PLATFORM_RELEASE_OVERRIDES),
        "platform_releases_discovered": relative_to_root(DISCOVERED_RELEASES_OUTPUT),
        "platform_intent": relative_to_root(CONTAINER_INTENT),
        "registry_base": REGISTRY_BASE,
        "token_service": TOKEN_URL,
        "container_cache_mode": "refresh" if refresh_container_manifests else "reuse",
    }

    docker_platforms: dict[str, dict[str, Any]] = {}
    token_by_repository: dict[str, str] = {}
    for release in docker_entries:
        image = release["image"]
        repository = release["repository"]
        cached_entry = None if refresh_container_manifests else cached_containers.get(image)
        if cached_entry is None:
            token = token_by_repository.get(repository)
            if not token:
                token = fetch_registry_token(repository)
                token_by_repository[repository] = token
            try:
                manifest_url, content_type, digest, payload = fetch_manifest_index(
                    repository, release["tag"], token
                )
                discovered_arches = extract_architectures(payload)
            except HTTPError as exc:
                if exc.code != 429:
                    raise
                manifest_url, content_type, digest, payload = fetch_tag_metadata(
                    repository, release["tag"]
                )
                discovered_arches = extract_architectures_from_tag_metadata(payload)
        else:
            manifest_url = str(cached_entry.get("manifest_url", ""))
            content_type = str(cached_entry.get("content_type", ""))
            digest = str(cached_entry.get("digest", ""))
            discovered_arches = [str(arch) for arch in cached_entry.get("discovered_arches", [])]
        docker_platforms[release["platform_id"]] = {
            "image": image,
            "repository": release["repository"],
            "repository_url": release["repository_url"],
            "tag": release["tag"],
            "platform_os": release["platform_os"],
            "platform_version": release["platform_version"],
            "deps": release["deps"],
            "manifest_url": manifest_url,
            "content_type": content_type,
            "digest": digest,
            "discovered_arches": discovered_arches,
            **({"alias_of": release["alias_of"]} if release.get("alias_of") else {}),
        }

    resolved_vm_platforms: list[dict[str, Any]] = []
    for entry in vm_entries:
        platform_id = entry["platform_id"]
        record = {
            "platform_id": platform_id,
            "os": entry["os"],
            "version": entry["version"],
            "source_arch": entry["source_arch"],
            "discovered_arches": list(entry["discovered_arches"]),
            "provider": entry["provider"],
        }
        if entry.get("repo"):
            repo = entry["repo"]
            asset_name = f"{entry['os']}-{entry['version']}-{entry['source_arch']}.qcow2"
            cached_vm_entry = cached_vm_platforms.get(platform_id, {})
            try:
                release = fetch_latest_release(repo)
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
            except SystemExit as exc:
                if "HTTP Error 403" not in str(exc) or not isinstance(cached_vm_entry, dict):
                    raise
                record.update(
                    {
                        "repo": repo,
                        "release_tag": cached_vm_entry.get("release_tag"),
                        "release_url": cached_vm_entry.get("release_url"),
                        "asset_name": cached_vm_entry.get("asset_name", asset_name),
                        "asset_url": cached_vm_entry.get("asset_url"),
                        "asset_size": cached_vm_entry.get("asset_size"),
                        "asset_updated_at": cached_vm_entry.get("asset_updated_at"),
                    }
                )
        if entry.get("runner_label"):
            record["runner_label"] = entry["runner_label"]
        if entry.get("alias_of"):
            record["alias_of"] = entry["alias_of"]
        if entry.get("resolved_version"):
            record["resolved_version"] = entry["resolved_version"]
        resolved_vm_platforms.append(record)

    platform_availability_meta = {
        "platform_catalog": relative_to_root(PLATFORM_CATALOG),
        "platform_release_overrides": relative_to_root(PLATFORM_RELEASE_OVERRIDES),
        "platform_releases_discovered": relative_to_root(DISCOVERED_RELEASES_OUTPUT),
        "platform_intent": relative_to_root(CONTAINER_INTENT),
        "docker_availability_raw": relative_to_root(DOCKER_AVAILABILITY_OUTPUT),
        "host_runner_catalog": relative_to_root(HOST_RUNNERS),
        "host_runner_discovery": relative_to_root(HOST_RUNNERS_DISCOVERED),
    }
    platform_availability = build_platform_availability(
        platform_releases,
        docker_platforms,
        resolved_vm_platforms,
        host_entries,
        host_runners,
        host_runner_discovery,
        runner_indexes,
    )

    DOCKER_AVAILABILITY_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    DISCOVERED_RELEASES_OUTPUT.write_text(
        render_mapping_yaml(
            {
                "platform_catalog": relative_to_root(PLATFORM_CATALOG),
                "platform_intent": relative_to_root(CONTAINER_INTENT),
                "platform_release_overrides": relative_to_root(PLATFORM_RELEASE_OVERRIDES),
            },
            platform_releases,
        ),
        encoding="utf-8",
    )
    DOCKER_AVAILABILITY_OUTPUT.write_text(
        render_mapping_yaml(docker_availability_meta, docker_platforms),
        encoding="utf-8",
    )
    PLATFORM_AVAILABILITY_OUTPUT.write_text(
        render_mapping_yaml(platform_availability_meta, platform_availability),
        encoding="utf-8",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--refresh-container-manifests",
        action="store_true",
        help="Refresh cached container manifest metadata from Docker Hub instead of reusing cached entries.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    export_catalog(
        refresh_container_manifests=args.refresh_container_manifests
    )
