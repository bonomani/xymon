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
