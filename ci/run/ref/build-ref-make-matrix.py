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
from lane_utils import VARIANT_NAME_SUFFIX
from lane_utils import SUPPORTED_LANE_VARIANTS
from matrix_common import (
    derive_platform_display_name,
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
from platform_availability import (
    load_platform_availability,
    resolve_container_runtime,
)

SUPPORTED_BUILD_TOOLS = {"make", "cmake"}
SUPPORTED_COMPILERS = {"auto", "gcc", "clang"}
SUPPORTED_PROFILES = {"default", "debian", "gnuinstall", "packaging"}
SUPPORTED_INSTALL_MODES = {"auto", "source", "package"}
SUPPORTED_CONTAINER_RUNTIME_PREFERENCES = {"linux_host", "linux_container"}
SUPPORTED_ARCH_FILTERS = {
    "all",
    "amd64",
    "arm64",
    "arm32v7",
    "ppc64le",
    "riscv64",
    "s390x",
}
SUPPORTED_VARIANT_FILTERS = {"all", *SUPPORTED_LANE_VARIANTS}
SUPPORTED_COVERAGE_POLICY_FILTERS = {
    "minimal",
    "balanced",
    "broad",
    "full",
}
SUPPORTED_SYMBOLIC_ALIAS_POLICY_FILTERS = {"exclude", "include"}
SUPPORTED_MOVING_TARGET_POLICY_FILTERS = {"exclude", "ordered_only", "include"}


def parse_string_list(value, context: str, *, supported_values=None):
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
        item = require_non_empty_string(raw, f"{context} entry #{index}")
        if supported_values is not None and item not in supported_values:
            die(f"{context} entry #{index} has unsupported value '{item}'")
        normalized.append(item)
    return normalized


def load_container_runtime_preferences(path: Path):
    if not path.exists():
        die(f"Missing platform intent: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    data = require_mapping(data, f"Platform intent root in {path}")
    containers = require_mapping(data.get("containers"), f"Platform intent containers in {path}")
    runtime_preference = require_mapping(
        containers.get("runtime_preference"),
        f"Platform intent containers.runtime_preference in {path}",
    )
    default = parse_string_list(
        runtime_preference.get("default"),
        "Platform intent containers.runtime_preference.default",
        supported_values=SUPPORTED_CONTAINER_RUNTIME_PREFERENCES,
    )
    if not default:
        die("Platform intent containers.runtime_preference.default must be set")
    overrides_raw = runtime_preference.get("overrides") or {}
    overrides_raw = require_mapping(
        overrides_raw,
        f"Platform intent containers.runtime_preference.overrides in {path}",
    )
    overrides = {}
    for platform_os, values in overrides_raw.items():
        key = require_non_empty_string(platform_os, "Platform intent runtime override key")
        parsed = parse_string_list(
            values,
            f"Platform intent runtime override for {key}",
            supported_values=SUPPORTED_CONTAINER_RUNTIME_PREFERENCES,
        )
        if not parsed:
            die(f"Platform intent runtime override for {key} must be non-empty")
        overrides[key.lower()] = parsed
    return default, overrides


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
            }
        )

    return families


def derive_manifest_purpose(goal: str) -> str:
    if goal == "compare":
        return "validation"
    return "generation"


def load_platform_releases(path: Path):
    if not path.exists():
        die(f"Missing platform releases: {path}")

    data = yaml.safe_load(path.read_text()) or {}
    platforms = data.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        die(f"Platform releases has no platforms mapping: {path}")

    normalized = {}
    for platform_id, entry in platforms.items():
        platform_id = require_non_empty_string(platform_id, "Platform releases platform id")
        normalized_entry = require_mapping(
            entry, f"Platform release entry '{platform_id}'"
        )
        runtime = require_non_empty_string(
            normalized_entry.get("runtime"), f"Platform '{platform_id}'.runtime"
        ).lower()
        if runtime not in {"docker", "vm", "host"}:
            die(f"Platform '{platform_id}' has unsupported runtime '{runtime}'")
        image = str(normalized_entry.get("image") or "").strip()
        runner = str(normalized_entry.get("runner") or "").strip()
        provider = str(normalized_entry.get("provider") or "").strip()
        if runtime == "docker":
            if not image:
                die(f"Platform '{platform_id}' (runtime=docker) must include image")
            if runner:
                die(f"Platform '{platform_id}' (runtime=docker) must not include runner")
        elif runtime == "vm":
            if image or runner:
                die(f"Platform '{platform_id}' (runtime=vm) must not include image/runner")
        else:
            if not runner:
                die(f"Platform '{platform_id}' (runtime=host) must include runner")
            if image:
                die(f"Platform '{platform_id}' (runtime=host) must not include image")
        normalized[platform_id] = normalized_entry

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
            version = deps.get("key")
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

    display_name = derive_platform_display_name(platform_id, platform_entry)
    variant = lane_obj.get("variant")
    suffix = VARIANT_NAME_SUFFIX.get(variant)
    if not suffix:
        die(
            f"Lane for family '{family_entry['family']}' has unsupported "
            f"variant '{variant}' for auto naming"
        )
    artifact_arch = infer_artifact_arch(lane_obj)
    arch_suffix = "" if artifact_arch == "amd64" else f" {artifact_arch}"
    lane_obj["name"] = f"{display_name}{arch_suffix} - {suffix}"


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


