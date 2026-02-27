#!/usr/bin/env python3
"""Shared helpers for ref-validation lane YAML parsing/expansion."""

from __future__ import annotations

from pathlib import Path


VARIANT_NAME_SUFFIX = {
    "server": "Server",
    "localclient": "Client (ct-client)",
    "client": "Client (ct-server)",
}

SUPPORTED_LANE_VARIANTS = frozenset(VARIANT_NAME_SUFFIX.keys())


class LaneSpecError(ValueError):
    """Invalid lane schema/contents."""


def extract_lane_include(
    lane_doc,
    lane_file: Path,
    *,
    require_include_key: bool = False,
):
    """Return the list of lane entries from a lane YAML document."""
    if isinstance(lane_doc, list):
        include = lane_doc
    elif isinstance(lane_doc, dict):
        if require_include_key and "include" not in lane_doc and "lanes" not in lane_doc:
            raise LaneSpecError(f"Lane file must define an 'include' list: {lane_file}")
        include = lane_doc.get("include", lane_doc.get("lanes", []))
    else:
        raise LaneSpecError(f"Lane file must be a list or mapping: {lane_file}")

    if not isinstance(include, list):
        raise LaneSpecError(f"Lane file include value is not a list: {lane_file}")
    return include


def _require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise LaneSpecError(f"{context} must be a non-empty string")
    return value.strip()


def expand_lane_variants(lane_obj, lane_file: Path, lane_index: int):
    """Expand a lane containing 'variants' into concrete lane mappings."""
    variants = lane_obj.get("variants")
    if variants is None:
        return [dict(lane_obj)]

    if "variant" in lane_obj:
        raise LaneSpecError(
            f"Lane file {lane_file} lane #{lane_index} cannot set both "
            "'variant' and 'variants'"
        )

    if not isinstance(variants, list) or not variants:
        raise LaneSpecError(f"Lane file {lane_file} lane #{lane_index} has invalid 'variants' list")

    name_prefix = _require_non_empty_string(
        lane_obj.get("name_prefix"),
        f"Lane file {lane_file} lane #{lane_index}.name_prefix",
    )

    base_lane = dict(lane_obj)
    base_lane.pop("variants", None)
    base_lane.pop("name_prefix", None)

    expanded = []
    for variant_index, raw_variant in enumerate(variants):
        context = f"Lane file {lane_file} lane #{lane_index} variants entry #{variant_index}"
        variant_overrides = {}
        if isinstance(raw_variant, str):
            variant = _require_non_empty_string(raw_variant, context)
        elif isinstance(raw_variant, dict):
            variant_overrides = dict(raw_variant)
            variant = _require_non_empty_string(
                variant_overrides.pop("variant", None), f"{context}.variant"
            )
        else:
            raise LaneSpecError(f"{context} must be a string or mapping")

        default_suffix = VARIANT_NAME_SUFFIX.get(variant)
        if not default_suffix:
            raise LaneSpecError(f"{context} has unsupported variant '{variant}'")

        custom_name = variant_overrides.pop("name", None)
        if custom_name is not None:
            custom_name = _require_non_empty_string(custom_name, f"{context}.name")

        custom_suffix = variant_overrides.pop("name_suffix", None)
        if custom_suffix is not None:
            custom_suffix = _require_non_empty_string(custom_suffix, f"{context}.name_suffix")

        if custom_name and custom_suffix:
            raise LaneSpecError(f"{context} cannot set both 'name' and 'name_suffix'")

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
