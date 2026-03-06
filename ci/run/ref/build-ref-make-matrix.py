#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path

import yaml
from matrix_common import (
    die,
    infer_artifact_arch,
    infer_platform_os,
    load_lanes_from_file,
    load_purpose_manifest_common,
    parse_supported_build_tools,
    require_mapping,
    require_non_empty_string,
    validate_dropdown_parity,
)

RUNTIME_TO_PLATFORM_RUNTIME = {
    "linux_host": "host",
    "linux_container": "docker",
    "bsd_vm": "vm",
    "macos_host": "host",
}

SUPPORTED_BUILD_TOOLS = {"make", "cmake"}
SUPPORTED_PURPOSES = {"generation", "validation"}


def load_manifest(path: Path, purpose: str):
    manifest_data = load_purpose_manifest_common(
        path,
        purpose=purpose,
        supported_runtimes=RUNTIME_TO_PLATFORM_RUNTIME,
        include_lane_defaults=True,
    )
    runtime_defaults = manifest_data["runtime_defaults"]
    lane_defaults = manifest_data["lane_defaults"]

    families = []
    for base_entry in manifest_data["entries"]:
        entry = base_entry["raw"]
        family = base_entry["family"]
        runtime = base_entry["runtime"]
        lane_file = base_entry["lane_file"]
        lane_overrides = require_mapping(
            base_entry["lane_overrides"], f"Manifest entry {family}.lane_overrides"
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
                "runtime_overrides": dict(runtime_defaults.get(runtime, {})),
                "lane_defaults": dict(lane_defaults.get(runtime, {})),
                "lane_overrides": lane_overrides,
                "container_arm64_overrides": container_arm64_overrides,
                "os_version_key": os_version_key,
                "default_architecture": default_architecture,
                "runner_key": runner_key,
                "default_runner": default_runner,
            }
        )

    return families


