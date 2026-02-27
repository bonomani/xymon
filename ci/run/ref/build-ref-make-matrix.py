#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
from pathlib import Path

import yaml
from matrix_common import (
    die,
    load_lanes_from_file,
    require_mapping,
    require_non_empty_string,
    validate_dropdown_parity,
)

SUPPORTED_RUNTIMES = {"linux_container", "bsd_vm"}
RESERVED_REF_MAKE_WORKFLOWS = {"ref-make-reusable.yml", "ref-make-select.yml"}

def load_manifest(path: Path):
    if not path.exists():
        die(f"Missing families manifest: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    runtime_defaults_raw = data.get("runtime_defaults", {})
    if runtime_defaults_raw is None:
        runtime_defaults_raw = {}
    runtime_defaults_raw = require_mapping(
        runtime_defaults_raw, f"Manifest runtime_defaults in {path}"
    )

    runtime_defaults = {}
    for runtime_key, defaults in runtime_defaults_raw.items():
        runtime_key = require_non_empty_string(
            runtime_key, f"Manifest runtime_defaults key in {path}"
        )
        if runtime_key not in SUPPORTED_RUNTIMES:
            die(f"Manifest has invalid runtime_defaults key '{runtime_key}'")
        runtime_defaults[runtime_key] = require_mapping(
            defaults, f"Manifest runtime_defaults.{runtime_key}"
        )

    entries = data.get("families")
    if not isinstance(entries, list) or not entries:
        die(f"Manifest has no families list: {path}")

    families = []
    seen_families = set()
    for index, raw in enumerate(entries):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(
            entry.get("family"), f"Manifest entry #{index}.family"
        )
        runtime = require_non_empty_string(
            entry.get("runtime"), f"Manifest entry #{index}.runtime"
        )
        lane_file = require_non_empty_string(
            entry.get("lane_file"), f"Manifest entry #{index}.lane_file"
        )
        if runtime not in SUPPORTED_RUNTIMES:
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

        families.append(
            {
                "family": family,
                "runtime": runtime,
                "lane_file": lane_file,
                "runtime_defaults": dict(runtime_defaults.get(runtime, {})),
                "lane_overrides": lane_overrides,
            }
        )

    return families

def validate_wrapper_parity(repo_root: Path, families):
    workflows_dir = repo_root / ".github" / "workflows"
    expected_wrappers = [f"ref-make-{entry['family']}.yml" for entry in families]

    actual_wrappers = sorted(
        path.name
        for path in workflows_dir.glob("ref-make-*.yml")
        if path.name not in RESERVED_REF_MAKE_WORKFLOWS
    )
    if sorted(expected_wrappers) != actual_wrappers:
        die(
            "ref-make wrapper workflow set drifts from manifest\n"
            f"expected: {sorted(expected_wrappers)}\n"
            f"actual:   {actual_wrappers}"
        )

    for entry in families:
        family = entry["family"]
        wrapper_path = workflows_dir / f"ref-make-{family}.yml"
        wrapper_data = yaml.safe_load(wrapper_path.read_text()) or {}

        on_config = wrapper_data.get("on", wrapper_data.get(True, {}))
        if not isinstance(on_config, dict) or "workflow_dispatch" not in on_config:
            die(f"{wrapper_path} must define workflow_dispatch")

        jobs = wrapper_data.get("jobs")
        if not isinstance(jobs, dict) or len(jobs) != 1:
            die(f"{wrapper_path} must define exactly one wrapper job")

        _, job = next(iter(jobs.items()))
        if not isinstance(job, dict):
            die(f"{wrapper_path} wrapper job must be a mapping")

        if job.get("uses") != "./.github/workflows/ref-make-select.yml":
            die(
                f"{wrapper_path} wrapper job must use "
                "./.github/workflows/ref-make-select.yml"
            )

        with_block = job.get("with", {})
        if not isinstance(with_block, dict) or with_block.get("family") != family:
            die(f"{wrapper_path} wrapper job must pass with.family={family!r}")


def validate_workflow_list_parity(script_path: Path, expected_workflows):
    if not script_path.exists():
        die(f"Missing workflow list script: {script_path}")

    result = subprocess.run(
        ["bash", str(script_path)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    listed = [line.strip() for line in result.stdout.splitlines() if line.strip()]

    if listed != expected_workflows:
        die(
            "ref-make workflow list script drifts from manifest\n"
            f"expected: {expected_workflows}\n"
            f"actual:   {listed}"
        )

def normalize_lane(family_entry, lane):
    lane_obj = dict(family_entry["runtime_defaults"])
    lane_obj.update(family_entry["lane_overrides"])
    lane_obj.update(dict(lane))

    required = ("name", "variant", "runtime", "runs_on", "build_tool", "ref_os")
    for key in required:
        if lane_obj.get(key) in (None, ""):
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' is missing '{key}'"
            )

    runtime = lane_obj["runtime"]
    if runtime == "bsd_vm" and lane_obj.get("os_version") in (None, ""):
        die(
            f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
            f"'{family_entry['family']}' is missing 'os_version'"
        )

    return lane_obj


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build matrix outputs for ref-make-select.yml"
    )
    parser.add_argument("--selected-family", required=True)
    parser.add_argument("--manifest", default="ci/run/ref/ref-make-families.yml")
    parser.add_argument(
        "--selector-workflow",
        default=".github/workflows/ref-make-select.yml",
    )
    parser.add_argument(
        "--workflow-list-script",
        default="ci/run/ref/list-ref-make-workflows.sh",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def main():
    args = parse_args()
    github_output = args.github_output
    if not github_output:
        die("GITHUB_OUTPUT is not set and --github-output was not provided")

    repo_root = Path(__file__).resolve().parents[3]
    families = load_manifest(repo_root / args.manifest)
    expected_options = ["all"] + [entry["family"] for entry in families]
    validate_dropdown_parity(repo_root / args.selector_workflow, expected_options)
    validate_wrapper_parity(repo_root, families)
    expected_workflows = [f"ref-make-{entry['family']}.yml" for entry in families]
    validate_workflow_list_parity(repo_root / args.workflow_list_script, expected_workflows)

    lookup = {entry["family"]: entry for entry in families}
    selected_family = args.selected_family
    if selected_family == "all":
        selected_entries = families
    else:
        if selected_family not in lookup:
            die(f"Unsupported family input: {selected_family}")
        selected_entries = [lookup[selected_family]]

    matrix_entries = []
    selected_families = []
    for family_entry in selected_entries:
        selected_families.append(family_entry["family"])
        lanes = load_lanes_from_file(
            repo_root / family_entry["lane_file"], strict_lane_mapping=True
        )
        for lane in lanes:
            normalized = normalize_lane(family_entry, lane)
            matrix_entries.append(
                {
                    "family": family_entry["family"],
                    "lane": normalized,
                }
            )

    matrix = {"include": matrix_entries}
    output_path = Path(github_output)
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"matrix={json.dumps(matrix)}\n")
        fh.write(f"lane_count={len(matrix_entries)}\n")
        fh.write(f"selected_families={','.join(selected_families)}\n")


if __name__ == "__main__":
    main()
