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
    if not isinstance(value, list):
        raise ValueError(f"{context} must be a list")
    normalized: list[str] = []
    for index, raw in enumerate(value):
        normalized.append(_require_non_empty_string(raw, f"{context}[{index}]"))
    return normalized


def load_platform_availability(path: Path) -> dict[str, dict]:
    if not path.exists():
        raise ValueError(f"Missing platform availability file: {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    data = _require_mapping(data, f"platform availability root in {path}")
    raw_platforms = _require_mapping(
        data.get("platforms"), f"platform availability platforms in {path}"
    )

    catalog: dict[str, dict] = {}
    for raw_platform_id, raw_entry in raw_platforms.items():
        platform_id = _require_non_empty_string(
            raw_platform_id, f"platform availability key in {path}"
        )
        entry = _require_mapping(
            raw_entry, f"platform availability entry '{platform_id}' in {path}"
        )
        runtime = _require_non_empty_string(
            entry.get("runtime"),
            f"platform availability entry '{platform_id}'.runtime",
        ).lower()

        normalized = dict(entry)
        normalized["runtime"] = runtime

        if runtime == "docker":
            normalized["image"] = _require_non_empty_string(
                entry.get("image"),
                f"platform availability entry '{platform_id}'.image",
            )
            normalized["platform_os"] = _require_non_empty_string(
                entry.get("platform_os"),
                f"platform availability entry '{platform_id}'.platform_os",
            ).lower()
            normalized["platform_version"] = _require_non_empty_string(
                entry.get("platform_version"),
                f"platform availability entry '{platform_id}'.platform_version",
            )
            normalized["digest"] = _require_non_empty_string(
                entry.get("digest"),
                f"platform availability entry '{platform_id}'.digest",
            )
            normalized["discovered_arches"] = _require_string_list(
                entry.get("discovered_arches"),
                f"platform availability entry '{platform_id}'.discovered_arches",
            )
            host_support_raw = _require_mapping(
                entry.get("host_support"),
                f"platform availability entry '{platform_id}'.host_support",
            )
            host_support: dict[str, dict] = {}
            for arch, raw_support in host_support_raw.items():
                arch_key = _require_non_empty_string(
                    arch,
                    f"platform availability entry '{platform_id}'.host_support key",
                )
                support = _require_mapping(
                    raw_support,
                    f"platform availability entry '{platform_id}'.host_support.{arch_key}",
                )
                direct_runner_labels = support.get("direct_runner_labels", [])
                container_runner_labels = support.get("container_runner_labels")
                direct_runner_labels = _require_string_list(
                    direct_runner_labels,
                    (
                        "platform availability entry "
                        f"'{platform_id}'.host_support.{arch_key}.direct_runner_labels"
                    ),
                )
                if container_runner_labels is None:
                    container_runner_labels = list(direct_runner_labels)
                else:
                    container_runner_labels = _require_string_list(
                        container_runner_labels,
                        (
                            "platform availability entry "
                            f"'{platform_id}'.host_support.{arch_key}.container_runner_labels"
                        ),
                    )
                host_support[arch_key] = {
                    "direct_runner_labels": direct_runner_labels,
                    "container_runner_labels": container_runner_labels,
                }
            normalized["host_support"] = host_support

        catalog[platform_id] = normalized

    return catalog


def resolve_container_runtime(
    *,
    platform_id: str,
    platform_os: str,
    artifact_arch: str,
    platform_availability: dict[str, dict],
) -> dict | None:
    entry = platform_availability.get(platform_id)
    if entry is None or entry.get("runtime") != "docker":
        return None

    normalized_os = platform_os.lower()
    if entry["platform_os"] != normalized_os:
        return None

    if artifact_arch not in entry["discovered_arches"]:
        return {
            "supported": False,
            "reason": (
                f"Platform availability entry '{platform_id}' does not discover arch "
                f"'{artifact_arch}'"
            ),
        }

    host_support = entry["host_support"].get(artifact_arch)
    if host_support is None:
        return {
            "supported": False,
            "reason": (
                f"Platform availability entry '{platform_id}' has no host/container support "
                f"for arch '{artifact_arch}'"
            ),
        }

    return {
        "supported": True,
        "image": entry["image"],
        "digest": entry["digest"],
        "platform_os": entry["platform_os"],
        "platform_version": entry["platform_version"],
        "direct_host_runners": list(host_support["direct_runner_labels"]),
        "container_runners": list(
            host_support["container_runner_labels"]
            if host_support["container_runner_labels"]
            else host_support["direct_runner_labels"]
        ),
        "supports_host": bool(host_support["direct_runner_labels"]),
        "supports_container": bool(
            host_support["container_runner_labels"]
            or host_support["direct_runner_labels"]
        ),
    }
