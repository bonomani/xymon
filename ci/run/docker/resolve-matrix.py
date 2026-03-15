#!/usr/bin/env python3
"""Resolve docker build data from the platform catalog."""

from __future__ import annotations

import argparse
import json
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
    parser.add_argument("--platform-catalog", default="ci/deps/platform-catalog.yaml")
    parser.add_argument(
        "--platform-availability", default=".github/data/platform-availability.yml"
    )
    parser.add_argument("--target", default="all")
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
    platform_catalog_path: Path,
    platform_availability_path: Path,
) -> dict[str, dict[str, str]]:
    if not platform_catalog_path.exists():
        die(f"Missing platform catalog file: {platform_catalog_path}")

    platform_availability = load_docker_platform_availability(platform_availability_path)

    data = load_yaml(platform_catalog_path)
    platforms = data.get("platforms", {})
    if not isinstance(platforms, dict) or not platforms:
        die(f"{platform_catalog_path} has no platforms mapping")

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
                f"platform '{platform_id}' is docker_build=true but has no platform availability entry"
            )
        available_image = str(availability_entry["image"])
        if available_image != image:
            die(
                f"platform '{platform_id}' image mismatch between static catalog "
                f"('{image}') and availability ('{available_image}')"
            )
        discovered_arches = require_string_list(
            availability_entry["discovered_arches"],
            f"{platform_availability_path} platforms.{platform_id}.discovered_arches",
        )
        digest = str(availability_entry["digest"])
        supported_platforms = resolve_supported_docker_platforms(platform_id, discovered_arches)

        docker_platforms[str(platform_id)] = {
            "base_image": f"{image}@{digest}",
            "platforms": ",".join(supported_platforms),
        }

    if not docker_platforms:
        die(
            f"{platform_catalog_path} has no runtime=docker platforms"
        )
    return docker_platforms


def main() -> None:
    args = parse_args()
    github_output = str(args.github_output or "").strip()
    compose_output = str(args.compose_output or "").strip()
    if not github_output and not compose_output and not args.list_targets:
        die("One of --github-output / GITHUB_OUTPUT, --compose-output, or --list-targets must be provided")
    platform_catalog_path = Path(args.platform_catalog)
    platform_availability_path = Path(args.platform_availability)
    dockerfile = Path("docker") / "Dockerfile"
    if not dockerfile.exists():
        die(f"Missing shared Dockerfile: {dockerfile}")

    docker_platforms = load_docker_build_platforms(
        platform_catalog_path, platform_availability_path
    )

    target_raw = str(args.target).strip()
    selected_names: set[str] = set()
    if target_raw.lower() != "all":
        selected_names = {name.strip() for name in target_raw.split(",") if name.strip()}
        if not selected_names:
            die("Resolved empty --target selection")

    known_names: set[str] = set()
    include: list[dict[str, str]] = []
    for platform_id, platform_info in docker_platforms.items():
        base_image = platform_info["base_image"]
        target_platforms = platform_info["platforms"]
        for build_tool in BUILD_TOOLS:
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
