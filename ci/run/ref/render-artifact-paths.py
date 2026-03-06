#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

import yaml


def die(message: str) -> None:
    raise SystemExit(message)


def require_mapping(value, context: str):
    if not isinstance(value, dict):
        die(f"{context} must be a mapping")
    return value


def require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        die(f"{context} must be a non-empty string")
    return value.strip()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Render artifact path list from ci/run/ref/artifact-manifest.yml"
    )
    parser.add_argument("--manifest", required=True, help="Artifact manifest YAML path")
    parser.add_argument("--profile", required=True, help="Profile key under profiles")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        die(f"Missing artifact manifest: {manifest_path}")

    data = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    data = require_mapping(data, f"Artifact manifest root in {manifest_path}")

    profiles = require_mapping(
        data.get("profiles"), f"Artifact manifest profiles in {manifest_path}"
    )
    profile = require_mapping(
        profiles.get(args.profile),
        f"Artifact manifest profile '{args.profile}' in {manifest_path}",
    )
    paths = profile.get("paths")
    if not isinstance(paths, list) or not paths:
        die(
            f"Artifact manifest profile '{args.profile}' has no non-empty 'paths' list"
        )

    seen = set()
    ordered = []
    for index, raw in enumerate(paths):
        path = require_non_empty_string(
            raw,
            f"Artifact manifest profile '{args.profile}'.paths[{index}]",
        )
        if path in seen:
            continue
        seen.add(path)
        ordered.append(path)

    for path in ordered:
        print(path)


if __name__ == "__main__":
    main()
