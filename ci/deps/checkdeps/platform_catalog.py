"""Platform catalog and platform release helpers for dependency checks."""

from __future__ import annotations

from typing import Tuple

from platform_normalization import (  # type: ignore
    compose_os_key,
    find_matching_rule,
    normalize_rule_version,
)


def infer_platform_os(platform_id: str) -> str:
    platform_id = platform_id.strip()
    if platform_id.startswith("opensuse-tumbleweed"):
        return "opensuse_tumbleweed"
    if platform_id.startswith("opensuse-leap-"):
        return "opensuse_leap"
    return platform_id.split("-", 1)[0]


def infer_release_version(platform_id: str, entry: dict) -> str | None:
    platform_version = str(entry.get("platform_version", "")).strip()
    if platform_version:
        return platform_version
    image = str(entry.get("image", "")).strip()
    if ":" in image:
        return image.rsplit(":", 1)[1].strip() or None
    if "-" in platform_id:
        return platform_id.split("-", 1)[1].replace("_", ".")
    return None


def validate_platform_catalog_fields(platform_os: str, entry: dict) -> None:
    runtime = str(entry.get("runtime", "")).strip().lower()
    if runtime not in {"docker", "vm", "host"}:
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_os}' has unsupported runtime '{runtime}'"
        )

    image = str(entry.get("image", "")).strip()
    runner = str(entry.get("runner", "")).strip()

    if runtime == "docker" and (image or runner):
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_os}' (runtime=docker) must not include image/runner"
        )
        return

    if runtime == "vm" and (image or runner):
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_os}' (runtime=vm) must not include image/runner"
        )
        return

    if image or runner:
        raise SystemExit(
            f"ERROR: platform catalog entry '{platform_os}' (runtime=host) must not include image/runner"
        )


def load_platform_catalog(path, load_yaml, require) -> dict[str, dict]:
    if not path.exists():
        return {}

    data = load_yaml(path)
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        return {}

    normalized = {}
    for platform_os, raw_entry in platforms.items():
        require(
            isinstance(platform_os, str) and platform_os.strip(),
            f"{path} platform os must be a non-empty string",
        )
        require(
            isinstance(raw_entry, dict),
            f"{path} platforms.{platform_os} must be a mapping",
        )
        validate_platform_catalog_fields(platform_os, raw_entry)
        normalized[platform_os] = raw_entry
    return normalized


def validate_platform_release_fields(platform_id: str, entry: dict) -> None:
    runtime_raw = entry.get("runtime")
    if runtime_raw is not None:
        runtime = str(runtime_raw).strip().lower()
        if runtime not in {"docker", "vm", "host"}:
            raise SystemExit(
                f"ERROR: platform release entry '{platform_id}' has unsupported runtime '{runtime}'"
            )

    platform_os_raw = entry.get("platform_os")
    if platform_os_raw is not None and not str(platform_os_raw).strip():
        raise SystemExit(
            f"ERROR: platform release entry '{platform_id}' has an empty platform_os"
        )

    image = str(entry.get("image", "")).strip()
    runner = str(entry.get("runner", "")).strip()
    if image and runner:
        raise SystemExit(
            f"ERROR: platform release entry '{platform_id}' must not define both image and runner"
        )


def load_platform_releases(path, load_yaml, require) -> dict[str, dict]:
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
        validate_platform_release_fields(platform_id, raw_entry)
        normalized[platform_id] = raw_entry
    return normalized


def load_platform_deps_bindings(
    platform_catalog: dict[str, dict],
    platform_releases: dict[str, dict],
    normalization_rules: dict[str, dict] | None = None,
) -> dict[str, dict]:
    bindings: dict[str, dict] = {}
    for platform_id, entry in platform_releases.items():
        platform_os = str(entry.get("platform_os", "")).strip() or infer_platform_os(platform_id)
        catalog_entry = platform_catalog.get(platform_os)
        if not isinstance(catalog_entry, dict):
            raise SystemExit(
                f"ERROR: platform release entry '{platform_id}' references unknown platform_os '{platform_os}'"
            )
        deps = catalog_entry.get("deps")
        release_deps = entry.get("deps")
        if release_deps is None:
            release_deps = {}
        if deps is None:
            continue
        if not isinstance(deps, dict):
            raise SystemExit(
                f"ERROR: platform catalog entry '{platform_os}' deps must be a mapping"
            )
        if not isinstance(release_deps, dict):
            raise SystemExit(
                f"ERROR: platform release entry '{platform_id}' deps must be a mapping"
            )
        package_family = str(deps.get("package_family", "")).strip()
        key_raw = release_deps.get("key")
        image = str(entry.get("image", "")).strip()
        runner = str(entry.get("runner", "")).strip()
        runtime = str(entry.get("runtime", "")).strip().lower()
        if not package_family or not platform_os:
            raise SystemExit(
                f"ERROR: platform release entry '{platform_id}' must resolve package_family and platform_os"
            )
        if key_raw is None:
            if not image and runtime != "docker":
                normalized_key = None
                os_key = platform_os
            else:
                matching_rule = find_matching_rule(normalization_rules, package_family, platform_os)
                if matching_rule is None:
                    normalized_key = None
                    os_key = platform_os
                else:
                    inferred_version = infer_release_version(platform_id, entry)
                    normalized_key = normalize_rule_version(matching_rule, inferred_version)
                    os_key = compose_os_key(platform_os, normalized_key)
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
    platform_releases: dict[str, dict],
) -> Tuple[dict[str, str], dict[str, set[str]]]:
    image_to_platform: dict[str, str] = {}
    duplicate_images: dict[str, set[str]] = {}
    for platform_id, entry in platform_releases.items():
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
