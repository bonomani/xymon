#!/usr/bin/env python3
"""Resolve release metadata and package build matrix for package workflows."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import yaml


def die(message: str) -> None:
    raise SystemExit(message)


def require_non_empty(value: str, context: str) -> str:
    if not value:
        die(f"{context} must be non-empty")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve package build inputs and matrix"
    )
    parser.add_argument("--release-version", default="")
    parser.add_argument("--package-set", default="all")
    parser.add_argument(
        "--github-output", default=os.environ.get("GITHUB_OUTPUT", "")
    )
    return parser.parse_args()


def normalize_package_set(raw_value: str) -> str:
    value = str(raw_value or "all").strip().lower()
    if value not in {"all", "deb", "rpm"}:
        die(f"Unsupported package_set: {value}")
    return value


def resolve_release_version(explicit_version: str) -> str:
    release_version = str(explicit_version or "").strip()
    if release_version:
        return release_version

    ref_type = os.environ.get("GITHUB_REF_TYPE", "").strip()
    ref_name = os.environ.get("GITHUB_REF_NAME", "").strip()
    if ref_type == "tag" and ref_name.startswith("rel-"):
        return ref_name[4:]

    die("Missing release version. Provide inputs.release_version or run on tag rel-*.")


def load_packaging_config() -> dict[str, dict]:
    repo_root = Path(__file__).resolve().parents[3]
    data_path = repo_root / "ci/deps/data/packaging.yaml"
    data = yaml.safe_load(data_path.read_text(encoding="utf-8")) or {}
    packaging = data.get("packaging")
    if not isinstance(packaging, dict) or not packaging:
        die(f"Missing or invalid packaging mapping in {data_path}")
    return packaging


def resolve_host_packages(workflow: dict, package_kind: str) -> str:
    packages = workflow.get("host_packages")
    if not isinstance(packages, list) or not packages:
        die(f"Missing workflow.host_packages for package kind: {package_kind}")

    normalized: list[str] = []
    seen: set[str] = set()
    for raw_package in packages:
        package = str(raw_package or "").strip()
        if not package:
            die(f"Invalid workflow.host_packages entry for package kind '{package_kind}': {raw_package!r}")
        if package in seen:
            continue
        seen.add(package)
        normalized.append(package)
    return "\n".join(normalized)


def build_matrix(
    packaging_config: dict[str, dict],
    package_set: str,
    release_version: str,
) -> dict[str, list[dict[str, str]]]:
    selected = ["deb", "rpm"] if package_set == "all" else [package_set]
    include: list[dict[str, str]] = []
    for kind in selected:
        raw_entry = packaging_config.get(kind)
        if not isinstance(raw_entry, dict):
            die(f"Missing packaging entry: {kind}")
        workflow = raw_entry.get("workflow")
        if not isinstance(workflow, dict):
            die(f"Missing workflow metadata for package kind: {kind}")

        build_script = str(workflow.get("build_script") or "").strip()
        artifact_prefix = str(workflow.get("artifact_name_prefix") or "").strip()
        artifact_paths = workflow.get("artifact_paths")
        if not build_script or not artifact_prefix:
            die(f"Incomplete workflow metadata for package kind: {kind}")
        if not isinstance(artifact_paths, list):
            die(f"Invalid artifact paths for package kind: {kind}")
        host_packages = resolve_host_packages(workflow, kind)
        include.append(
            {
                "name": kind,
                "build_script": build_script,
                "artifact_name": f"{artifact_prefix}_{release_version}",
                "artifact_paths": "\n".join(str(path) for path in artifact_paths),
                "host_packages": host_packages,
            }
        )
    return {"include": include}


def write_outputs(
    output_path: Path,
    *,
    release_version: str,
    matrix: dict[str, list[dict[str, str]]],
) -> None:
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"release_version={release_version}\n")
        fh.write("matrix<<EOF\n")
        fh.write(json.dumps(matrix))
        fh.write("\nEOF\n")
        fh.write(f"matrix_count={len(matrix['include'])}\n")


def main() -> None:
    args = parse_args()
    output_path = Path(require_non_empty(args.github_output, "--github-output / GITHUB_OUTPUT"))
    package_set = normalize_package_set(args.package_set)
    release_version = resolve_release_version(args.release_version)
    packaging_config = load_packaging_config()
    matrix = build_matrix(packaging_config, package_set, release_version)
    write_outputs(
        output_path,
        release_version=release_version,
        matrix=matrix,
    )


if __name__ == "__main__":
    main()