def apply_platform_availability_overrides(
    family_entry,
    lane_obj,
    platform_id,
    platform_entry,
    platform_availability,
):
    if platform_id is None or platform_entry is None:
        return None

    deps = platform_entry.get("deps")
    if not isinstance(deps, dict):
        return None

    platform_os = str(platform_entry.get("platform_os") or "").strip()
    if not platform_os:
        platform_os = infer_platform_os(family_entry["family"], platform_id)
    artifact_arch = infer_artifact_arch(lane_obj)
    try:
        resolved = resolve_container_runtime(
            platform_id=platform_id,
            platform_os=platform_os,
            artifact_arch=artifact_arch,
            platform_availability=platform_availability,
        )
    except ValueError as exc:
        die(f"{lane_context_label(family_entry, lane_obj)}: {exc}")

    if resolved is None:
        return None
    if not resolved.get("supported", True):
        return resolved

    lane_obj["container"] = resolved["image"]
    return resolved


def resolve_preferred_runtime(
    family_entry,
    lane_obj,
    discovered_platform=None,
    intent_runtime_preferences=None,
):
    runtime = family_entry["runtime"]
    preference_list = list(
        intent_runtime_preferences or family_entry.get("runtime_preference", [family_entry["runtime"]])
    )

    if discovered_platform is not None:
        if not discovered_platform.get("supported", True):
            return None, None
        host_runners = list(discovered_platform.get("direct_host_runners", []))
        if "linux_host" in preference_list and host_runners:
            runtime = "linux_host"
            lane_obj["runs_on"] = host_runners[0]
        elif "linux_container" in preference_list and discovered_platform.get("supports_container"):
            runtime = "linux_container"
        else:
            return None, None
        lane_obj["runtime"] = runtime
        lane_obj["runtime_preference"] = ",".join(preference_list)
        return runtime, (host_runners[0] if host_runners else None)

    lane_obj["runtime"] = runtime
    lane_obj["runtime_preference"] = ",".join(preference_list)
    return runtime, None


