#!/usr/bin/env python3

from pathlib import Path

import yaml
from lane_utils import LaneSpecError, expand_lane_variants, extract_lane_include


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


def parse_supported_build_tools(value, context: str, *, supported_values=None):
    if value is None:
        return None
    if isinstance(value, str):
        values = [value]
    elif isinstance(value, list) and value:
        values = value
    else:
        die(f"{context} must be a non-empty string or list")

    normalized = []
    for index, raw in enumerate(values):
        tool = require_non_empty_string(raw, f"{context} entry #{index}")
        if supported_values is not None and tool not in supported_values:
            die(f"{context} entry #{index} has unsupported value '{tool}'")
        normalized.append(tool)
    return normalized


def infer_platform_os(family: str, platform_id=None) -> str:
    """Return the concrete platform OS/family for a lane."""
    if isinstance(platform_id, str):
        platform_id = platform_id.strip()
    if platform_id:
        return platform_id.split("-", 1)[0]
    return require_non_empty_string(family, "Lane family")


def infer_artifact_arch(lane_obj) -> str:
    """Return a stable arch label for artifact naming."""
    architecture = str(lane_obj.get("architecture") or "").strip().lower()
    if architecture:
        normalized = architecture.replace("_", "-")
        if normalized in {"x86-64", "x86_64", "amd64"}:
            return "amd64"
        if normalized in {"arm64", "aarch64"}:
            return "arm64"
        return normalized

    container_options = str(lane_obj.get("container_options") or "").strip().lower()
    if "linux/arm64" in container_options:
        return "arm64"

    runner = str(lane_obj.get("runner") or lane_obj.get("runs_on") or "").strip().lower()
    if "-arm" in runner or "arm64" in runner or "aarch64" in runner:
        return "arm64"

    lane_name = str(lane_obj.get("name") or "").strip().lower()
    if " arm64" in lane_name or lane_name.endswith("arm64") or " aarch64" in lane_name:
        return "arm64"
    if " x86-64" in lane_name or lane_name.endswith("x86-64") or " amd64" in lane_name:
        return "amd64"

    return "amd64"


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


