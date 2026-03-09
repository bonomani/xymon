#!/usr/bin/env python3

from __future__ import annotations

import re
from pathlib import Path

import yaml

from lane_utils import VARIANT_NAME_SUFFIX

ARCH_TO_ARTIFACT = {
    "x64": "amd64",
    "arm64": "arm64",
}

PLATFORM_DISPLAY_NAMES = {
    "ubuntu": "Ubuntu",
    "macos": "macOS",
    "windows": "Windows",
}


def _require_mapping(value, context: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be a mapping")
    return value


def _require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context} must be a non-empty string")
    return value.strip()


def load_github_host_runners(path: Path) -> list[dict]:
    if not path.exists():
        raise ValueError(f"Missing GitHub host runner catalog: {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    data = _require_mapping(data, f"GitHub host runner catalog root in {path}")
    runners = data.get("runners")
    if not isinstance(runners, list) or not runners:
        raise ValueError(f"GitHub host runner catalog has no runners list: {path}")

    normalized = []
    for index, raw_entry in enumerate(runners):
        entry = _require_mapping(
            raw_entry, f"GitHub host runner catalog entry #{index} in {path}"
        )
        normalized.append(
            {
                "label": _require_non_empty_string(
                    entry.get("label"),
                    f"GitHub host runner catalog entry #{index}.label",
                ),
                "machine_family": _require_non_empty_string(
                    entry.get("machine_family"),
                    f"GitHub host runner catalog entry #{index}.machine_family",
                ).lower(),
                "platform_os": _require_non_empty_string(
                    entry.get("platform_os"),
                    f"GitHub host runner catalog entry #{index}.platform_os",
                ).lower(),
                "platform_version": _require_non_empty_string(
                    entry.get("platform_version"),
                    f"GitHub host runner catalog entry #{index}.platform_version",
                ),
                "arch": _require_non_empty_string(
                    entry.get("arch"),
                    f"GitHub host runner catalog entry #{index}.arch",
                ).lower(),
            }
        )

    return normalized


def build_host_runner_index(host_runners: list[dict]) -> dict[tuple[str, str, str, str], dict]:
    index = {}
    for entry in host_runners:
        key = (
            entry["machine_family"],
            entry["platform_os"],
            entry["platform_version"],
            entry["arch"],
        )
        if key in index:
            # Preview labels can share the same logical OS/version/arch tuple.
            # Keep the first canonical entry as the preferred selector.
            continue
        index[key] = entry
    return index


def artifact_arch_for_host_runner(entry: dict) -> str:
    arch = entry["arch"]
    if arch not in ARCH_TO_ARTIFACT:
        raise ValueError(f"Unsupported host runner architecture: {arch}")
    return ARCH_TO_ARTIFACT[arch]


def host_runner_display_name(entry: dict) -> str:
    platform_os = entry["platform_os"]
    version = entry["platform_version"]
    arch = artifact_arch_for_host_runner(entry)
    os_label = PLATFORM_DISPLAY_NAMES.get(platform_os, platform_os.title())
    return f"{os_label} {version} {arch}"


def host_runner_platform_id(entry: dict) -> str:
    version = entry["platform_version"].replace(".", "_")
    arch = artifact_arch_for_host_runner(entry)
    return f"gha-{entry['platform_os']}-{version}-{arch}"


def build_generated_host_lanes(
    host_runners: list[dict],
    *,
    machine_family: str,
) -> list[dict]:
    lanes = []
    for entry in sorted(
        host_runners,
        key=lambda item: (
            item["platform_os"],
            item["platform_version"],
            item["arch"],
            item["label"],
        ),
    ):
        if entry["machine_family"] != machine_family:
            continue
        machine_label = PLATFORM_DISPLAY_NAMES.get(
            entry["machine_family"], entry["machine_family"].title()
        )
        name_prefix = f"{machine_label} host ({host_runner_display_name(entry)})"
        platform_id = host_runner_platform_id(entry)
        architecture = artifact_arch_for_host_runner(entry)
        for variant, suffix in VARIANT_NAME_SUFFIX.items():
            lanes.append(
                {
                    "name": f"{name_prefix} - {suffix}",
                    "variant": variant,
                    "platform_id": platform_id,
                    "platform_os": entry["platform_os"],
                    "runs_on": entry["label"],
                    "architecture": architecture,
                    # Synthetic host lanes do not bind through the platform catalog.
                    "platform_catalog_optional": True,
                }
            )
    return lanes


def infer_host_lookup_version(platform_id: str, platform_entry: dict) -> str:
    display_name = str(platform_entry.get("display_name") or "").strip()
    if display_name:
        match = re.search(r"(\d+(?:\.\d+)+)", display_name)
        if match:
            return match.group(1)

    suffix = platform_id.split("-", 1)[1] if "-" in platform_id else platform_id
    if re.fullmatch(r"\d+", suffix):
        return f"{suffix}.04"
    if re.fullmatch(r"\d+(?:_\d+)+", suffix):
        return suffix.replace("_", ".")
    if re.fullmatch(r"\d+(?:\.\d+)+", suffix):
        return suffix
    return ""


def resolve_linux_host_runner(
    *,
    platform_id: str,
    platform_entry: dict,
    artifact_arch: str,
    host_runner_index: dict[tuple[str, str, str, str], dict],
) -> dict | None:
    if artifact_arch not in {"amd64", "arm64"}:
        return None

    deps = platform_entry.get("deps")
    if not isinstance(deps, dict):
        return None
    platform_os = str(deps.get("os") or "").strip().lower()
    if not platform_os:
        return None

    platform_version = infer_host_lookup_version(platform_id, platform_entry)
    if not platform_version:
        return None

    host_arch = "x64" if artifact_arch == "amd64" else "arm64"
    return host_runner_index.get(("linux", platform_os, platform_version, host_arch))