def normalize_lane(
    family_entry,
    lane,
    platform_catalog,
    platform_availability,
    build_tool,
    requested_compiler,
    profile,
    install_mode,
    container_runtime_preferences,
    selected_symbolic_alias_policy,
    selected_moving_target_policy,
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
    if platform_entry is not None:
        if (
            selected_symbolic_alias_policy == "exclude"
            and platform_entry.get("alias_of") not in (None, "")
        ):
            return None
        moving_text = " ".join(
            str(value)
            for value in (
                platform_id or "",
                platform_entry.get("platform_version", ""),
                platform_entry.get("image", ""),
            )
        ).lower()
        is_moving_target = any(
            keyword in moving_text for keyword in ("edge", "tumbleweed", "rolling")
        ) or (
            "latest" in moving_text and platform_entry.get("alias_of") in (None, "")
        )
        if selected_moving_target_policy == "exclude" and is_moving_target:
            return None
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

    discovered_platform = apply_platform_availability_overrides(
        family_entry,
        lane_obj,
        platform_id,
        platform_entry,
        platform_availability,
    )
    if discovered_platform is not None and not discovered_platform.get("supported", True):
        return None
    intent_runtime_preference = None
    if platform_entry is not None and str(platform_entry.get("runtime", "")).lower() == "docker":
        platform_os_key = str(platform_entry.get("platform_os") or "").strip().lower()
        if not platform_os_key and platform_id:
            platform_os_key = infer_platform_os(family_entry["family"], platform_id).lower()
        if platform_os_key:
            default_preference, overrides = container_runtime_preferences
            intent_runtime_preference = list(
                overrides.get(platform_os_key, default_preference)
            )
    effective_runtime, _ = resolve_preferred_runtime(
        family_entry,
        lane_obj,
        discovered_platform=discovered_platform,
        intent_runtime_preferences=intent_runtime_preference,
    )
    if effective_runtime is None:
        return None
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
        "--selected-variant",
        default="all",
        choices=sorted(SUPPORTED_VARIANT_FILTERS),
    )
    parser.add_argument(
        "--selected-arch",
        default="all",
        choices=sorted(SUPPORTED_ARCH_FILTERS),
    )
    parser.add_argument(
        "--selected-coverage-policy",
        default="balanced",
        choices=sorted(SUPPORTED_COVERAGE_POLICY_FILTERS),
    )
    parser.add_argument(
        "--selected-symbolic-alias-policy",
        default="exclude",
        choices=sorted(SUPPORTED_SYMBOLIC_ALIAS_POLICY_FILTERS),
    )
    parser.add_argument(
        "--selected-moving-target-policy",
        default="ordered_only",
        choices=sorted(SUPPORTED_MOVING_TARGET_POLICY_FILTERS),
    )
    parser.add_argument(
        "--goal",
        required=True,
        choices=("verify", "ref", "compare"),
        help="Execution goal selection",
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
        "--platform-releases",
        default=".github/data/platform-releases-discovered.yml",
    )
    parser.add_argument(
        "--runtime-model",
        default="ci/run/ref/runtime-model.json",
    )
    parser.add_argument(
        "--platform-availability",
        default=".github/data/platform-availability.yml",
    )
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    parser.add_argument(
        "--platform-intent",
        default="ci/deps/platform-intent.yaml",
    )
    return parser.parse_args()


def load_family_lanes(repo_root: Path, family_entry, *, selected_coverage_policy: str):
    return load_lanes_from_file(
        repo_root / family_entry["lane_file"],
        shared_defaults=family_entry.get("lane_defaults", {}),
        strict_lane_mapping=True,
        generated_overrides={"coverage_policy": selected_coverage_policy},
    )


def main():
    args = parse_args()
    purpose = derive_manifest_purpose(args.goal)
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
    families = load_manifest(repo_root / args.manifest, purpose, runtime_to_platform_runtime)
    for family_entry in families:
        family_entry["runtime_to_platform_runtime"] = runtime_to_platform_runtime
        family_entry["runtime_to_execution"] = runtime_to_execution
        family_entry["runtime_to_default_ref_os"] = runtime_to_default_ref_os
        family_entry["runtime_to_requires_runs_on"] = runtime_to_requires_runs_on

    platform_catalog = load_platform_releases(repo_root / args.platform_releases)
    container_runtime_preferences = load_container_runtime_preferences(
        repo_root / args.platform_intent
    )
    lookup = {entry["family"]: entry for entry in families}
    selected_family = args.selected_family
    selected_variant = args.selected_variant
    selected_arch = args.selected_arch
    selected_coverage_policy = args.selected_coverage_policy
    selected_symbolic_alias_policy = args.selected_symbolic_alias_policy
    selected_moving_target_policy = args.selected_moving_target_policy
    if selected_family == "all":
        selected_entries = families
    else:
        if selected_family not in lookup:
            die(f"Unsupported family input: {selected_family}")
        selected_entries = [lookup[selected_family]]

    platform_availability_path = repo_root / args.platform_availability
    try:
        platform_availability = load_platform_availability(platform_availability_path)
    except ValueError as exc:
        die(str(exc))

    matrices = {runtime: [] for runtime in runtime_order}
    selected_families = []
    for family_entry in selected_entries:
        selected_families.append(family_entry["family"])
        lanes = load_family_lanes(
            repo_root,
            family_entry,
            selected_coverage_policy=selected_coverage_policy,
        )
        for lane in lanes:
            if not isinstance(lane, dict):
                continue
            normalized = normalize_lane(
                family_entry,
                lane,
                platform_catalog,
                platform_availability,
                build_tool,
                compiler,
                profile,
                install_mode,
                container_runtime_preferences,
                selected_symbolic_alias_policy,
                selected_moving_target_policy,
            )
            if normalized is None:
                continue
            if selected_variant != "all" and normalized.get("variant") != selected_variant:
                continue
            if selected_arch != "all" and normalized.get("artifact_arch") != selected_arch:
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