def load_purpose_manifest_common(
    path: Path,
    *,
    purpose: str,
    supported_runtimes,
    include_lane_defaults=False,
):
    if not path.exists():
        die(f"Missing families manifest: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    data = require_mapping(data, f"Manifest root in {path}")

    purpose = require_non_empty_string(purpose, f"Manifest purpose in {path}")
    supported_runtime_keys = set(supported_runtimes)

    runtime_defaults_root = data.get("runtime_defaults", {})
    if runtime_defaults_root is None:
        runtime_defaults_root = {}
    runtime_defaults_root = require_mapping(
        runtime_defaults_root, f"Manifest runtime_defaults in {path}"
    )
    runtime_defaults_raw = runtime_defaults_root.get(purpose, {})
    if runtime_defaults_raw is None:
        runtime_defaults_raw = {}
    runtime_defaults_raw = require_mapping(
        runtime_defaults_raw, f"Manifest runtime_defaults.{purpose} in {path}"
    )

    runtime_defaults = {}
    for runtime_key, defaults in runtime_defaults_raw.items():
        runtime_key = require_non_empty_string(
            runtime_key, f"Manifest runtime_defaults.{purpose} key in {path}"
        )
        if runtime_key not in supported_runtime_keys:
            die(
                f"Manifest has invalid runtime_defaults.{purpose} key '{runtime_key}'"
            )
        runtime_defaults[runtime_key] = require_mapping(
            defaults, f"Manifest runtime_defaults.{purpose}.{runtime_key}"
        )

    lane_defaults = {}
    if include_lane_defaults:
        lane_defaults_root = data.get("lane_defaults", {})
        if lane_defaults_root is None:
            lane_defaults_root = {}
        lane_defaults_root = require_mapping(
            lane_defaults_root, f"Manifest lane_defaults in {path}"
        )
        lane_defaults_raw = lane_defaults_root.get(purpose, {})
        if lane_defaults_raw is None:
            lane_defaults_raw = {}
        lane_defaults_raw = require_mapping(
            lane_defaults_raw, f"Manifest lane_defaults.{purpose} in {path}"
        )

        for runtime_key, defaults in lane_defaults_raw.items():
            runtime_key = require_non_empty_string(
                runtime_key, f"Manifest lane_defaults.{purpose} key in {path}"
            )
            if runtime_key not in supported_runtime_keys:
                die(
                    f"Manifest has invalid lane_defaults.{purpose} key '{runtime_key}'"
                )
            defaults = require_mapping(
                defaults, f"Manifest lane_defaults.{purpose}.{runtime_key}"
            )
            lane_defaults[runtime_key] = {}
            for default_name, default_value in defaults.items():
                default_name = require_non_empty_string(
                    default_name,
                    f"Manifest lane_defaults.{purpose}.{runtime_key} default name in {path}",
                )
                lane_defaults[runtime_key][default_name] = require_mapping(
                    default_value,
                    f"Manifest lane_defaults.{purpose}.{runtime_key}.{default_name}",
                )

    entries = data.get("families")
    if not isinstance(entries, list) or not entries:
        die(f"Manifest has no families list: {path}")

    normalized_entries = []
    seen_families = set()
    for index, raw in enumerate(entries):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(
            entry.get("family"), f"Manifest entry #{index}.family"
        )
        if family in seen_families:
            die(f"Duplicate family in manifest: {family}")
        seen_families.add(family)

        purpose_entry = entry.get(purpose)
        if purpose_entry is None:
            continue
        purpose_entry = require_mapping(
            purpose_entry, f"Manifest entry {family}.{purpose}"
        )

        enabled = purpose_entry.get("enabled", True)
        if enabled is False:
            continue
        if enabled is not True:
            die(f"Manifest entry {family}.{purpose}.enabled must be a boolean")

        runtime = require_non_empty_string(
            purpose_entry.get("runtime"), f"Manifest entry {family}.{purpose}.runtime"
        )
        lane_file = require_non_empty_string(
            purpose_entry.get("lane_file"),
            f"Manifest entry {family}.{purpose}.lane_file",
        )

        if runtime not in supported_runtime_keys:
            die(
                f"Manifest entry {family}.{purpose} has invalid runtime '{runtime}'"
            )

        lane_overrides = purpose_entry.get("lane_overrides", {})
        if lane_overrides is None:
            lane_overrides = {}
        lane_overrides = require_mapping(
            lane_overrides, f"Manifest entry {family}.{purpose}.lane_overrides"
        )

        normalized_entries.append(
            {
                "family": family,
                "runtime": runtime,
                "lane_file": lane_file,
                "lane_overrides": lane_overrides,
                "raw": purpose_entry,
                "family_raw": entry,
            }
        )

    return {
        "runtime_defaults": runtime_defaults,
        "lane_defaults": lane_defaults,
        "entries": normalized_entries,
    }


def load_lanes_from_file(
    lane_file: Path,
    *,
    shared_defaults=None,
    strict_lane_mapping=False,
):
    if not lane_file.exists():
        die(f"Missing lane file: {lane_file}")

    if shared_defaults is None:
        shared_defaults = {}
    shared_defaults = require_mapping(
        shared_defaults, f"Shared lane defaults for {lane_file}"
    )

    data = yaml.safe_load(lane_file.read_text()) or {}
    lane_defaults = {}
    if isinstance(data, dict):
        lane_defaults = data.get("defaults", {})
        if lane_defaults is None:
            lane_defaults = {}
        lane_defaults = require_mapping(lane_defaults, f"Lane file defaults: {lane_file}")

    try:
        lanes = extract_lane_include(data, lane_file, require_include_key=isinstance(data, dict))
    except LaneSpecError as exc:
        die(str(exc))

    normalized_defaults = {}
    for default_name, default_value in shared_defaults.items():
        default_name = require_non_empty_string(
            default_name, f"Shared lane default name for {lane_file}"
        )
        normalized_defaults[default_name] = require_mapping(
            default_value, f"Shared lane default '{default_name}' for {lane_file}"
        )

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
            if strict_lane_mapping:
                die(f"Lane entry #{index} in {lane_file} must be a mapping")
            expanded_lanes.append(lane)
            continue

        lane_obj = dict(lane)
        try:
            expanded_lanes.extend(expand_lane_variants(lane_obj, lane_file, index))
        except LaneSpecError as exc:
            die(str(exc))

    resolved_lanes = []
    for index, lane in enumerate(expanded_lanes):
        if not isinstance(lane, dict):
            if strict_lane_mapping:
                die(f"Lane entry #{index} in {lane_file} must be a mapping")
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
