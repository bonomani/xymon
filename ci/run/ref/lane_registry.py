#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml
from lane_utils import VARIANT_NAME_SUFFIX, extract_lane_include, expand_lane_variants
from matrix_common import (
    derive_platform_display_name,
    load_purpose_manifest_common,
    require_mapping,
    require_non_empty_string,
)
from runtime_model import load_runtime_model


@dataclass(frozen=True)
class LaneRecord:
    name: str
    family: str
    lane_file: str
    include_index: int
    variant: str
    platform_id: str
    allow_failure: bool


def _load_platform_display_names(platform_catalog_path: Path) -> dict[str, str]:
    data = yaml.safe_load(platform_catalog_path.read_text(encoding="utf-8")) or {}
    data = require_mapping(data, f"Platform catalog root in {platform_catalog_path}")
    platforms = require_mapping(data.get("platforms"), "Platform catalog 'platforms'")

    display_names: dict[str, str] = {}
    for platform_id, raw_entry in platforms.items():
        platform_key = require_non_empty_string(platform_id, "Platform ID")
        entry = require_mapping(raw_entry, f"Platform '{platform_key}'")
        display_names[platform_key] = derive_platform_display_name(platform_key, entry)
    return display_names


def _load_family_descriptors(manifest_path: Path, runtime_model_path: Path) -> dict[str, dict]:
    runtime_model = load_runtime_model(runtime_model_path)
    runtime_keys = set(runtime_model["ordered_keys"])

    descriptors: dict[str, dict] = {}
    for purpose in ("generation", "validation"):
        manifest_data = load_purpose_manifest_common(
            manifest_path,
            purpose=purpose,
            supported_runtimes=runtime_keys,
            include_lane_defaults=True,
        )
        lane_defaults_by_runtime = manifest_data["lane_defaults"]
        for entry in manifest_data["entries"]:
            family = entry["family"]
            runtime = entry["runtime"]
            lane_file = entry["lane_file"]
            descriptor = descriptors.setdefault(
                family,
                {
                    "family": family,
                    "runtime": runtime,
                    "lane_file": lane_file,
                    "shared_defaults": {},
                },
            )
            if descriptor["runtime"] != runtime:
                raise ValueError(
                    f"Family '{family}' runtime drift detected while loading manifest purposes"
                )
            if descriptor["lane_file"] != lane_file:
                raise ValueError(
                    f"Family '{family}' lane_file drift detected while loading manifest purposes"
                )
            for default_name, default_values in lane_defaults_by_runtime.get(runtime, {}).items():
                descriptor["shared_defaults"].setdefault(default_name, dict(default_values))
    return descriptors


def _load_lane_defaults(doc: object, lane_file: Path, shared_defaults: dict[str, dict]) -> dict[str, dict]:
    defaults = {}
    if isinstance(doc, dict):
        defaults = doc.get("defaults", {}) or {}
    defaults = require_mapping(defaults, f"Lane file defaults: {lane_file}")

    normalized: dict[str, dict] = {}
    for default_name, raw_value in shared_defaults.items():
        key = require_non_empty_string(default_name, f"Shared default key for {lane_file}")
        normalized[key] = require_mapping(raw_value, f"Shared default '{key}' for {lane_file}")
    for default_name, raw_value in defaults.items():
        key = require_non_empty_string(default_name, f"Default key in {lane_file}")
        normalized[key] = require_mapping(raw_value, f"Default '{key}' in {lane_file}")
    return normalized


def _resolve_entry_defaults(entry: dict, defaults: dict[str, dict], lane_file: Path, index: int) -> dict:
    resolved: dict = {}
    if "_all" in defaults:
        resolved.update(defaults["_all"])

    selected_defaults = entry.get("defaults")
    if selected_defaults is not None:
        if isinstance(selected_defaults, str):
            selected = [selected_defaults]
        elif isinstance(selected_defaults, list):
            selected = [require_non_empty_string(value, f"Lane #{index} defaults value in {lane_file}") for value in selected_defaults]
        else:
            raise ValueError(f"Lane #{index} in {lane_file} has invalid defaults selector")

        for default_name in selected:
            if default_name == "_all":
                continue
            if default_name not in defaults:
                raise ValueError(f"Lane #{index} in {lane_file} references unknown default '{default_name}'")
            resolved.update(defaults[default_name])

    resolved.update(entry)
    return resolved


def _derive_lane_name(lane: dict, platform_display_names: dict[str, str]) -> str:
    explicit_name = str(lane.get("name") or "").strip()
    if explicit_name:
        return explicit_name

    platform_id = str(lane.get("platform_id") or "").strip()
    variant = str(lane.get("variant") or "").strip()
    if not platform_id:
        raise ValueError(f"Lane is missing platform_id and has no explicit name: {lane}")
    if not variant:
        raise ValueError(f"Lane is missing variant and has no explicit name: {lane}")
    if platform_id not in platform_display_names:
        raise ValueError(f"Unknown platform_id '{platform_id}' while deriving lane name")
    suffix = VARIANT_NAME_SUFFIX.get(variant)
    if not suffix:
        raise ValueError(f"Unsupported lane variant '{variant}' while deriving lane name")
    return f"{platform_display_names[platform_id]} - {suffix}"


def build_lane_registry(
    manifest_path: Path,
    platform_catalog_path: Path,
    runtime_model_path: Path | None = None,
) -> dict[str, LaneRecord]:
    repo_root = Path(__file__).resolve().parents[3]
    if runtime_model_path is None:
        runtime_model_path = repo_root / "ci/run/ref/runtime-model.json"
    family_descriptors = _load_family_descriptors(manifest_path, runtime_model_path)
    platform_display_names = _load_platform_display_names(platform_catalog_path)
    registry: dict[str, LaneRecord] = {}
    for family, descriptor in family_descriptors.items():
        lane_file_rel = descriptor["lane_file"]
        lane_file = repo_root / lane_file_rel
        raw_doc = yaml.safe_load(lane_file.read_text(encoding="utf-8")) or {}
        include = extract_lane_include(
            raw_doc,
            lane_file,
            require_include_key=isinstance(raw_doc, dict),
        )
        if not isinstance(include, list):
            raise ValueError(f"Lane include section must be a list: {lane_file}")
        defaults = _load_lane_defaults(raw_doc, lane_file, descriptor["shared_defaults"])
        resolved_include = []
        for include_index, raw_entry in enumerate(include):
            entry = require_mapping(raw_entry, f"Lane entry #{include_index} in {lane_file}")
            resolved_entry = _resolve_entry_defaults(entry, defaults, lane_file, include_index)
            expanded = expand_lane_variants(dict(resolved_entry), lane_file, include_index)
            resolved_include.append((include_index, expanded))

        for include_index, expanded_lanes in resolved_include:
            for lane in expanded_lanes:
                variant = str(lane.get("variant") or "").strip()
                platform_id = str(lane.get("platform_id") or "").strip()
                lane_name = _derive_lane_name(lane, platform_display_names)
                allow_failure = bool(lane.get("allow_failure") is True)

                record = LaneRecord(
                    name=lane_name,
                    family=family,
                    lane_file=lane_file_rel,
                    include_index=include_index,
                    variant=variant,
                    platform_id=platform_id,
                    allow_failure=allow_failure,
                )
                if lane_name in registry:
                    other = registry[lane_name]
                    raise ValueError(
                        "Duplicate lane name mapping detected: "
                        f"'{lane_name}' -> {other.lane_file}#{other.include_index} and "
                        f"{record.lane_file}#{record.include_index}"
                    )
                registry[lane_name] = record
    return registry
