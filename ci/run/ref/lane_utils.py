#!/usr/bin/env python3
"""Shared helpers for ref-validation lane YAML parsing/expansion."""

from __future__ import annotations

import re
from pathlib import Path


VARIANT_NAME_SUFFIX = {
    "server": "Server",
    "localclient": "Client (ct-client)",
    "client": "Client (ct-server)",
}

SUPPORTED_LANE_VARIANTS = frozenset(VARIANT_NAME_SUFFIX.keys())
DEFAULT_LANE_VARIANTS = ["server", "localclient", "client"]


class LaneSpecError(ValueError):
    """Invalid lane schema/contents."""


def extract_lane_include(
    lane_doc,
    lane_file: Path,
    *,
    require_include_key: bool = False,
    generated_overrides=None,
):
    """Return the list of lane entries from a lane YAML document."""
    if isinstance(lane_doc, list):
        include = lane_doc
    elif isinstance(lane_doc, dict):
        if "generated" in lane_doc:
            include = expand_generated_lanes(
                lane_doc["generated"],
                lane_file,
                generated_overrides=generated_overrides,
            )
        else:
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


def _require_mapping(value, context: str) -> dict:
    if not isinstance(value, dict):
        raise LaneSpecError(f"{context} must be a mapping")
    return value


def _require_string_list(value, context: str) -> list[str]:
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not value:
        raise LaneSpecError(f"{context} must be a non-empty string or list")
    return [_require_non_empty_string(item, f"{context}[{index}]") for index, item in enumerate(value)]


def _version_key(value: str) -> tuple[int, tuple[int, ...], str]:
    numbers = tuple(int(part) for part in re.findall(r"\d+", value))
    return (1 if numbers else 0, numbers, value)


def _infer_platform_version(platform_id: str) -> str:
    parts = platform_id.split("-", 1)
    if len(parts) != 2 or not parts[1]:
        return ""
    return parts[1].replace("_", ".")


def expand_generated_lanes(generated_doc, lane_file: Path, *, generated_overrides=None) -> list[dict]:
    generated = _require_mapping(generated_doc, f"Lane file generated block: {lane_file}")
    platforms = generated.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        raise LaneSpecError(f"Lane file generated.platforms must be a non-empty list: {lane_file}")

    policy = generated.get("policy", {})
    policy = _require_mapping(policy, f"Lane file generated.policy: {lane_file}")
    secondary_defaults = policy.get("secondary_defaults", [])
    if secondary_defaults:
        secondary_defaults = _require_string_list(
            secondary_defaults, f"Lane file generated.policy.secondary_defaults: {lane_file}"
        )
    secondary_scope = policy.get("secondary_scope", "none")
    secondary_scope = _require_non_empty_string(
        secondary_scope, f"Lane file generated.policy.secondary_scope: {lane_file}"
    )
    # Generated lane policy always keeps primary lanes for every listed platform.
    # secondary_scope only controls whether secondary-arch lanes are added:
    # none -> never, all -> every platform, latest_only -> latest stable + rolling ids.
    generated_overrides = _require_mapping(
        generated_overrides or {},
        f"Lane file generated overrides: {lane_file}",
    )
    selected_arch_policy = generated_overrides.get("arch_policy")
    if selected_arch_policy is not None:
        selected_arch_policy = _require_non_empty_string(
            selected_arch_policy,
            f"Lane file generated overrides arch_policy: {lane_file}",
        )
        if selected_arch_policy == "non_primary_all":
            secondary_scope = "all"
        elif selected_arch_policy == "non_primary_none":
            secondary_scope = "none"
        elif selected_arch_policy == "non_primary_latest_only":
            secondary_scope = "latest_only"
        else:
            raise LaneSpecError(
                "Lane file generated overrides arch_policy must be one of "
                f"non_primary_latest_only|non_primary_all|non_primary_none: {lane_file}"
            )
    if secondary_scope not in {"none", "all", "latest_only"}:
        raise LaneSpecError(
            f"Lane file generated.policy.secondary_scope must be one of none|all|latest_only: {lane_file}"
        )
    rolling_platform_ids = {
        value
        for value in _require_string_list(
            policy.get("rolling_platform_ids", []), f"Lane file generated.policy.rolling_platform_ids: {lane_file}"
        )
    } if policy.get("rolling_platform_ids") else set()

    platform_entries = []
    for index, raw_entry in enumerate(platforms):
        entry = _require_mapping(raw_entry, f"Lane file generated.platforms[{index}] in {lane_file}")
        platform_id = _require_non_empty_string(
            entry.get("platform_id"), f"Lane file generated.platforms[{index}].platform_id"
        )
        platform_entries.append((platform_id, dict(entry)))

    stable_entries = [
        (platform_id, entry)
        for platform_id, entry in platform_entries
        if platform_id not in rolling_platform_ids
    ]
    latest_stable = None
    if stable_entries:
        latest_stable = max(
            stable_entries,
            key=lambda item: (_version_key(_infer_platform_version(item[0])), item[0]),
        )[0]

    expanded: list[dict] = []
    for platform_id, entry in platform_entries:
        base_entry = dict(entry)
        secondary_name_prefix = base_entry.pop("name_prefix", None)
        base_entry.pop("arches", None)
        base_entry["platform_id"] = platform_id
        expanded.append(base_entry)

        include_secondary = False
        if secondary_defaults:
            if secondary_scope == "all":
                include_secondary = True
            elif secondary_scope == "latest_only":
                include_secondary = platform_id == latest_stable or platform_id in rolling_platform_ids

        if not include_secondary:
            continue

        secondary_entry = dict(base_entry)
        secondary_entry["defaults"] = list(secondary_defaults)
        if secondary_name_prefix is not None:
            name_prefix = secondary_name_prefix
            name_prefix = _require_non_empty_string(
                name_prefix, f"Lane file generated.platforms name_prefix for {platform_id}"
            )
            secondary_entry["name_prefix"] = f"{name_prefix} {' '.join(secondary_defaults)}"
        expanded.append(secondary_entry)

    return expanded


def expand_lane_variants(lane_obj, lane_file: Path, lane_index: int):
    """Expand a lane mapping into concrete per-variant lane mappings."""
    if "allow_failure" in lane_obj and "variant" not in lane_obj:
        raise LaneSpecError(
            f"Lane file {lane_file} lane #{lane_index} must set allow_failure on concrete variants, "
            "not on the multi-variant entry"
        )

    variants = lane_obj.get("variants")
    if variants is None:
        # When a lane omits explicit variants, expand the conventional
        # server/localclient/client set by default.
        if "variant" in lane_obj:
            return [dict(lane_obj)]
        variants = list(DEFAULT_LANE_VARIANTS)

    if "variant" in lane_obj:
        raise LaneSpecError(
            f"Lane file {lane_file} lane #{lane_index} cannot set both "
            "'variant' and 'variants'"
        )

    if not isinstance(variants, list) or not variants:
        raise LaneSpecError(f"Lane file {lane_file} lane #{lane_index} has invalid 'variants' list")

    name_prefix_raw = lane_obj.get("name_prefix")
    name_prefix = ""
    if name_prefix_raw is not None:
        name_prefix = _require_non_empty_string(
            name_prefix_raw,
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
        elif name_prefix:
            suffix = custom_suffix or default_suffix
            lane_variant["name"] = f"{name_prefix} - {suffix}"
        elif custom_suffix:
            lane_variant["name"] = custom_suffix
        lane_variant.update(variant_overrides)
        expanded.append(lane_variant)

    return expanded
