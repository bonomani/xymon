#!/usr/bin/env python3

import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import yaml

REGISTRY_BASE = "https://registry-1.docker.io"
TOKEN_URL = "https://auth.docker.io/token"
INTENT_PATH = Path("ci/deps/platform-intent.yaml")
HOST_RUNNER_CATALOG_PATH = Path(".github/data/github-host-runners.yml")
OUTPUT_PATH = Path(".github/data/container-catalog.yml")
MANIFEST_ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
ARCH_NORMALIZATION = {
    ("amd64", None): "amd64",
    ("arm64", None): "arm64",
    ("arm64", "v8"): "arm64",
    ("arm", "v7"): "arm32v7",
    ("ppc64le", None): "ppc64le",
    ("riscv64", None): "riscv64",
    ("s390x", None): "s390x",
}
HOST_ARCH_TO_INTENT_ARCH = {
    "x64": "amd64",
    "amd64": "amd64",
    "arm64": "arm64",
}


def require_mapping(value, context):
    if not isinstance(value, dict):
        raise SystemExit(f"{context} must be a mapping")
    return value


def require_non_empty_string(value, context):
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{context} must be a non-empty string")
    return value.strip()


def require_string_list(value, context):
    if not isinstance(value, list) or not value:
        raise SystemExit(f"{context} must be a non-empty list")
    normalized = []
    for index, raw in enumerate(value):
        normalized.append(require_non_empty_string(raw, f"{context}[{index}]"))
    return normalized


def load_yaml_mapping(path, context):
    if not path.exists():
        raise SystemExit(f"Missing {context}: {path}")
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return require_mapping(data, context)


def load_intent():
    data = load_yaml_mapping(INTENT_PATH, f"platform intent in {INTENT_PATH}")
    families = require_mapping(data.get("families"), f"{INTENT_PATH} families")

    normalized_families = []
    for name, raw in families.items():
        family = require_mapping(raw, f"{INTENT_PATH} families.{name}")
        repository = require_non_empty_string(
            family.get("repository"), f"{INTENT_PATH} families.{name}.repository"
        )
        repository_url = require_non_empty_string(
            family.get("repository_url"), f"{INTENT_PATH} families.{name}.repository_url"
        )
        runtime_preference = require_string_list(
            family.get("runtime_preference"),
            f"{INTENT_PATH} families.{name}.runtime_preference",
        )
        releases = family.get("releases")
        if not isinstance(releases, list) or not releases:
            raise SystemExit(
                f"{INTENT_PATH} families.{name}.releases must be a non-empty list"
            )

        normalized_releases = []
        for index, raw_release in enumerate(releases):
            entry = require_mapping(
                raw_release,
                f"{INTENT_PATH} families.{name}.releases[{index}]",
            )
            deps = require_mapping(
                entry.get("deps"),
                f"{INTENT_PATH} families.{name}.releases[{index}].deps",
            )
            platform_os = require_non_empty_string(
                deps.get("os"),
                f"{INTENT_PATH} families.{name}.releases[{index}].deps.os",
            ).lower()
            normalized_releases.append(
                {
                    "platform_id": require_non_empty_string(
                        entry.get("platform_id"),
                        f"{INTENT_PATH} families.{name}.releases[{index}].platform_id",
                    ),
                    "tag": require_non_empty_string(
                        entry.get("tag"),
                        f"{INTENT_PATH} families.{name}.releases[{index}].tag",
                    ),
                    "platform_version": require_non_empty_string(
                        entry.get("platform_version"),
                        f"{INTENT_PATH} families.{name}.releases[{index}].platform_version",
                    ),
                    "deps": deps,
                    "platform_os": platform_os,
                    "arches": require_string_list(
                        entry.get("arches"),
                        f"{INTENT_PATH} families.{name}.releases[{index}].arches",
                    ),
                }
            )

        normalized_families.append(
            {
                "family": name,
                "repository": repository,
                "repository_url": repository_url,
                "runtime_preference": runtime_preference,
                "releases": normalized_releases,
            }
        )

    return normalized_families


def load_host_runner_index():
    data = load_yaml_mapping(
        HOST_RUNNER_CATALOG_PATH,
        f"GitHub host runner catalog in {HOST_RUNNER_CATALOG_PATH}",
    )
    runners = data.get("runners")
    if not isinstance(runners, list):
        raise SystemExit(f"{HOST_RUNNER_CATALOG_PATH} runners must be a list")

    index = {}
    for idx, raw in enumerate(runners):
        entry = require_mapping(raw, f"{HOST_RUNNER_CATALOG_PATH} runners[{idx}]")
        platform_os = require_non_empty_string(
            entry.get("platform_os"),
            f"{HOST_RUNNER_CATALOG_PATH} runners[{idx}].platform_os",
        ).lower()
        platform_version = require_non_empty_string(
            entry.get("platform_version"),
            f"{HOST_RUNNER_CATALOG_PATH} runners[{idx}].platform_version",
        )
        arch = require_non_empty_string(
            entry.get("arch"),
            f"{HOST_RUNNER_CATALOG_PATH} runners[{idx}].arch",
        ).lower()
        label = require_non_empty_string(
            entry.get("label"),
            f"{HOST_RUNNER_CATALOG_PATH} runners[{idx}].label",
        )
        normalized_arch = HOST_ARCH_TO_INTENT_ARCH.get(arch)
        if normalized_arch is None:
            continue
        index[(platform_os, platform_version, normalized_arch)] = label
    return index


