"""Platform catalog helpers for dependency checks."""

from __future__ import annotations

from typing import Tuple

from platform_normalization import (  # type: ignore
    compose_os_key,
    find_matching_rule,
    normalize_rule_version,
)


def validate_platform_runtime_fields(platform_id: str, entry: dict) -> None:
    runtime = str(entry.get("runtime", "")).strip().lower()
    if runtime not in {"docker", "vm", "host"}:
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_id}' has unsupported runtime '{runtime}'"
        )

    image = str(entry.get("image", "")).strip()
    runner = str(entry.get("runner", "")).strip()
    provider = str(entry.get("provider", "")).strip()

    if runtime == "docker":
        if not image:
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' (runtime=docker) must include image"
            )
        if runner:
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' (runtime=docker) must not include runner"
            )
        return

    if runtime == "vm":
        if image or runner:
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' (runtime=vm) must not include image/runner"
            )
        return

    if not runner:
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_id}' (runtime=host) must include runner"
        )
    if image:
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_id}' (runtime=host) must not include image"
        )


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
        validate_platform_runtime_fields(platform_id, raw_entry)
        normalized[platform_id] = raw_entry
    return normalized


def load_platform_deps_bindings(
    platform_catalog: dict[str, dict],
    normalization_rules: dict[str, dict] | None = None,
) -> dict[str, dict]:
    bindings: dict[str, dict] = {}
    for platform_id, entry in platform_catalog.items():
        deps = entry.get("deps")
        if deps is None:
            continue
        if not isinstance(deps, dict):
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' deps must be a mapping"
            )
        package_family = str(deps.get("package_family", "")).strip()
        platform_os = str(entry.get("platform_os", "")).strip()
        key_raw = deps.get("key")
        if not package_family or not platform_os:
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_id}' must include platform_os and deps.package_family"
            )
        if key_raw is None:
            normalized_key = None
            os_key = platform_os
        else:
            key = str(key_raw).strip()
            matching_rule = find_matching_rule(normalization_rules, package_family, platform_os)
            normalized_key = normalize_rule_version(matching_rule, key)
            os_key = compose_os_key(platform_os, normalized_key)
        bindings[platform_id] = {
            "package_family": package_family,
            "platform_os": platform_os,
            "deps_key": normalized_key,
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
