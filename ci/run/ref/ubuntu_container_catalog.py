#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path

import yaml


def _require_mapping(value, context: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be a mapping")
    return value


def _require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context} must be a non-empty string")
    return value.strip()


def _require_string_list(value, context: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{context} must be a non-empty list")
    normalized = []
    for index, raw in enumerate(value):
        normalized.append(_require_non_empty_string(raw, f"{context}[{index}]"))
    return normalized


def load_ubuntu_container_catalog(path: Path) -> dict[str, dict]:
    if not path.exists():
        raise ValueError(f"Missing Ubuntu container catalog: {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    data = _require_mapping(data, f"Ubuntu container catalog root in {path}")
    platforms = data.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        raise ValueError(f"Ubuntu container catalog has no platforms list: {path}")

    catalog: dict[str, dict] = {}
    for index, raw_entry in enumerate(platforms):
        entry = _require_mapping(
            raw_entry, f"Ubuntu container catalog entry #{index} in {path}"
        )
        platform_id = _require_non_empty_string(
            entry.get("platform_id"),
            f"Ubuntu container catalog entry #{index}.platform_id",
        )
        discovered = _require_mapping(
            entry.get("discovered"),
            f"Ubuntu container catalog entry {platform_id}.discovered",
        )
        host_support_raw = _require_mapping(
            entry.get("host_support"),
            f"Ubuntu container catalog entry {platform_id}.host_support",
        )
        host_support: dict[str, dict] = {}
        for arch, raw_support in host_support_raw.items():
            arch_key = _require_non_empty_string(
                arch,
                f"Ubuntu container catalog entry {platform_id}.host_support key",
            )
            support = _require_mapping(
                raw_support,
                f"Ubuntu container catalog entry {platform_id}.host_support.{arch_key}",
            )
            runner = support.get("runner")
            if runner is not None:
                runner = _require_non_empty_string(
                    runner,
                    f"Ubuntu container catalog entry {platform_id}.host_support.{arch_key}.runner",
                )
            host_support[arch_key] = {
                "runner": runner,
                "runtime_preference": _require_string_list(
                    support.get("runtime_preference"),
                    f"Ubuntu container catalog entry {platform_id}.host_support.{arch_key}.runtime_preference",
                ),
            }

        if platform_id in catalog:
            raise ValueError(f"Duplicate Ubuntu container catalog platform: {platform_id}")

        catalog[platform_id] = {
            "platform_id": platform_id,
            "image": _require_non_empty_string(
                entry.get("image"),
                f"Ubuntu container catalog entry {platform_id}.image",
            ),
            "platform_os": _require_non_empty_string(
                entry.get("platform_os"),
                f"Ubuntu container catalog entry {platform_id}.platform_os",
            ).lower(),
            "platform_version": _require_non_empty_string(
                entry.get("platform_version"),
                f"Ubuntu container catalog entry {platform_id}.platform_version",
            ),
            "deps": _require_mapping(
                entry.get("deps"),
                f"Ubuntu container catalog entry {platform_id}.deps",
            ),
            "intended_arches": _require_string_list(
                entry.get("intended_arches"),
                f"Ubuntu container catalog entry {platform_id}.intended_arches",
            ),
            "discovered_arches": _require_string_list(
                discovered.get("arches"),
                f"Ubuntu container catalog entry {platform_id}.discovered.arches",
            ),
            "host_support": host_support,
        }

    return catalog


def resolve_ubuntu_container_runtime(
    *,
    platform_id: str,
    artifact_arch: str,
    ubuntu_catalog: dict[str, dict],
) -> dict | None:
    entry = ubuntu_catalog.get(platform_id)
    if entry is None:
        return None

    if artifact_arch not in entry["intended_arches"]:
        raise ValueError(
            f"Ubuntu container catalog entry '{platform_id}' does not intend arch '{artifact_arch}'"
        )
    if artifact_arch not in entry["discovered_arches"]:
        raise ValueError(
            f"Ubuntu container catalog entry '{platform_id}' is missing discovered arch '{artifact_arch}'"
        )

    host_support = entry["host_support"].get(artifact_arch)
    if host_support is None:
        raise ValueError(
            f"Ubuntu container catalog entry '{platform_id}' has no host support record for arch '{artifact_arch}'"
        )

    return {
        "image": entry["image"],
        "runtime_preference": list(host_support["runtime_preference"]),
        "host_runner": host_support["runner"],
    }
