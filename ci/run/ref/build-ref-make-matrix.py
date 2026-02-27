#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path

from matrix_common import (
    die,
    load_lanes_from_file,
    load_manifest_common,
    require_mapping,
    validate_dropdown_parity,
)

SUPPORTED_RUNTIMES = {"linux_container", "bsd_vm"}

def load_manifest(path: Path):
    manifest_data = load_manifest_common(path, supported_runtimes=SUPPORTED_RUNTIMES)
    runtime_defaults = manifest_data["runtime_defaults"]
    families = []
    for entry in manifest_data["entries"]:
        families.append(
            {
                "family": entry["family"],
                "runtime": entry["runtime"],
                "lane_file": entry["lane_file"],
                "runtime_defaults": dict(runtime_defaults.get(entry["runtime"], {})),
                "lane_overrides": require_mapping(
                    entry["lane_overrides"],
                    f"Manifest entry {entry['family']}.lane_overrides",
                ),
            }
        )
    return families


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
