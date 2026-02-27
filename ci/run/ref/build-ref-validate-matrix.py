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

RUNTIME_TO_PLATFORM_RUNTIME = {
    "linux_container": "docker",
    "bsd_vm": "vm",
    "macos_host": "host",
}

VARIANT_NAME_SUFFIX = {
    "server": "Server",
    "localclient": "Client (ct-client)",
    "client": "Client (ct-server)",
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
        if runtime_key not in RUNTIME_TO_MATRIX_KEY:
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
                "runtime_overrides": dict(runtime_defaults.get(runtime, {})),
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


def expand_lane_variants(lane_obj, lane_file: Path, lane_index: int):
    variants = lane_obj.get("variants")
    if variants is None:
        return [lane_obj]

    if "variant" in lane_obj:
        die(
            f"Lane file {lane_file} lane #{lane_index} cannot set both "
            "'variant' and 'variants'"
        )

    if not isinstance(variants, list) or not variants:
        die(f"Lane file {lane_file} lane #{lane_index} has invalid 'variants' list")

    name_prefix = require_non_empty_string(
        lane_obj.get("name_prefix"),
        f"Lane file {lane_file} lane #{lane_index}.name_prefix",
    )

    base_lane = dict(lane_obj)
    base_lane.pop("variants", None)
    base_lane.pop("name_prefix", None)

    expanded = []
    for variant_index, raw_variant in enumerate(variants):
        context = (
            f"Lane file {lane_file} lane #{lane_index} variants entry #{variant_index}"
        )
        variant_overrides = {}
        if isinstance(raw_variant, str):
            variant = require_non_empty_string(raw_variant, context)
        elif isinstance(raw_variant, dict):
            variant_overrides = dict(raw_variant)
            variant = require_non_empty_string(
                variant_overrides.pop("variant", None), f"{context}.variant"
            )
        else:
            die(f"{context} must be a string or mapping")

        default_suffix = VARIANT_NAME_SUFFIX.get(variant)
        if not default_suffix:
            die(f"{context} has unsupported variant '{variant}'")

        custom_name = variant_overrides.pop("name", None)
        if custom_name is not None:
            custom_name = require_non_empty_string(custom_name, f"{context}.name")

        custom_suffix = variant_overrides.pop("name_suffix", None)
        if custom_suffix is not None:
            custom_suffix = require_non_empty_string(
                custom_suffix, f"{context}.name_suffix"
            )

        if custom_name and custom_suffix:
            die(f"{context} cannot set both 'name' and 'name_suffix'")

        lane_variant = dict(base_lane)
        lane_variant["variant"] = variant
        if custom_name:
            lane_variant["name"] = custom_name
        else:
            suffix = custom_suffix or default_suffix
            lane_variant["name"] = f"{name_prefix} - {suffix}"
        lane_variant.update(variant_overrides)
        expanded.append(lane_variant)

    return expanded


def load_lanes_from_file(lane_file: Path):
    if not lane_file.exists():
        die(f"Missing lane file: {lane_file}")

    data = yaml.safe_load(lane_file.read_text()) or {}
    lane_defaults = {}
    if isinstance(data, list):
        lanes = data
    elif isinstance(data, dict):
        lane_defaults = data.get("defaults", {})
        if lane_defaults is None:
            lane_defaults = {}
        lane_defaults = require_mapping(lane_defaults, f"Lane file defaults: {lane_file}")
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

    normalized_defaults = {}
    for default_name, default_value in lane_defaults.items():
        default_name = require_non_empty_string(
            default_name, f"Lane file default name in {lane_file}"
        )
        normalized_defaults[default_name] = require_mapping(
            default_value, f"Lane file default '{default_name}' in {lane_file}"
        )

    expanded_lanes = []
    for index, lane in enumerate(lanes):
        if not isinstance(lane, dict):
            expanded_lanes.append(lane)
            continue

        lane_obj = dict(lane)
        expanded_lanes.extend(expand_lane_variants(lane_obj, lane_file, index))

    resolved_lanes = []
    for index, lane in enumerate(expanded_lanes):
        if not isinstance(lane, dict):
            resolved_lanes.append(lane)
            continue

        lane_obj = dict(lane)
        resolved_lane = {}

        if "_all" in normalized_defaults:
            resolved_lane.update(normalized_defaults["_all"])

        selected_defaults = lane_obj.pop("defaults", None)
        if selected_defaults is not None:
            if isinstance(selected_defaults, str):
                selected_defaults = [selected_defaults]
            elif isinstance(selected_defaults, list):
                selected_defaults = [
                    require_non_empty_string(
                        value,
                        f"Lane file defaults selector entry #{index} in {lane_file}",
                    )
                    for value in selected_defaults
                ]
            else:
                die(
                    f"Lane file defaults selector must be string or list in "
                    f"{lane_file} lane #{index}"
                )

            for default_name in selected_defaults:
                if default_name == "_all":
                    continue
                if default_name not in normalized_defaults:
                    die(
                        f"Unknown lane default '{default_name}' in {lane_file} "
                        f"lane #{index}"
                    )
                resolved_lane.update(normalized_defaults[default_name])

        resolved_lane.update(lane_obj)
        resolved_lanes.append(resolved_lane)

    return resolved_lanes


def infer_platform_version(platform_id: str) -> str:
    parts = platform_id.split("-", 1)
    if len(parts) != 2 or not parts[1]:
        return ""
    return parts[1].replace("_", ".")


def normalize_lane(family_entry, lane, platform_catalog):
    lane_obj = dict(lane)
    lane_obj.setdefault("allow_failure", False)
    lane_obj.update(family_entry["runtime_overrides"])
    lane_obj.update(family_entry["lane_overrides"])

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
    parser.add_argument(
        "--platform-catalog",
        default="ci/deps/platform-catalog.yaml",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def main():
    args = parse_args()
    github_output = args.github_output
    if not github_output:
        die("GITHUB_OUTPUT is not set and --github-output was not provided")

    families = load_manifest(Path(args.manifest))
    platform_catalog = load_platform_catalog(Path(args.platform_catalog))
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
            normalized = normalize_lane(family_entry, lane, platform_catalog)
            matrices[family_entry["runtime"]].append(
                {
                    "family": family_entry["family"],
                    "lane": normalized,
                }
            )

    matrix_linux = {"include": matrices["linux_container"]}
    matrix_host_vm = {"include": matrices["bsd_vm"] + matrices["macos_host"]}
    lane_count_linux = len(matrix_linux["include"])
    lane_count_host_vm = len(matrix_host_vm["include"])
    lane_count_total = lane_count_linux + lane_count_host_vm

    output_path = Path(github_output)
    with output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"matrix_linux={json.dumps(matrix_linux)}\n")
        fh.write(f"matrix_host_vm={json.dumps(matrix_host_vm)}\n")
        fh.write(f"lane_count_total={lane_count_total}\n")
        fh.write(f"lane_count_linux={lane_count_linux}\n")
        fh.write(f"lane_count_host_vm={lane_count_host_vm}\n")
        fh.write(f"selected_families={','.join(selected_families)}\n")


if __name__ == "__main__":
    main()
