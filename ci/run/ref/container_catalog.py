#!/usr/bin/env python3

from __future__ import annotations
from typing import Any

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
    normalized: list[str] = []
    for index, raw in enumerate(value):
        normalized.append(_require_non_empty_string(raw, f"{context}[{index}]"))
    return normalized


def load_container_catalog(path: Path) -> dict[str, dict]:
    if not path.exists():
        raise ValueError(f"Missing container catalog: {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    data = _require_mapping(data, f"container catalog root in {path}")
    raw_platforms = data.get("platforms")
    entries: list[Any] = []
    if isinstance(raw_platforms, list):
        entries = raw_platforms
    elif isinstance(raw_platforms, dict):
        containers = raw_platforms.get("containers")
        if isinstance(containers, list):
            entries = containers
    if not entries:
        raise ValueError(f"Container catalog has no entries at {path}")

    catalog: dict[str, dict] = {}
    for index, raw_entry in enumerate(entries):
        entry = _require_mapping(
            raw_entry, f"container catalog entry #{index} in {path}"
        )
        platform_id = _require_non_empty_string(
            entry.get("platform_id"),
            f"container catalog entry #{index}.platform_id",
        )
        platform_os = _require_non_empty_string(
            entry.get("platform_os"),
            f"container catalog entry {platform_id}.platform_os",
        ).lower()
        discovered = entry.get("discovered")
        discovered_arches_raw = entry.get("discovered_arches")
        if discovered_arches_raw is None:
            discovered = _require_mapping(
                discovered,
                f"container catalog entry {platform_id}.discovered",
            )
            discovered_arches_raw = discovered.get("arches")
        host_support_raw = _require_mapping(
            entry.get("host_support"),
            f"container catalog entry {platform_id}.host_support",
        )
        host_support: dict[str, dict] = {}
        for arch, raw_support in host_support_raw.items():
            arch_key = _require_non_empty_string(
                arch, f"container catalog entry {platform_id}.host_support key"
            )
            support = _require_mapping(
                raw_support,
                f"container catalog entry {platform_id}.host_support.{arch_key}",
            )
            runner = support.get("runner")
            direct_runner_labels: list[str] = []
            container_runner_labels: list[str] = []
            if runner is not None:
                runner = _require_non_empty_string(
                    runner,
                    f"container catalog entry {platform_id}.host_support.{arch_key}.runner",
                )
            else:
                direct_runner_labels = support.get("direct_runner_labels")
                if direct_runner_labels is not None:
                    direct_runner_labels = _require_string_list(
                        direct_runner_labels,
                        f"container catalog entry {platform_id}.host_support.{arch_key}.direct_runner_labels",
                    )
                else:
                    direct_runner_labels = []
                container_runner_labels = support.get("container_runner_labels")
                if container_runner_labels is not None:
                    container_runner_labels = _require_string_list(
                        container_runner_labels,
                        f"container catalog entry {platform_id}.host_support.{arch_key}.container_runner_labels",
                    )
                else:
                    container_runner_labels = list(direct_runner_labels)
            host_support[arch_key] = {
                "runner": runner,
                "direct_runner_labels": direct_runner_labels,
                "container_runner_labels": container_runner_labels,
                "runtime_preference": _require_string_list(
                    support.get("runtime_preference"),
                    f"container catalog entry {platform_id}.host_support.{arch_key}.runtime_preference",
                ),
            }

        if platform_id in catalog:
            raise ValueError(f"Duplicate container catalog platform: {platform_id}")

        catalog[platform_id] = {
            "platform_id": platform_id,
            "image": _require_non_empty_string(
                entry.get("image"),
                f"container catalog entry {platform_id}.image",
            ),
            "platform_os": platform_os,
            "platform_version": _require_non_empty_string(
                entry.get("platform_version"),
                f"container catalog entry {platform_id}.platform_version",
            ),
            "deps": _require_mapping(
                entry.get("deps"),
                f"container catalog entry {platform_id}.deps",
            ),
            "intended_arches": _require_string_list(
                entry.get("intended_arches"),
                f"container catalog entry {platform_id}.intended_arches",
            ),
            "discovered_arches": _require_string_list(
                discovered_arches_raw,
                f"container catalog entry {platform_id}.discovered_arches",
            ),
            "host_support": host_support,
        }

    return catalog


def resolve_container_runtime(
    *, platform_id: str, platform_os: str, artifact_arch: str, container_catalog: dict[str, dict]
) -> dict | None:
    entry = container_catalog.get(platform_id)
    if entry is None:
        return None

    normalized_os = platform_os.lower()
    if entry["platform_os"] != normalized_os:
        return None

    if artifact_arch not in entry["intended_arches"]:
        return None
    if artifact_arch not in entry["discovered_arches"]:
        raise ValueError(
            f"Container catalog entry '{platform_id}' is missing discovered arch '{artifact_arch}'"
        )

    host_support = entry["host_support"].get(artifact_arch)
    if host_support is None:
        return None

    return {
        "image": entry["image"],
        "runtime_preference": list(host_support["runtime_preference"]),
        "host_runner": host_support["runner"]
        or (host_support["direct_runner_labels"][0] if host_support["direct_runner_labels"] else None),
    }
