#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path

import yaml

RUNTIME_TO_MATRIX_KEY = {
    "linux_container": "linux",
    "bsd_vm": "bsd",
    "macos_host": "macos",
}


def die(message: str) -> None:
    raise SystemExit(message)


def require_mapping(value, context: str):
    if not isinstance(value, dict):
        die(f"{context} must be a mapping")
    return value


def require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value:
        die(f"{context} must be a non-empty string")
    return value


def load_manifest(path: Path):
    if not path.exists():
        die(f"Missing families manifest: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    entries = data.get("families")
    if not isinstance(entries, list) or not entries:
        die(f"Manifest has no families list: {path}")

    families = []
    seen_families = set()
    for index, raw in enumerate(entries):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(entry.get("family"), f"Manifest entry #{index}.family")
        runtime = require_non_empty_string(entry.get("runtime"), f"Manifest entry #{index}.runtime")
        lane_file = require_non_empty_string(
            entry.get("lane_file"), f"Manifest entry #{index}.lane_file"
        )

        if runtime not in RUNTIME_TO_MATRIX_KEY:
            die(f"Manifest entry has invalid runtime '{runtime}': {entry!r}")
        if family in seen_families:
            die(f"Duplicate family in manifest: {family}")
        seen_families.add(family)

        lane_overrides = entry.get("lane_overrides", {})
        if lane_overrides is None:
            lane_overrides = {}
        lane_overrides = require_mapping(
            lane_overrides, f"Manifest entry {family}.lane_overrides"
        )

        container_arm64_overrides = entry.get("container_arm64_overrides")
        if container_arm64_overrides is not None:
            container_arm64_overrides = require_mapping(
                container_arm64_overrides,
                f"Manifest entry {family}.container_arm64_overrides",
            )

        os_version_key = entry.get("os_version_key")
        if os_version_key is not None:
            os_version_key = require_non_empty_string(
                os_version_key, f"Manifest entry {family}.os_version_key"
            )

        default_architecture = entry.get("default_architecture")
        if default_architecture is not None:
            default_architecture = require_non_empty_string(
                default_architecture, f"Manifest entry {family}.default_architecture"
            )

        runner_key = entry.get("runner_key")
        default_runner = entry.get("default_runner")
        if runner_key is not None:
            runner_key = require_non_empty_string(
                runner_key, f"Manifest entry {family}.runner_key"
            )
            default_runner = require_non_empty_string(
                default_runner, f"Manifest entry {family}.default_runner"
            )
        elif default_runner is not None:
            die(f"Manifest entry {family} sets default_runner without runner_key")

        families.append(
            {
                "family": family,
                "runtime": runtime,
                "lane_file": lane_file,
                "lane_overrides": lane_overrides,
                "container_arm64_overrides": container_arm64_overrides,
                "os_version_key": os_version_key,
                "default_architecture": default_architecture,
                "runner_key": runner_key,
                "default_runner": default_runner,
            }
        )

    return families


def validate_dropdown_parity(selector_workflow_path: Path, expected_options):
    if not selector_workflow_path.exists():
        die(f"Missing selector workflow: {selector_workflow_path}")

    workflow_data = yaml.safe_load(selector_workflow_path.read_text()) or {}
    on_config = workflow_data.get("on", workflow_data.get(True, {}))
    if not isinstance(on_config, dict):
        die(f"Workflow 'on' block is not a mapping: {selector_workflow_path}")

    declared_options = (
        on_config.get("workflow_dispatch", {})
        .get("inputs", {})
        .get("family", {})
        .get("options", [])
    )
    if declared_options != expected_options:
        die(
            "workflow_dispatch family options drift from manifest\n"
            f"expected: {expected_options}\n"
            f"actual:   {declared_options}"
        )


def load_lanes_from_file(lane_file: Path):
    if not lane_file.exists():
        die(f"Missing lane file: {lane_file}")

    data = yaml.safe_load(lane_file.read_text()) or {}
    if isinstance(data, list):
        lanes = data
    elif isinstance(data, dict):
        if "include" in data:
            lanes = data.get("include")
        elif "lanes" in data:
            lanes = data.get("lanes")
        else:
            die(f"Lane file must define an 'include' list: {lane_file}")
    else:
        die(f"Lane file must be a list or mapping: {lane_file}")

    if not isinstance(lanes, list):
        die(f"Lane file include value is not a list: {lane_file}")

    return lanes


def normalize_lane(family_entry, lane):
    lane_obj = dict(lane)
    lane_obj.setdefault("allow_failure", False)
    lane_obj.update(family_entry["lane_overrides"])

    arm64_overrides = family_entry["container_arm64_overrides"]
    if arm64_overrides and family_entry["runtime"] == "linux_container":
        container_options = str(lane_obj.get("container_options", "")).lower()
        if "linux/arm64" in container_options:
            lane_obj.update(arm64_overrides)

    os_version_key = family_entry["os_version_key"]
    if os_version_key:
        lane_obj["os_version"] = lane_obj.get(os_version_key)
        if lane_obj["os_version"] in (None, ""):
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' is missing '{os_version_key}'"
            )

    default_architecture = family_entry["default_architecture"]
    if default_architecture:
        lane_obj.setdefault("architecture", default_architecture)

    runner_key = family_entry["runner_key"]
    if runner_key:
        lane_obj.setdefault(runner_key, family_entry["default_runner"])

    return lane_obj


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build matrix outputs for ref-validate-select.yml"
    )
    parser.add_argument("--selected-family", required=True)
    parser.add_argument(
        "--manifest",
        default="ci/run/ref/ref-validate-families.yml",
    )
    parser.add_argument(
        "--selector-workflow",
        default=".github/workflows/ref-validate-select.yml",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def main():
    args = parse_args()
    github_output = args.github_output
    if not github_output:
        die("GITHUB_OUTPUT is not set and --github-output was not provided")

    families = load_manifest(Path(args.manifest))
    expected_options = ["all"] + [entry["family"] for entry in families]
    validate_dropdown_parity(Path(args.selector_workflow), expected_options)

    lookup = {entry["family"]: entry for entry in families}
    selected_family = args.selected_family
    if selected_family == "all":
        selected_entries = families
    else:
        if selected_family not in lookup:
            die(f"Unsupported family input: {selected_family}")
        selected_entries = [lookup[selected_family]]

    matrices = {runtime: [] for runtime in RUNTIME_TO_MATRIX_KEY}
    selected_families = []

    for family_entry in selected_entries:
        selected_families.append(family_entry["family"])
        lanes = load_lanes_from_file(Path(family_entry["lane_file"]))
        for lane in lanes:
            if not isinstance(lane, dict):
                continue
            normalized = normalize_lane(family_entry, lane)
            matrices[family_entry["runtime"]].append(
                {
                    "family": family_entry["family"],
                    "lane": normalized,
                }
            )

    matrix_linux = {"include": matrices["linux_container"]}
    matrix_bsd = {"include": matrices["bsd_vm"]}
    matrix_macos = {"include": matrices["macos_host"]}
    lane_count_linux = len(matrix_linux["include"])
    lane_count_bsd = len(matrix_bsd["include"])
    lane_count_macos = len(matrix_macos["include"])
    lane_count_total = lane_count_linux + lane_count_bsd + lane_count_macos

    output_path = Path(github_output)
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"matrix_linux={json.dumps(matrix_linux)}\n")
        fh.write(f"matrix_bsd={json.dumps(matrix_bsd)}\n")
        fh.write(f"matrix_macos={json.dumps(matrix_macos)}\n")
        fh.write(f"lane_count_total={lane_count_total}\n")
        fh.write(f"lane_count_linux={lane_count_linux}\n")
        fh.write(f"lane_count_bsd={lane_count_bsd}\n")
        fh.write(f"lane_count_macos={lane_count_macos}\n")
        fh.write(f"selected_families={','.join(selected_families)}\n")


if __name__ == "__main__":
    main()
