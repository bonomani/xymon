#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path

import yaml
from execution_model import (
    resolve_install_mode,
    validate_requested_install_mode,
)
from github_host_runners import (
    build_generated_host_lanes,
    build_host_runner_index,
    load_github_host_runners,
    resolve_linux_host_runner,
)
from lane_utils import VARIANT_NAME_SUFFIX
from matrix_common import (
    die,
    infer_artifact_arch,
    infer_platform_os,
    load_lanes_from_file,
    load_purpose_manifest_common,
    parse_supported_build_tools,
    require_mapping,
    require_non_empty_string,
)
from runtime_model import load_runtime_model

SUPPORTED_BUILD_TOOLS = {"make", "cmake"}
SUPPORTED_COMPILERS = {"auto", "gcc", "clang"}
SUPPORTED_PROFILES = {"default", "debian", "gnuinstall", "packaging"}
SUPPORTED_INSTALL_MODES = {"auto", "source", "package"}


def parse_runtime_preference(entry, runtime, supported_runtime_keys, family):
    raw = entry.get("runtime_preference")
    if raw is None:
        return [runtime]
    if not isinstance(raw, list) or not raw:
        die(
            f"Manifest entry {family}.runtime_preference must be a non-empty list"
        )
    normalized = []
    for index, raw_key in enumerate(raw):
        key = require_non_empty_string(
            raw_key,
            f"Manifest entry {family}.runtime_preference[{index}]",
        )
        if key not in supported_runtime_keys:
            die(
                f"Manifest entry {family}.runtime_preference[{index}] "
                f"references unknown runtime '{key}'"
            )
        normalized.append(key)
    if normalized[0] != runtime:
        die(
            f"Manifest entry {family}.runtime_preference must start with "
            f"the primary runtime '{runtime}'"
        )
    return normalized