def load_platform_catalog(path: Path):
    if not path.exists():
        die(f"Missing platform catalog: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    platforms = data.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        die(f"Platform catalog has no platforms mapping: {path}")

    normalized = {}
    for platform_id, entry in platforms.items():
        platform_id = require_non_empty_string(platform_id, "Platform catalog platform id")
        normalized[platform_id] = require_mapping(
            entry, f"Platform catalog entry '{platform_id}'"
        )

    return normalized


def infer_platform_version(platform_id: str) -> str:
    parts = platform_id.split("-", 1)
    if len(parts) != 2 or not parts[1]:
        return ""
    return parts[1].replace("_", ".")


def normalize_lane(family_entry, lane, platform_catalog, build_tool, purpose: str):
    lane_obj = dict(family_entry["runtime_overrides"])
    lane_obj.update(lane)
    if purpose == "validation":
        lane_obj.setdefault("allow_failure", False)
    lane_obj.update(family_entry["lane_overrides"])
    lane_obj["runtime"] = family_entry["runtime"]
    lane_obj["build_tool"] = build_tool

    if lane_obj.get("ref_os") in (None, ""):
        if lane_obj["runtime"] in {"linux_host", "linux_container"}:
            lane_obj["ref_os"] = "linux"
        elif lane_obj["runtime"] == "macos_host":
            lane_obj["ref_os"] = "macos"
        elif lane_obj["runtime"] == "bsd_vm":
            lane_obj["ref_os"] = family_entry["family"]
        else:
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' has unknown runtime '{lane_obj['runtime']}'"
            )

    lane_obj.setdefault("artifact_family", lane_obj["ref_os"])
    lane_obj.setdefault("baseline_root", f"make_{lane_obj['ref_os']}")
    supported_build_tools = parse_supported_build_tools(
        lane_obj.pop("supported_build_tools", None),
        (
            f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
            f"'{family_entry['family']}' supported_build_tools"
        ),
        supported_values=SUPPORTED_BUILD_TOOLS,
    )

    platform_id = lane_obj.get("platform_id")
    if platform_id is not None:
        platform_id = require_non_empty_string(
            platform_id,
            f"Lane '{lane_obj.get('name', '<unnamed>')}' platform_id",
        )
        platform_entry = platform_catalog.get(platform_id)
        if platform_entry is None:
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' references unknown platform_id '{platform_id}'"
            )

        if supported_build_tools is None:
            supported_build_tools = parse_supported_build_tools(
                platform_entry.get("supported_build_tools"),
                f"Platform '{platform_id}'.supported_build_tools",
                supported_values=SUPPORTED_BUILD_TOOLS,
            )

        platform_runtime = require_non_empty_string(
            platform_entry.get("runtime"),
            f"Platform '{platform_id}'.runtime",
        ).lower()
        expected_runtime = RUNTIME_TO_PLATFORM_RUNTIME[family_entry["runtime"]]
        if platform_runtime != expected_runtime:
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' expects runtime '{expected_runtime}' "
                f"but platform '{platform_id}' is '{platform_runtime}'"
            )

        if platform_runtime == "docker":
            lane_obj["container"] = require_non_empty_string(
                platform_entry.get("image"), f"Platform '{platform_id}'.image"
            )
        elif platform_runtime == "host":
            runner_key = family_entry["runner_key"]
            if runner_key:
                lane_obj.setdefault(
                    runner_key,
                    require_non_empty_string(
                        platform_entry.get("runner"), f"Platform '{platform_id}'.runner"
                    ),
                )

        os_version_key = family_entry["os_version_key"]
        if os_version_key and lane_obj.get(os_version_key) in (None, ""):
            inferred_version = ""
            deps = platform_entry.get("deps")
            if isinstance(deps, dict):
                version = deps.get("version")
                if isinstance(version, (str, int, float)):
                    inferred_version = str(version).strip()
            if not inferred_version:
                inferred_version = infer_platform_version(platform_id)
            if inferred_version:
                lane_obj[os_version_key] = inferred_version

    if supported_build_tools is not None and build_tool not in supported_build_tools:
        return None

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

    lane_obj.setdefault(
        "platform_os",
        infer_platform_os(family_entry["family"], lane_obj.get("platform_id")),
    )

    required = ("name", "variant", "runtime", "build_tool", "ref_os", "platform_os")
    for key in required:
        if lane_obj.get(key) in (None, ""):
            die(
                f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
                f"'{family_entry['family']}' is missing '{key}'"
            )

    runtime = lane_obj["runtime"]
    if runtime in {"linux_host", "linux_container", "bsd_vm"} and lane_obj.get("runs_on") in (
        None,
        "",
    ):
        die(
            f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
            f"'{family_entry['family']}' is missing 'runs_on'"
        )
    if runtime == "linux_container" and lane_obj.get("container") in (None, ""):
        die(
            f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
            f"'{family_entry['family']}' is missing 'container'"
        )
    if runtime == "macos_host" and lane_obj.get("runner") in (None, "") and lane_obj.get(
        "runs_on"
    ) in (None, ""):
        die(
            f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
            f"'{family_entry['family']}' is missing 'runner' or 'runs_on'"
        )

    lane_obj["artifact_arch"] = infer_artifact_arch(lane_obj)

    return lane_obj


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build matrix outputs for ref selector workflows"
    )
    parser.add_argument(
        "--purpose",
        default="generation",
        choices=sorted(SUPPORTED_PURPOSES),
        help="Manifest purpose to resolve (generation or validation)",
    )
    parser.add_argument("--selected-family", required=True)
    parser.add_argument(
        "--build-tool",
        required=True,
        choices=sorted(SUPPORTED_BUILD_TOOLS),
        help="Build tool selection (make or cmake)",
    )
    parser.add_argument("--manifest", default="ci/run/ref/ref-families.yml")
    parser.add_argument(
        "--selector-workflow",
        default=".github/workflows/ref-make-select.yml",
    )
    parser.add_argument(
        "--platform-catalog",
        default="ci/deps/platform-catalog.yaml",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def expected_dropdown_families_union(manifest_path: Path) -> list[str]:
    generation_families = {entry["family"] for entry in load_manifest(manifest_path, "generation")}
    validation_families = {entry["family"] for entry in load_manifest(manifest_path, "validation")}
    enabled_union = generation_families | validation_families

    data = yaml.safe_load(manifest_path.read_text()) or {}
    families = data.get("families", [])
    if not isinstance(families, list):
        die(f"Manifest has no families list: {manifest_path}")

    ordered = []
    seen = set()
    for index, raw in enumerate(families):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(entry.get("family"), f"Manifest entry #{index}.family")
        if family in enabled_union and family not in seen:
            ordered.append(family)
            seen.add(family)
    return ordered


def main():
    args = parse_args()
    purpose = args.purpose
    github_output = args.github_output
    if not github_output:
        die("GITHUB_OUTPUT is not set and --github-output was not provided")
    build_tool = args.build_tool
    if build_tool not in SUPPORTED_BUILD_TOOLS:
        die(f"Unsupported build tool: {build_tool}")

    repo_root = Path(__file__).resolve().parents[3]
    families = load_manifest(repo_root / args.manifest, purpose)
    platform_catalog = load_platform_catalog(repo_root / args.platform_catalog)
    expected_options = ["all"] + expected_dropdown_families_union(repo_root / args.manifest)
    validate_dropdown_parity(repo_root / args.selector_workflow, expected_options)

    lookup = {entry["family"]: entry for entry in families}
    selected_family = args.selected_family
    if selected_family == "all":
        selected_entries = families
    else:
        if selected_family not in lookup:
            die(f"Unsupported family input: {selected_family}")
        selected_entries = [lookup[selected_family]]

    matrices = {runtime: [] for runtime in RUNTIME_TO_PLATFORM_RUNTIME}
    selected_families = []
    for family_entry in selected_entries:
        selected_families.append(family_entry["family"])
        lanes = load_lanes_from_file(
            repo_root / family_entry["lane_file"],
            shared_defaults=family_entry.get("lane_defaults", {}),
            strict_lane_mapping=True,
        )
        for lane in lanes:
            if not isinstance(lane, dict):
                continue
            normalized = normalize_lane(
                family_entry, lane, platform_catalog, build_tool, purpose
            )
            if normalized is None:
                continue
            runtime = normalized.get("runtime")
            matrices[runtime].append(
                {
                    "family": family_entry["family"],
                    "lane": normalized,
                }
            )

    matrix_all = {
        "include": [
            *matrices["linux_host"],
            *matrices["linux_container"],
            *matrices["bsd_vm"],
            *matrices["macos_host"],
        ]
    }
    lane_counts = {runtime: len(entries) for runtime, entries in matrices.items()}
    lane_count_total = len(matrix_all["include"])

    output_path = Path(github_output)
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"matrix_all={json.dumps(matrix_all)}\n")
        fh.write(f"lane_count_total={lane_count_total}\n")
        fh.write(f"lane_counts_json={json.dumps(lane_counts, sort_keys=True)}\n")
        fh.write(f"selected_families={','.join(selected_families)}\n")


if __name__ == "__main__":
    main()
