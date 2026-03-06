#!/usr/bin/env python3
"""Resolve docker build matrix from ci/deps/docker-matrix.yaml + platform catalog."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def die(message: str) -> None:
    raise SystemExit(message)


def require_non_empty(value: str, context: str) -> str:
    if not value:
        die(f"{context} must be non-empty")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve docker image build matrix")
    parser.add_argument("--matrix-file", default="ci/deps/docker-matrix.yaml")
    parser.add_argument("--platform-catalog", default="ci/deps/platform-catalog.yaml")
    parser.add_argument("--target", default="all")
    parser.add_argument("--image-tag", default="")
    parser.add_argument("--push", default="no")
    parser.add_argument("--repo-owner", default="")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def load_yaml(path: Path):
    try:
        import yaml  # type: ignore
    except Exception as exc:  # pragma: no cover - runtime environment dependent
        die(
            f"PyYAML is required to parse {path}. Install with 'python3 -m pip install pyyaml'. ({exc})"
        )
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def load_docker_platform_images(path: Path) -> dict[str, str]:
    if not path.exists():
        die(f"Missing platform catalog file: {path}")

    data = load_yaml(path)
    platforms = data.get("platforms", {})
    if not isinstance(platforms, dict) or not platforms:
        die(f"{path} has no platforms mapping")

    docker_platform_images: dict[str, str] = {}
    for platform_id, raw_entry in platforms.items():
        if not isinstance(raw_entry, dict):
            continue
        runtime = str(raw_entry.get("runtime") or "").strip().lower()
        if runtime != "docker":
            continue
        image = str(raw_entry.get("image") or "").strip()
        if not image:
            die(f"platform '{platform_id}' is runtime=docker but has no image")
        docker_platform_images[str(platform_id)] = image

    if not docker_platform_images:
        die(f"{path} has no runtime=docker platforms")
    return docker_platform_images


def main() -> None:
    args = parse_args()
    output_path = require_non_empty(args.github_output, "--github-output / GITHUB_OUTPUT")

    push_raw = str(args.push).strip().lower()
    if push_raw not in {"yes", "no"}:
        die(f"Unsupported push mode: {push_raw}")

    matrix_path = Path(args.matrix_file)
    if not matrix_path.exists():
        die(f"Missing docker matrix file: {matrix_path}")
    platform_catalog_path = Path(args.platform_catalog)

    data = load_yaml(matrix_path)
    docker_platform_images = load_docker_platform_images(platform_catalog_path)
    services = data.get("services", [])
    if not isinstance(services, list) or not services:
        die(f"{matrix_path} has no services list")

    target_raw = str(args.target).strip()
    selected_names: set[str] = set()
    if target_raw.lower() != "all":
        selected_names = {name.strip() for name in target_raw.split(",") if name.strip()}
        if not selected_names:
            die("Resolved empty --target selection")

    repo_owner = str(args.repo_owner or "").strip().lower()
    require_non_empty(repo_owner, "--repo-owner")

    known_names: set[str] = set()
    include: list[dict[str, str]] = []
    for raw_entry in services:
        if not isinstance(raw_entry, dict):
            continue
        name = str(raw_entry.get("name") or "").strip()
        if not name:
            continue
        platform_id = str(raw_entry.get("platform_id") or "").strip()
        if not platform_id:
            die(f"Service '{name}' is missing platform_id")
        if platform_id not in docker_platform_images:
            die(
                f"Service '{name}' references unknown or non-docker platform_id '{platform_id}' "
                f"from {platform_catalog_path}"
            )
        known_names.add(name)
        if selected_names and name not in selected_names:
            continue

        dockerfile = Path("docker") / name / "Dockerfile"
        if not dockerfile.exists():
            die(f"Missing Dockerfile for service '{name}': {dockerfile}")

        include.append(
            {
                "name": name,
                "platform_id": platform_id,
                "base_image": docker_platform_images[platform_id],
                "dockerfile": str(dockerfile),
                "image": f"ghcr.io/{repo_owner}/xymon-{name}",
            }
        )

    if selected_names:
        missing = sorted(selected_names - known_names)
        if missing:
            die("Unknown docker target(s): " + ", ".join(missing))

    image_tag = str(args.image_tag).strip()
    if not image_tag:
        sha = os.environ.get("GITHUB_SHA", "").strip()
        image_tag = f"sha-{sha[:12]}" if sha else "manual"

    matrix = {"include": include}
    with Path(output_path).open("a", encoding="utf-8") as fh:
        fh.write("matrix<<EOF\n")
        fh.write(json.dumps(matrix))
        fh.write("\nEOF\n")
        fh.write(f"matrix_count={len(include)}\n")
        fh.write(f"image_tag={image_tag}\n")
        fh.write(f"push_enabled={'1' if push_raw == 'yes' else '0'}\n")


if __name__ == "__main__":
    main()
