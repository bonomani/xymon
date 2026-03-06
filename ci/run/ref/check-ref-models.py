#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

import yaml
from matrix_common import (
    die,
    load_lanes_from_file,
    load_purpose_manifest_common,
    require_mapping,
    require_non_empty_string,
    validate_dropdown_parity,
)
from runtime_model import load_runtime_model


def parse_args():
    parser = argparse.ArgumentParser(
        description="Validate ref model consistency (runtime model, family manifest, selector parity)"
    )
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--runtime-model", required=True)
    parser.add_argument("--selector-workflow", required=True)
    return parser.parse_args()


def expected_dropdown_families_union(manifest_path: Path, runtime_keys: set[str]) -> list[str]:
    generation_families = {
        entry["family"]
        for entry in load_purpose_manifest_common(
            manifest_path,
            purpose="generation",
            supported_runtimes=runtime_keys,
            include_lane_defaults=False,
        )["entries"]
    }
    validation_families = {
        entry["family"]
        for entry in load_purpose_manifest_common(
            manifest_path,
            purpose="validation",
            supported_runtimes=runtime_keys,
            include_lane_defaults=False,
        )["entries"]
    }
    enabled_union = generation_families | validation_families

    data = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    data = require_mapping(data, f"Manifest root in {manifest_path}")
    families = data.get("families", [])
    if not isinstance(families, list):
        die(f"Manifest has no families list: {manifest_path}")

    ordered = []
    seen = set()
    for index, raw in enumerate(families):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(
            entry.get("family"), f"Manifest entry #{index}.family"
        )
        if family in enabled_union and family not in seen:
            ordered.append(family)
            seen.add(family)
    return ordered


def validate_family_overlays(manifest_path: Path, runtime_keys: set[str]) -> None:
    data = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    data = require_mapping(data, f"Manifest root in {manifest_path}")
    families = data.get("families")
    if not isinstance(families, list) or not families:
        die(f"Manifest has no families list: {manifest_path}")

    seen = set()
    for index, raw in enumerate(families):
        entry = require_mapping(raw, f"Manifest entry #{index}")
        family = require_non_empty_string(
            entry.get("family"), f"Manifest entry #{index}.family"
        )
        if family in seen:
            die(f"Duplicate family in manifest: {family}")
        seen.add(family)

        common = require_mapping(entry.get("common", {}), f"Manifest entry {family}.common")
        runtime = require_non_empty_string(
            common.get("runtime"), f"Manifest entry {family}.common.runtime"
        )
        if runtime not in runtime_keys:
            die(f"Manifest entry {family}.common.runtime '{runtime}' is not in runtime model")
        require_non_empty_string(
            common.get("lane_file"), f"Manifest entry {family}.common.lane_file"
        )

        for purpose in ("generation", "validation"):
            if purpose not in entry:
                continue
            overlay_raw = entry.get(purpose)
            if overlay_raw in (None, True, False):
                continue
            overlay = require_mapping(overlay_raw, f"Manifest entry {family}.{purpose}")
            for forbidden in ("runtime", "lane_file"):
                if forbidden in overlay:
                    die(
                        f"Manifest entry {family}.{purpose} must not override "
                        f"'{forbidden}' (keep topology in common)"
                    )


def validate_lane_files(manifest_path: Path, runtime_keys: set[str], repo_root: Path) -> None:
    for purpose in ("generation", "validation"):
        manifest_data = load_purpose_manifest_common(
            manifest_path,
            purpose=purpose,
            supported_runtimes=runtime_keys,
            include_lane_defaults=True,
        )
        runtime_lane_defaults = manifest_data["lane_defaults"]
        for entry in manifest_data["entries"]:
            family = entry["family"]
            runtime = entry["runtime"]
            lane_file = repo_root / entry["lane_file"]
            lanes = load_lanes_from_file(
                lane_file,
                shared_defaults=runtime_lane_defaults.get(runtime, {}),
                strict_lane_mapping=True,
            )
            if not lanes:
                die(
                    f"Manifest entry {family}.{purpose} resolved lane file "
                    f"'{entry['lane_file']}' with no lanes"
                )


def main() -> None:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[3]
    manifest_path = repo_root / args.manifest
    runtime_model_path = repo_root / args.runtime_model
    selector_workflow_path = repo_root / args.selector_workflow

    runtime_model = load_runtime_model(runtime_model_path)
    runtime_keys = set(runtime_model["ordered_keys"])

    validate_family_overlays(manifest_path, runtime_keys)
    validate_lane_files(manifest_path, runtime_keys, repo_root)

    expected_options = ["all"] + expected_dropdown_families_union(
        manifest_path, runtime_keys
    )
    validate_dropdown_parity(selector_workflow_path, expected_options)


if __name__ == "__main__":
    main()
