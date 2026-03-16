#!/usr/bin/env python3
"""Resolve docker build data from the platform releases inventory."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import yaml

BUILD_TOOLS = ("cmake", "make")
ARCH_TO_DOCKER_PLATFORM = (
    ("amd64", "linux/amd64"),
    ("arm64", "linux/arm64"),
    ("arm32v7", "linux/arm/v7"),
    ("ppc64le", "linux/ppc64le"),
    ("riscv64", "linux/riscv64"),
    ("s390x", "linux/s390x"),
)


def die(message: str) -> None:
    raise SystemExit(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve docker build matrix")
    parser.add_argument(
        "--platform-releases",
        default=".github/data/platform-releases-discovered.yml",
    )
    parser.add_argument(
        "--platform-availability", default=".github/data/platform-availability.yml"
    )
    parser.add_argument("--target", default="all")
    parser.add_argument("--build-tool", default="cmake", choices=("cmake", "make"))
    parser.add_argument(
        "--coverage-policy",
        default="balanced",
        choices=("minimal", "balanced", "broad", "full"),
    )
    parser.add_argument("--github-output", default="")
    parser.add_argument("--compose-output", default="")
    parser.add_argument("--list-targets", action="store_true")
    return parser.parse_args()


def load_yaml(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def render_compose(include: list[dict[str, str]]) -> str:
    lines = ['version: "3.9"', "", "services:"]
    for entry in include:
        lines.extend(
            [
                f"  {entry['name']}:",
                "    build:",
                "      context: ..",
                '      dockerfile: "docker/Dockerfile"',
                "      args:",
                f'        BASE_IMAGE: "{entry["base_image"]}"',
                f'        BUILD_TOOL: "{entry["build_tool"]}"',
                "",
            ]
        )
    return "\n".join(lines).rstrip() + "\n"


def derive_service_name(platform_id: str, build_tool: str) -> str:
    return f"{platform_id}-server-{build_tool}"


def require_mapping(value, context: str) -> dict:
    if not isinstance(value, dict):
        die(f"{context} must be a mapping")
    return value


def require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        die(f"{context} must be a non-empty string")
    return value.strip()


def require_string_list(value, context: str) -> list[str]:
    if not isinstance(value, list) or not value:
        die(f"{context} must be a non-empty list")
    return [require_non_empty_string(item, f"{context}[]") for item in value]


def resolve_supported_docker_platforms(platform_id: str, discovered_arches: list[str]) -> list[str]:
    discovered = {arch.strip().lower() for arch in discovered_arches if arch.strip()}
    platforms = [
        docker_platform
        for arch_name, docker_platform in ARCH_TO_DOCKER_PLATFORM
        if arch_name in discovered
    ]
    if not platforms:
        die(
            f"platform '{platform_id}' has no supported multi-arch docker targets in availability: "
            + ", ".join(sorted(discovered))
        )
    return platforms


def load_docker_platform_availability(
    path: Path,
) -> dict[str, dict[str, str | list[str]]]:
    if not path.exists():
        die(f"Missing platform availability file: {path}")

    data = load_yaml(path)
    platforms = require_mapping(data.get("platforms"), f"{path} platforms")
    availability: dict[str, dict[str, str | list[str]]] = {}
    for platform_id, raw_entry in platforms.items():
        entry = require_mapping(raw_entry, f"{path} platforms.{platform_id}")
        runtime = require_non_empty_string(
            entry.get("runtime"), f"{path} platforms.{platform_id}.runtime"
        ).lower()
        if runtime != "docker":
            continue
        availability[str(platform_id)] = {
            "image": require_non_empty_string(
                entry.get("image"), f"{path} platforms.{platform_id}.image"
            ),
            "digest": require_non_empty_string(
                entry.get("digest"), f"{path} platforms.{platform_id}.digest"
            ),
            "discovered_arches": require_string_list(
                entry.get("discovered_arches"),
                f"{path} platforms.{platform_id}.discovered_arches",
            ),
        }
    if not availability:
        die(f"{path} has no runtime=docker platform availability entries")
    return availability


def load_docker_build_platforms(
    platform_releases_path: Path,
    platform_availability_path: Path,
) -> dict[str, dict[str, str]]:
    if not platform_releases_path.exists():
        die(f"Missing platform releases file: {platform_releases_path}")

    platform_availability = load_docker_platform_availability(platform_availability_path)

    data = load_yaml(platform_releases_path)
    platforms = data.get("platforms", {})
    if not isinstance(platforms, dict) or not platforms:
        die(f"{platform_releases_path} has no platforms mapping")

    docker_platforms: dict[str, dict[str, str]] = {}
    for platform_id, raw_entry in platforms.items():
        if not isinstance(raw_entry, dict):
            continue
        runtime = str(raw_entry.get("runtime") or "").strip().lower()
        if runtime != "docker":
            continue
        image = str(raw_entry.get("image") or "").strip()
        if not image:
            die(f"platform '{platform_id}' is runtime=docker but has no image")

        availability_entry = platform_availability.get(str(platform_id))
        if availability_entry is None:
            die(
                f"platform '{platform_id}' has no platform availability entry"
            )
        available_image = str(availability_entry["image"])
        if available_image != image:
            die(
                f"platform '{platform_id}' image mismatch between platform releases "
                f"('{image}') and availability ('{available_image}')"
            )
        discovered_arches = require_string_list(
            availability_entry["discovered_arches"],
            f"{platform_availability_path} platforms.{platform_id}.discovered_arches",
        )
        digest = str(availability_entry["digest"])
        supported_platforms = resolve_supported_docker_platforms(platform_id, discovered_arches)

        platform_os = str(raw_entry.get("platform_os") or "").strip()
        platform_version = str(raw_entry.get("platform_version") or "").strip()
        docker_platforms[str(platform_id)] = {
            "base_image": f"{image}@{digest}",
            "platforms": ",".join(supported_platforms),
            "platform_os": platform_os,
            "platform_version": platform_version,
        }

    if not docker_platforms:
        die(
                f"{platform_releases_path} has no runtime=docker platforms"
        )
    return docker_platforms


def is_micro_version(platform_id: str, all_platform_ids: set[str]) -> bool:
    """True if a parent platform ID exists after stripping the _N patch segment.

    e.g. debian-11_1-slim -> debian-11-slim (exists) -> micro
         alpine-3_19      -> alpine-3        (missing) -> not micro
    """
    parent = re.sub(r"_\d+(-|$)", r"\1", platform_id)
    return parent != platform_id and parent in all_platform_ids


def is_rolling_version(platform_version: str) -> bool:
    """True if the version string is a non-numeric rolling tag (edge, latest, base)."""
    return not re.match(r"^\d", platform_version)


def _version_key(version: str) -> tuple:
    numbers = tuple(int(p) for p in re.findall(r"\d+", version))
    return (1 if numbers else 0, numbers, version)


def latest_stable_per_family(docker_platforms: dict[str, dict[str, str]]) -> set[str]:
    """Return the platform_id with the highest stable version per OS family."""
    all_ids = set(docker_platforms)
    by_family: dict[str, list] = {}
    for platform_id, info in docker_platforms.items():
        if is_micro_version(platform_id, all_ids):
            continue
        if is_rolling_version(info["platform_version"]):
            continue
        family = info["platform_os"]
        by_family.setdefault(family, []).append(
            (_version_key(info["platform_version"]), platform_id)
        )
    return {max(entries)[1] for entries in by_family.values() if entries}


def apply_coverage_policy(
    docker_platforms: dict[str, dict[str, str]],
    coverage_policy: str,
) -> dict[str, dict[str, str]]:
    """Apply coverage_policy — mirrors the Pipeline lane coverage_policy semantics.

    Version scope (which platform versions are included):
      minimal / balanced : primary versions only — no micro-versions
      broad              : all stable versions including micro-versions
      full               : everything including rolling tags (alpine-edge, archlinux-latest)

    Architecture scope (which Docker --platform string each entry gets):
      minimal  : linux/amd64 only for all platforms
      balanced : full multi-arch for the latest stable version per OS family,
                 linux/amd64 only for all others
      broad    : full multi-arch for all included platforms
      full     : full multi-arch for all included platforms
    """
    all_ids = set(docker_platforms)
    latest = latest_stable_per_family(docker_platforms) if coverage_policy == "balanced" else set()

    result: dict[str, dict[str, str]] = {}
    for platform_id, info in docker_platforms.items():
        micro = is_micro_version(platform_id, all_ids)
        rolling = is_rolling_version(info["platform_version"])

        # Version scope filter
        if coverage_policy in ("minimal", "balanced") and micro:
            continue
        if coverage_policy == "broad" and rolling:
            continue

        # Architecture scope
        if coverage_policy == "minimal":
            effective_platforms = "linux/amd64"
        elif coverage_policy == "balanced":
            effective_platforms = (
                info["platforms"] if platform_id in latest else "linux/amd64"
            )
        else:
            effective_platforms = info["platforms"]

        result[platform_id] = {**info, "platforms": effective_platforms}
    return result


def main() -> None:
    args = parse_args()
    github_output = str(args.github_output or "").strip()
    compose_output = str(args.compose_output or "").strip()
    if not github_output and not compose_output and not args.list_targets:
        die("One of --github-output / GITHUB_OUTPUT, --compose-output, or --list-targets must be provided")
    platform_releases_path = Path(args.platform_releases)
    platform_availability_path = Path(args.platform_availability)
    dockerfile = Path("docker") / "Dockerfile"
    if not dockerfile.exists():
        die(f"Missing shared Dockerfile: {dockerfile}")

    docker_platforms = load_docker_build_platforms(
        platform_releases_path, platform_availability_path
    )
    docker_platforms = apply_coverage_policy(docker_platforms, args.coverage_policy)

    target_raw = str(args.target).strip().lower()
    build_tool_filter = str(args.build_tool).strip().lower()

    os_families = {info["platform_os"] for info in docker_platforms.values() if info["platform_os"]}
    target_is_family = target_raw in os_families
    selected_names: set[str] = set()
    if target_raw != "all" and not target_is_family:
        selected_names = {name.strip() for name in target_raw.split(",") if name.strip()}
        if not selected_names:
            die("Resolved empty --target selection")

    active_build_tools = (build_tool_filter,)

    known_names: set[str] = set()
    include: list[dict[str, str]] = []
    for platform_id, platform_info in docker_platforms.items():
        if target_is_family and platform_info["platform_os"] != target_raw:
            continue
        base_image = platform_info["base_image"]
        target_platforms = platform_info["platforms"]
        for build_tool in active_build_tools:
            name = derive_service_name(platform_id, build_tool)
            known_names.add(name)
            if selected_names and name not in selected_names:
                continue

            entry = {
                "name": name,
                "base_image": base_image,
                "build_tool": build_tool,
                "platforms": target_platforms,
            }
            include.append(entry)

    if selected_names:
        missing = sorted(selected_names - known_names)
        if missing:
            die("Unknown docker target(s): " + ", ".join(missing))

    matrix = {"include": include}
    if github_output:
        with Path(github_output).open("a", encoding="utf-8") as fh:
            fh.write("matrix<<EOF\n")
            fh.write(json.dumps(matrix))
            fh.write("\nEOF\n")
            fh.write(f"matrix_count={len(include)}\n")
    if compose_output:
        compose_path = Path(compose_output)
        compose_path.parent.mkdir(parents=True, exist_ok=True)
        compose_path.write_text(render_compose(include), encoding="utf-8")
    if args.list_targets:
        if include:
            print("\n".join(entry["name"] for entry in include))


if __name__ == "__main__":
    main()