def load_manifest(path: Path, purpose: str, runtime_to_platform_runtime):
    supported_runtime_keys = set(runtime_to_platform_runtime)
    manifest_data = load_purpose_manifest_common(
        path,
        purpose=purpose,
        supported_runtimes=runtime_to_platform_runtime,
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

        lane_source = entry.get("lane_source")
        if lane_source is not None:
            lane_source = require_non_empty_string(
                lane_source, f"Manifest entry {family}.lane_source"
            )

        host_catalog_machine_family = entry.get("host_catalog_machine_family")
        if host_catalog_machine_family is not None:
            host_catalog_machine_family = require_non_empty_string(
                host_catalog_machine_family,
                f"Manifest entry {family}.host_catalog_machine_family",
            ).lower()

        runtime_preference = parse_runtime_preference(
            entry, runtime, supported_runtime_keys, family
        )

        families.append(
            {
                "family": family,
                "runtime": runtime,
                "runtime_preference": runtime_preference,
                "lane_file": lane_file,
                "runtime_overrides": dict(runtime_defaults.get(runtime, {})),
                "lane_defaults": dict(lane_defaults.get(runtime, {})),
                "lane_overrides": lane_overrides,
                "container_arm64_overrides": container_arm64_overrides,
                "os_version_key": os_version_key,
                "default_architecture": default_architecture,
                "lane_source": lane_source,
                "host_catalog_machine_family": host_catalog_machine_family,
            }
        )

    return families


def derive_manifest_purpose(ref_mode: str) -> str:
    if ref_mode == "compare":
        return "validation"
    return "generation"


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


def lane_context_label(family_entry, lane_obj) -> str:
    return (
        f"Lane '{lane_obj.get('name', '<unnamed>')}' for family "
        f"'{family_entry['family']}'"
    )


def resolve_supported_build_tools(family_entry, lane_obj, platform_entry, platform_id):
    supported_build_tools = parse_supported_build_tools(
        lane_obj.pop("supported_build_tools", None),
        f"{lane_context_label(family_entry, lane_obj)} supported_build_tools",
        supported_values=SUPPORTED_BUILD_TOOLS,
    )
    if supported_build_tools is None and platform_entry is not None:
        supported_build_tools = parse_supported_build_tools(
            platform_entry.get("supported_build_tools"),
            f"Platform '{platform_id}'.supported_build_tools",
            supported_values=SUPPORTED_BUILD_TOOLS,
        )
    return supported_build_tools


def resolve_platform_binding(family_entry, lane_obj, platform_catalog):
    platform_id = lane_obj.get("platform_id")
    if platform_id is None:
        return None, None, ""

    platform_id = require_non_empty_string(
        platform_id,
        f"{lane_context_label(family_entry, lane_obj)} platform_id",
    )
    platform_entry = platform_catalog.get(platform_id)
    if platform_entry is None:
        if lane_obj.get("platform_catalog_optional") is True:
            return platform_id, None, ""
        die(
            f"{lane_context_label(family_entry, lane_obj)} references unknown "
            f"platform_id '{platform_id}'"
        )

    platform_runtime = require_non_empty_string(
        platform_entry.get("runtime"),
        f"Platform '{platform_id}'.runtime",
    ).lower()
    expected_runtime = family_entry["runtime_to_platform_runtime"][family_entry["runtime"]]
    if platform_runtime != expected_runtime:
        die(
            f"{lane_context_label(family_entry, lane_obj)} expects runtime "
            f"'{expected_runtime}' but platform '{platform_id}' is '{platform_runtime}'"
        )

    return platform_id, platform_entry, platform_runtime


def apply_platform_runtime_defaults(
    family_entry,
    lane_obj,
    platform_entry,
    platform_id,
    platform_runtime,
):
    if platform_entry is None:
        return

    if platform_runtime == "docker":
        lane_obj["container"] = require_non_empty_string(
            platform_entry.get("image"), f"Platform '{platform_id}'.image"
        )
    elif platform_runtime == "host":
        lane_obj.setdefault(
            "runs_on",
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


def auto_name_lane(family_entry, lane_obj, platform_entry, platform_id):
    if lane_obj.get("name") not in (None, ""):
        return
    if platform_entry is None:
        die(
            f"Lane for family '{family_entry['family']}' is missing name "
            "and cannot be auto-named without platform_id"
        )

    display_name = require_non_empty_string(
        platform_entry.get("display_name"),
        f"Platform '{platform_id}'.display_name",
    )
    variant = lane_obj.get("variant")
    suffix = VARIANT_NAME_SUFFIX.get(variant)
    if not suffix:
        die(
            f"Lane for family '{family_entry['family']}' has unsupported "
            f"variant '{variant}' for auto naming"
        )
    lane_obj["name"] = f"{display_name} - {suffix}"


def apply_container_arm64_overrides(family_entry, lane_obj, runtime_execution):
    arm64_overrides = family_entry["container_arm64_overrides"]
    if not arm64_overrides or runtime_execution != "container":
        return
    container_options = str(lane_obj.get("container_options", "")).lower()
    if "linux/arm64" in container_options:
        lane_obj.update(arm64_overrides)


def finalize_lane_defaults(family_entry, lane_obj):
    os_version_key = family_entry["os_version_key"]
    if os_version_key:
        lane_obj["os_version"] = lane_obj.get(os_version_key)
        if lane_obj["os_version"] in (None, ""):
            die(
                f"{lane_context_label(family_entry, lane_obj)} is missing "
                f"'{os_version_key}'"
            )

    default_architecture = family_entry["default_architecture"]
    if default_architecture:
        lane_obj.setdefault("architecture", default_architecture)

    # Keep runs_on as the canonical runner selector key.
    lane_obj.pop("runner", None)

    lane_obj.setdefault(
        "platform_os",
        infer_platform_os(family_entry["family"], lane_obj.get("platform_id")),
    )


def validate_lane_requirements(
    family_entry,
    lane_obj,
    runtime_execution,
    runtime_requires_runs_on,
):
    required = ("name", "variant", "runtime", "build_tool", "ref_os", "platform_os")
    for key in required:
        if lane_obj.get(key) in (None, ""):
            die(f"{lane_context_label(family_entry, lane_obj)} is missing '{key}'")

    if runtime_requires_runs_on and lane_obj.get("runs_on") in (None, ""):
        die(f"{lane_context_label(family_entry, lane_obj)} is missing 'runs_on'")
    if runtime_execution == "container" and lane_obj.get("container") in (None, ""):
        die(f"{lane_context_label(family_entry, lane_obj)} is missing 'container'")
    if runtime_execution == "host" and lane_obj.get("runs_on") in (None, ""):
        die(f"{lane_context_label(family_entry, lane_obj)} is missing 'runs_on'")


def resolve_preferred_runtime(
    family_entry,
    lane_obj,
    platform_id,
    platform_entry,
    host_runner_index,
):
    runtime = family_entry["runtime"]
    preference_list = list(
        family_entry.get("runtime_preference", [family_entry["runtime"]])
    )
    host_runner = None

    if platform_id and platform_entry is not None and host_runner_index:
        candidate_arch = infer_artifact_arch(lane_obj)
        host_runner = resolve_linux_host_runner(
            platform_id=platform_id,
            platform_entry=platform_entry,
            artifact_arch=candidate_arch,
            host_runner_index=host_runner_index,
        )
        if host_runner is not None:
            runtime = "linux_host"
            preference_list = ["linux_host", "linux_container"]
            lane_obj["runs_on"] = host_runner["label"]

    lane_obj["runtime"] = runtime
    lane_obj["runtime_preference"] = ",".join(preference_list)
    return runtime, host_runner


def normalize_lane(
    family_entry,
    lane,
    platform_catalog,
    host_runner_index,
    build_tool,
    requested_compiler,
    profile,
    install_mode,
):
    lane_obj = dict(family_entry["runtime_overrides"])
    lane_obj.update(lane)
    lane_obj.update(family_entry["lane_overrides"])
    lane_obj["build_tool"] = build_tool
    # Resolve compiler per lane so auto can follow runtime defaults.
    # BSD/macOS lanes default to clang; Linux lanes default to gcc.
    compiler = requested_compiler
    if compiler == "auto":
        runtime_key = family_entry["runtime"]
        if runtime_key in {"bsd_vm", "macos_host"}:
            compiler = "clang"
        else:
            compiler = "gcc"
    lane_obj["compiler"] = compiler
    lane_obj["profile"] = profile
    lane_obj["install_mode"] = install_mode
    runtime_default_ref_os = family_entry["runtime_to_default_ref_os"][
        family_entry["runtime"]
    ]

    if lane_obj.get("ref_os") in (None, ""):
        if runtime_default_ref_os == "family":
            lane_obj["ref_os"] = family_entry["family"]
        else:
            lane_obj["ref_os"] = runtime_default_ref_os

    lane_obj.setdefault("artifact_family", lane_obj["ref_os"])
    lane_obj.setdefault("baseline_root", f"make_{lane_obj['ref_os']}")
    platform_id, platform_entry, platform_runtime = resolve_platform_binding(
        family_entry, lane_obj, platform_catalog
    )
    supported_build_tools = resolve_supported_build_tools(
        family_entry, lane_obj, platform_entry, platform_id
    )
    apply_platform_runtime_defaults(
        family_entry,
        lane_obj,
        platform_entry,
        platform_id,
        platform_runtime,
    )
    auto_name_lane(family_entry, lane_obj, platform_entry, platform_id)

    if supported_build_tools is not None and build_tool not in supported_build_tools:
        return None

    effective_runtime, _ = resolve_preferred_runtime(
        family_entry,
        lane_obj,
        platform_id,
        platform_entry,
        host_runner_index,
    )
    runtime_execution = family_entry["runtime_to_execution"][effective_runtime]
    runtime_default_ref_os = family_entry["runtime_to_default_ref_os"][effective_runtime]
    runtime_requires_runs_on = family_entry["runtime_to_requires_runs_on"][effective_runtime]

    apply_container_arm64_overrides(family_entry, lane_obj, runtime_execution)
    finalize_lane_defaults(family_entry, lane_obj)
    validate_lane_requirements(
        family_entry,
        lane_obj,
        runtime_execution,
        runtime_requires_runs_on,
    )

    lane_obj["artifact_arch"] = infer_artifact_arch(lane_obj)

    return lane_obj


def parse_args():
    parser = argparse.ArgumentParser(
        description="Build matrix outputs for ref selector workflows"
    )
    parser.add_argument("--selected-family", required=True)
    parser.add_argument(
        "--ref-mode",
        required=True,
        choices=("off", "generate", "compare"),
        help="Reference handling mode selection",
    )
    parser.add_argument(
        "--build-tool",
        required=True,
        choices=sorted(SUPPORTED_BUILD_TOOLS),
        help="Build tool selection (make or cmake)",
    )
    parser.add_argument(
        "--compiler",
        required=True,
        choices=sorted(SUPPORTED_COMPILERS),
        help="Compiler selection (auto, gcc, or clang)",
    )
    parser.add_argument(
        "--profile",
        required=True,
        choices=sorted(SUPPORTED_PROFILES),
        help="Layout/profile selection",
    )
    parser.add_argument(
        "--install-mode",
        required=True,
        choices=sorted(SUPPORTED_INSTALL_MODES),
        help="Install semantics selection",
    )
    parser.add_argument("--manifest", default="ci/run/ref/ref-families.yml")
    parser.add_argument(
        "--platform-catalog",
        default="ci/deps/platform-catalog.yaml",
    )
    parser.add_argument(
        "--runtime-model",
        default="ci/run/ref/runtime-model.json",
    )
    parser.add_argument(
        "--github-host-runners",
        default=".github/data/github-host-runners.yml",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    return parser.parse_args()


def load_family_lanes(repo_root: Path, family_entry, host_runners):
    lane_source = family_entry.get("lane_source")
    if lane_source is None:
        return load_lanes_from_file(
            repo_root / family_entry["lane_file"],
            shared_defaults=family_entry.get("lane_defaults", {}),
            strict_lane_mapping=True,
        )
    if lane_source == "github_host_catalog":
        machine_family = family_entry.get("host_catalog_machine_family")
        if machine_family is None:
            die(
                f"Family '{family_entry['family']}' requires host_catalog_machine_family "
                "when lane_source=github_host_catalog"
            )
        return build_generated_host_lanes(
            host_runners,
            machine_family=machine_family,
        )
    die(
        f"Unsupported lane source '{lane_source}' for family "
        f"'{family_entry['family']}'"
    )


def main():
    args = parse_args()
    purpose = derive_manifest_purpose(args.ref_mode)
    github_output = args.github_output
    if not github_output:
        die("GITHUB_OUTPUT is not set and --github-output was not provided")
    build_tool = args.build_tool
    if build_tool not in SUPPORTED_BUILD_TOOLS:
        die(f"Unsupported build tool: {build_tool}")
    compiler = args.compiler
    if compiler not in SUPPORTED_COMPILERS:
        die(f"Unsupported compiler: {compiler}")
    profile = args.profile
    if profile not in SUPPORTED_PROFILES:
        die(f"Unsupported profile: {profile}")
    if build_tool == "make" and profile == "gnuinstall":
        die("profile=gnuinstall requires build_tool=cmake")
    if build_tool == "cmake" and profile == "debian":
        die("profile=debian requires build_tool=make")
    requested_install_mode = args.install_mode
    validate_requested_install_mode(requested_install_mode)
    install_mode = resolve_install_mode(requested_install_mode, build_tool, profile)

    repo_root = Path(__file__).resolve().parents[3]
    runtime_model = load_runtime_model(repo_root / args.runtime_model)
    runtime_to_platform_runtime = runtime_model["platform_runtime_by_key"]
    runtime_to_execution = runtime_model["execution_by_key"]
    runtime_to_default_ref_os = runtime_model["default_ref_os_by_key"]
    runtime_to_requires_runs_on = runtime_model["requires_runs_on_by_key"]
    runtime_order = runtime_model["ordered_keys"]
    host_runners = load_github_host_runners(repo_root / args.github_host_runners)
    host_runner_index = build_host_runner_index(host_runners)

    families = load_manifest(repo_root / args.manifest, purpose, runtime_to_platform_runtime)
    for family_entry in families:
        family_entry["runtime_to_platform_runtime"] = runtime_to_platform_runtime
        family_entry["runtime_to_execution"] = runtime_to_execution
        family_entry["runtime_to_default_ref_os"] = runtime_to_default_ref_os
        family_entry["runtime_to_requires_runs_on"] = runtime_to_requires_runs_on

    platform_catalog = load_platform_catalog(repo_root / args.platform_catalog)
    lookup = {entry["family"]: entry for entry in families}
    selected_family = args.selected_family
    if selected_family == "all":
        selected_entries = families
    else:
        if selected_family not in lookup:
            die(f"Unsupported family input: {selected_family}")
        selected_entries = [lookup[selected_family]]

    matrices = {runtime: [] for runtime in runtime_order}
    selected_families = []
    for family_entry in selected_entries:
        selected_families.append(family_entry["family"])
        lanes = load_family_lanes(repo_root, family_entry, host_runners)
        for lane in lanes:
            if not isinstance(lane, dict):
                continue
            normalized = normalize_lane(
                family_entry,
                lane,
                platform_catalog,
                host_runner_index,
                build_tool,
                compiler,
                profile,
                install_mode,
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
        "include": [entry for runtime in runtime_order for entry in matrices[runtime]]
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
