"""Platform catalog helpers for dependency checks."""

from __future__ import annotations

from typing import Tuple


def load_platform_catalog(path, load_yaml, require) -> dict[str, dict]:
    if not path.exists():
        return {}

    data = load_yaml(path)
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        return {}

    normalized = {}
    for platform_id, raw_entry in platforms.items():
        require(
            isinstance(platform_id, str) and platform_id.strip(),
            f"{path} platform id must be a non-empty string",
        )
        require(
            isinstance(raw_entry, dict),
            f"{path} platforms.{platform_id} must be a mapping",
        )
        normalized[platform_id] = raw_entry
    return normalized


def load_platform_deps_bindings(platform_catalog: dict[str, dict]) -> dict[str, dict]:
    bindings: dict[str, dict] = {}
    for platform_id, entry in platform_catalog.items():
        deps = entry.get("deps")
        if deps is None:
            continue
        if not isinstance(deps, dict):
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' deps must be a mapping"
            )
        family = str(deps.get("family", "")).strip()
        os_name = str(deps.get("os", "")).strip()
        version_raw = deps.get("version")
        if not family or not os_name:
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' deps must include family and os"
            )
        if version_raw is None:
            os_key = os_name
        else:
            version = str(version_raw).strip()
            os_key = os_name if not version else f"{os_name}_{version}"
        bindings[platform_id] = {
            "family": family,
            "os": os_name,
            "version": None if version_raw is None else str(version_raw).strip(),
            "os_key": os_key,
        }
    return bindings


def build_docker_image_index(
    platform_catalog: dict[str, dict],
) -> Tuple[dict[str, str], dict[str, set[str]]]:
    image_to_platform: dict[str, str] = {}
    duplicate_images: dict[str, set[str]] = {}
    for platform_id, entry in platform_catalog.items():
        runtime = str(entry.get("runtime", "")).strip().lower()
        if runtime != "docker":
            continue
        image_ref = str(entry.get("image", "")).strip().lower().split("@", 1)[0]
        if not image_ref:
            continue
        previous = image_to_platform.get(image_ref)
        if previous and previous != platform_id:
            duplicate_images.setdefault(image_ref, {previous}).add(platform_id)
        else:
            image_to_platform[image_ref] = platform_id
    return image_to_platform, duplicate_images
