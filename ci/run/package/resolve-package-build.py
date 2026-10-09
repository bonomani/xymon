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
    parser.add_argument("--package-set", default="deb")
    parser.add_argument(
        "--github-output", default=os.environ.get("GITHUB_OUTPUT", "")
    )
    return parser.parse_args()


ALL_PACKAGE_KINDS = ["deb", "rpm", "arch", "apk", "pkg"]


def normalize_package_set(raw_value: str) -> str:
    value = str(raw_value or "").strip().lower()
    if value not in set(ALL_PACKAGE_KINDS):
        die(f"Unsupported package_set: {value!r}")
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
    if packages is None:
        return ""
    if not isinstance(packages, list):
        die(f"Invalid workflow.host_packages for package kind: {package_kind}")
    if not packages:
        return ""

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
    selected = ALL_PACKAGE_KINDS if not package_set else [package_set]
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
        execution = str(workflow.get("execution") or "host").strip().lower()
        if not build_script or not artifact_prefix:
            die(f"Incomplete workflow metadata for package kind: {kind}")
        if not isinstance(artifact_paths, list):
            die(f"Invalid artifact paths for package kind: {kind}")
        if execution not in {"host", "bsd_vm"}:
            die(f"Unsupported workflow.execution for package kind '{kind}': {execution}")
        host_packages = resolve_host_packages(workflow, kind)
        entry = {
            "name": kind,
            "execution": execution,
            "build_script": build_script,
            "artifact_name": f"{artifact_prefix}_{release_version}",
            "artifact_paths": "\n".join(str(path) for path in artifact_paths),
            "host_packages": host_packages,
        }
        if execution == "bsd_vm":
            vm = workflow.get("vm")
            if not isinstance(vm, dict):
                die(f"Missing workflow.vm metadata for package kind: {kind}")
            for field_name, output_name in (
                ("operating_system", "vm_operating_system"),
                ("version", "vm_version"),
                ("architecture", "vm_architecture"),
                ("shell", "vm_shell"),
                ("memory", "vm_memory"),
                ("cpu_count", "vm_cpu_count"),
            ):
                value = str(vm.get(field_name) or "").strip()
                if not value:
                    die(f"Missing workflow.vm.{field_name} for package kind: {kind}")
                entry[output_name] = value
        include.append(entry)
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
    raw_set = str(args.package_set or "").strip()
    package_set = normalize_package_set(raw_set) if raw_set else ""
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