def fetch_registry_token(repository):
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


def fetch_manifest_index(repository, tag, token):
    manifest_url = f"{REGISTRY_BASE}/v2/{repository}/manifests/{tag}"
    request = Request(
        manifest_url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": MANIFEST_ACCEPT,
        },
    )
    with urlopen(request) as response:
        content_type = response.headers.get("Content-Type", "")
        digest = response.headers.get("docker-content-digest", "")
        payload = json.load(response)
    return manifest_url, content_type, digest, payload


def normalize_manifest_architecture(platform):
    if not isinstance(platform, dict):
        return None
    if platform.get("os") != "linux":
        return None
    key = (platform.get("architecture"), platform.get("variant"))
    return ARCH_NORMALIZATION.get(key)


def extract_architectures(payload):
    manifests = payload.get("manifests")
    if not isinstance(manifests, list):
        return []
    archs = []
    for manifest in manifests:
        arch = normalize_manifest_architecture(manifest.get("platform"))
        if arch is None or arch in archs:
            continue
        archs.append(arch)
    return archs


def host_support_for_release(release, runtime_preference, host_runner_index):
    support = {}
    platform_os = release["platform_os"].lower()
    platform_version = release["platform_version"]
    for arch in release["arches"]:
        normalized_arch = arch.lower()
        runner = host_runner_index.get((platform_os, platform_version, normalized_arch))
        if runner:
            preference = list(runtime_preference)
        else:
            preference = ["linux_container"]
        support[arch] = {"runner": runner, "runtime_preference": preference}
    return support


def yaml_quote(value):
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def format_yaml(intent, records):
    lines = [
        "source:",
        f"  intent_file: {yaml_quote(str(INTENT_PATH))}",
        f"  host_runner_catalog: {yaml_quote(str(HOST_RUNNER_CATALOG_PATH))}",
        f"  registry_base: {yaml_quote(REGISTRY_BASE)}",
        f"  token_service: {yaml_quote(TOKEN_URL)}",
        "platforms:",
    ]
    for record in records:
        lines.append(f"  - platform_id: {yaml_quote(record['platform_id'])}")
        lines.append(f"    family: {yaml_quote(record['family'])}")
        lines.append(f"    platform_os: {yaml_quote(record['platform_os'])}")
        lines.append(f"    platform_version: {yaml_quote(record['platform_version'])}")
        lines.append(f"    image: {yaml_quote(record['image'])}")
        lines.append(f"    repository: {yaml_quote(record['repository'])}")
        lines.append(f"    repository_url: {yaml_quote(record['repository_url'])}")
        lines.append("    deps:")
        lines.append(f"      family: {yaml_quote(record['deps']['family'])}")
        lines.append(f"      os: {yaml_quote(record['deps']['os'])}")
        lines.append(f"      version: {yaml_quote(record['deps']['version'])}")
        lines.append("    intended_arches:")
        for arch in record["intended_arches"]:
            lines.append(f"      - {yaml_quote(arch)}")
        lines.append("    discovered:")
        lines.append(f"      manifest_url: {yaml_quote(record['manifest_url'])}")
        lines.append(f"      content_type: {yaml_quote(record['content_type'])}")
        lines.append(f"      digest: {yaml_quote(record['digest'])}")
        lines.append("      arches:")
        for arch in record["discovered_arches"]:
            lines.append(f"        - {yaml_quote(arch)}")
        lines.append("    host_support:")
        for arch in record["intended_arches"]:
            support = record["host_support"][arch]
            lines.append(f"      {arch}:")
            if support["runner"] is None:
                lines.append("        runner: null")
            else:
                lines.append(f"        runner: {yaml_quote(support['runner'])}")
            lines.append("        runtime_preference:")
            for runtime in support["runtime_preference"]:
                lines.append(f"          - {yaml_quote(runtime)}")
    return "\n".join(lines) + "\n"


def main():
    intent = load_intent()
    host_runner_index = load_host_runner_index()
    records = []
    for family in intent:
        token = fetch_registry_token(family["repository"])
        for release in family["releases"]:
            manifest_url, content_type, digest, payload = fetch_manifest_index(
                family["repository"], release["tag"], token
            )
            discovered_arches = extract_architectures(payload)
            host_support = host_support_for_release(
                release, family["runtime_preference"], host_runner_index
            )
            image = f"{family['repository']}:{release['tag']}"
            records.append(
                {
                    "family": family["family"],
                    "repository": family["repository"],
                    "repository_url": family["repository_url"],
                    "platform_id": release["platform_id"],
                    "platform_os": release["platform_os"],
                    "platform_version": release["platform_version"],
                    "image": image,
                    "deps": release["deps"],
                    "intended_arches": list(release["arches"]),
                    "manifest_url": manifest_url,
                    "content_type": content_type,
                    "digest": digest,
                    "discovered_arches": discovered_arches,
                    "host_support": host_support,
                }
            )

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(format_yaml(intent, records), encoding="utf-8")


if __name__ == "__main__":
    main()
