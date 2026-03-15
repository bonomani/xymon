#!/usr/bin/env python3
"""Sanity-check packaging deps YAML structure and content."""
from __future__ import annotations

import copy
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except Exception as exc:  # pragma: no cover
    print(f"Failed to import PyYAML: {exc}")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "ci" / "deps" / "data"
FILES = [
    DATA_DIR / "deps-client.yaml",
    DATA_DIR / "deps-localclient.yaml",
    DATA_DIR / "deps-server.yaml",
]
MAP_FILE = DATA_DIR / "deps-map.yaml"
DEFAULT_TOPOLOGY_FILE = DATA_DIR / "deps-targets.yaml"
MAP_RESOLVER_AWK = ROOT / "ci" / "deps" / "lib" / "resolve-map.awk"
PLATFORM_NORMALIZATION_FILE = ROOT / "ci" / "deps" / "platform-normalization.yaml"
PLATFORM_CATALOG_FILE = ROOT / "ci" / "deps" / "platform-catalog.yaml"
PLATFORM_RELEASES_FILE = ROOT / "ci" / "deps" / "platform-releases.yaml"
REF_FAMILIES_MANIFEST = ROOT / "ci" / "run" / "ref" / "ref-families.yml"
REF_LANE_UTILS_DIR = ROOT / "ci" / "run" / "ref"
CHECKDEPS_DIR = ROOT / "ci" / "deps" / "checkdeps"

if str(REF_LANE_UTILS_DIR) not in sys.path:
    sys.path.insert(0, str(REF_LANE_UTILS_DIR))
if str(CHECKDEPS_DIR) not in sys.path:
    sys.path.insert(0, str(CHECKDEPS_DIR))
try:
    from lane_utils import (  # type: ignore
        LaneSpecError,
        SUPPORTED_LANE_VARIANTS,
        expand_lane_variants,
        extract_lane_include,
    )
    from matrix_common import load_purpose_manifest_common  # type: ignore
except Exception as exc:  # pragma: no cover
    print(f"Failed to import lane_utils helpers: {exc}")
    sys.exit(2)

try:
    from workflow_io import find_package_steps, parse_workflow_yaml  # type: ignore
    from platform_normalization import (  # type: ignore
        candidate_os_keys_for_rule,
        compose_os_key,
    )
    from platform_catalog import (  # type: ignore
        build_docker_image_index,
        load_platform_catalog,
        load_platform_deps_bindings,
        load_platform_releases,
    )
    from shell_lint import check_shell_scripts  # type: ignore
except Exception as exc:  # pragma: no cover
    print(f"Failed to import checkdeps helpers: {exc}")
    sys.exit(2)


def load_yaml(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text())
    except Exception as exc:  # pragma: no cover
        print(f"Invalid YAML: {path}: {exc}")
        sys.exit(2)
    if not isinstance(data, dict):
        print(f"Unexpected YAML structure (root is not a mapping): {path}")
        sys.exit(2)
    return data


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"ERROR: {msg}")
        sys.exit(1)


def normalize_string_list(value, label: str) -> list[str]:
    require(isinstance(value, list), f"{label} must be a list")
    normalized: list[str] = []
    for entry in value:
        require(isinstance(entry, str), f"{label} entries must be strings")
        item = entry.strip()
        require(bool(item), f"{label} entries must be non-empty strings")
        normalized.append(item)
    return normalized


def load_topology(topology_file: Path) -> dict:
    require(topology_file.exists(), f"missing topology file: {topology_file}")
    data = load_yaml(topology_file)
    require("build" not in data, f"{topology_file} uses deprecated 'build' key; strict v2 requires 'targets'")
    require("bindings" not in data, f"{topology_file} uses deprecated 'bindings' key; strict v2 requires 'targets'")
    targets = data.get("targets")
    require(isinstance(targets, dict), f"{topology_file} targets must be a mapping")
    for family, family_entry in targets.items():
        require(
            isinstance(family_entry, dict),
            f"{topology_file} targets.{family} must be a mapping",
        )
        for os_name, os_entry in family_entry.items():
            require(
                isinstance(os_entry, dict),
                f"{topology_file} targets.{family}.{os_name} must be a mapping",
            )
            profile_name = os_entry.get("profile")
            require(
                isinstance(profile_name, str) and profile_name.strip(),
                f"{topology_file} targets.{family}.{os_name}.profile must be a non-empty string",
            )
            packagers = os_entry.get("packagers")
            require(
                isinstance(packagers, dict) and bool(packagers),
                f"{topology_file} targets.{family}.{os_name}.packagers must be a non-empty mapping",
            )
            for pkg_name, pkg_entry in packagers.items():
                if pkg_entry is None:
                    continue
                require(
                    isinstance(pkg_entry, dict),
                    (
                        f"{topology_file} targets.{family}.{os_name}.packagers."
                        f"{pkg_name} must be a mapping"
                    ),
                )
    data["build"] = copy.deepcopy(targets)
    return data


def load_shared_version_notes(version_notes_file: Path) -> dict:
    require(version_notes_file.exists(), f"missing version notes file: {version_notes_file}")
    data = load_yaml(version_notes_file)
    notes = data.get("version_notes")
    require(isinstance(notes, dict), f"{version_notes_file} version_notes must be a mapping")
    return notes


def deep_merge_dict(base: dict, overlay: dict) -> dict:
    merged = copy.deepcopy(base)
    for key, value in overlay.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = deep_merge_dict(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def apply_mandatory_delta(
    base_items: list[str],
    delta: dict,
    label: str,
) -> list[str]:
    require(isinstance(delta, dict), f"{label} must be a mapping with add/remove lists")
    unknown = sorted(set(delta.keys()) - {"add", "remove"})
    require(not unknown, f"{label} contains unsupported keys: {', '.join(unknown)}")
    add_items = normalize_string_list(delta.get("add", []), f"{label}.add")
    remove_items = set(normalize_string_list(delta.get("remove", []), f"{label}.remove"))

    merged = [item for item in base_items if item not in remove_items]
    for item in add_items:
        if item not in merged:
            merged.append(item)
    return merged


def merge_profiles_with_overlay_delta(
    base_profiles: dict,
    overlay_profiles: dict,
    label: str,
) -> dict[str, dict]:
    require(isinstance(base_profiles, dict), f"{label} base profiles must be a mapping")
    require(isinstance(overlay_profiles, dict), f"{label} overlay profiles must be a mapping")

    merged_profiles: dict[str, dict] = {}
    for profile_name, base_entry in base_profiles.items():
        require(
            isinstance(profile_name, str) and profile_name.strip(),
            f"{label} base profile names must be non-empty strings",
        )
        require(isinstance(base_entry, dict), f"{label} base profile '{profile_name}' must be a mapping")
        merged_profiles[profile_name] = copy.deepcopy(base_entry)

    for profile_name, overlay_entry in overlay_profiles.items():
        require(
            isinstance(profile_name, str) and profile_name.strip(),
            f"{label} overlay profile names must be non-empty strings",
        )
        require(isinstance(overlay_entry, dict), f"{label} overlay profile '{profile_name}' must be a mapping")
        require(
            profile_name in merged_profiles,
            f"{label} overlay profile '{profile_name}' is missing from base profiles",
        )

        base_entry = merged_profiles[profile_name]
        merged_entry = deep_merge_dict(base_entry, overlay_entry)

        base_libs = base_entry.get("libs")
        overlay_libs = overlay_entry.get("libs")
        if overlay_libs is not None:
            require(
                isinstance(overlay_libs, dict),
                f"{label} overlay profile '{profile_name}'.libs must be a mapping",
            )
        if isinstance(overlay_libs, dict) and "mandatory" in overlay_libs:
            require(
                isinstance(base_libs, dict) and "mandatory" in base_libs,
                f"{label} base profile '{profile_name}' must define libs.mandatory for overlay delta",
            )
            base_mandatory = normalize_string_list(
                base_libs["mandatory"],
                f"{label} base profile '{profile_name}'.libs.mandatory",
            )
            merged_mandatory = apply_mandatory_delta(
                base_mandatory,
                overlay_libs["mandatory"],
                f"{label} overlay profile '{profile_name}'.libs.mandatory",
            )
            merged_entry.setdefault("libs", {})
            merged_entry["libs"]["mandatory"] = merged_mandatory

        merged_profiles[profile_name] = merged_entry

    return merged_profiles


def load_platform_normalization_rules() -> dict[str, dict]:
    if not PLATFORM_NORMALIZATION_FILE.exists():
        return {}
    data = load_yaml(PLATFORM_NORMALIZATION_FILE)
    normalization = data.get("normalization", {})
    if not isinstance(normalization, dict):
        return {}
    os_ids = normalization.get("os_ids", {})
    if not isinstance(os_ids, dict):
        return {}
    rules: dict[str, dict] = {}
    for os_id, entry in os_ids.items():
        if isinstance(os_id, str) and isinstance(entry, dict):
            rules[os_id] = entry
    return rules


def expand_variant_profiles(
    data: dict,
    path: Path,
    topology: dict,
    topology_file: Path,
    shared_version_notes: dict,
    version_notes_file: Path,
) -> dict:
    topology_targets = topology.get("targets", {})
    require(isinstance(topology_targets, dict), f"{topology_file} targets must be a mapping")

    require(
        "topology" not in data,
        f"{path} uses deprecated key 'topology'; strict v2 requires 'targets_file'",
    )
    require(
        "bindings_file" not in data,
        f"{path} uses deprecated key 'bindings_file'; strict v2 uses targets only",
    )
    require(
        "profiles" not in data and "runtime" not in data,
        f"{path} must not define inline profiles/runtime in strict v2",
    )

    targets_ref = data.get("targets_file")
    require(
        isinstance(targets_ref, str) and targets_ref.strip(),
        f"{path} targets_file must be a non-empty string",
    )
    require(
        Path(targets_ref).name == topology_file.name,
        f"{path} targets_file='{targets_ref}' does not match active targets '{topology_file.name}'",
    )

    require(
        "version_notes_file" not in data,
        f"{path} must not define version_notes_file; strict v2 sources it from base_file",
    )

    base_file_ref = data.get("base_file")
    overlay_file_ref = data.get("overlay_file")
    overlay_variant_ref = data.get("overlay_variant")
    require(
        isinstance(base_file_ref, str) and base_file_ref.strip(),
        f"{path} base_file must be a non-empty string",
    )
    require(
        isinstance(overlay_file_ref, str) and overlay_file_ref.strip(),
        f"{path} overlay_file must be a non-empty string",
    )
    require(
        isinstance(overlay_variant_ref, str) and overlay_variant_ref.strip(),
        f"{path} overlay_variant must be a non-empty string",
    )

    base_path = path.parent / base_file_ref
    overlay_path = path.parent / overlay_file_ref
    require(base_path.exists(), f"{path} references missing base_file: {base_path}")
    require(overlay_path.exists(), f"{path} references missing overlay_file: {overlay_path}")

    base_data = load_yaml(base_path)
    overlay_data = load_yaml(overlay_path)

    base_version_notes = base_data.get("version_notes_file")
    require(
        isinstance(base_version_notes, str) and base_version_notes.strip(),
        f"{base_path} version_notes_file must be a non-empty string",
    )
    require(
        Path(base_version_notes).name == version_notes_file.name,
        f"{base_path} version_notes_file='{base_version_notes}' does not match active notes '{version_notes_file.name}'",
    )

    base_profiles = base_data.get("profiles", {})
    require(isinstance(base_profiles, dict), f"{base_path} profiles must be a mapping")

    variants_map = overlay_data.get("variants", {})
    require(isinstance(variants_map, dict), f"{overlay_path} variants must be a mapping")
    selected_overlay = variants_map.get(overlay_variant_ref)
    if selected_overlay is None:
        selected_overlay = {}
    require(
        isinstance(selected_overlay, dict),
        (
            f"{overlay_path} variants.{overlay_variant_ref} must be a mapping when provided "
            f"(referenced by {path})"
        ),
    )

    overlay_profiles = selected_overlay.get("profiles", {})
    if overlay_profiles is None:
        overlay_profiles = {}
    require(
        isinstance(overlay_profiles, dict),
        f"{overlay_path} variants.{overlay_variant_ref}.profiles must be a mapping",
    )

    profiles = merge_profiles_with_overlay_delta(
        base_profiles,
        overlay_profiles,
        f"{path}",
    )

    for profile_name, profile_entry in profiles.items():
        require(isinstance(profile_entry, dict), f"{path} profiles.{profile_name} must be a mapping")
        libs = profile_entry.get("libs")
        if libs is not None:
            require(isinstance(libs, dict), f"{path} profiles.{profile_name}.libs must be a mapping")
            if "mandatory" in libs:
                normalize_string_list(
                    libs["mandatory"],
                    f"{path} profiles.{profile_name}.libs.mandatory",
                )
        tools = profile_entry.get("tools")
        if tools is not None:
            require(isinstance(tools, dict), f"{path} profiles.{profile_name}.tools must be a mapping")

    base_runtime = base_data.get("runtime", {})
    if base_runtime is None:
        base_runtime = {}
    require(isinstance(base_runtime, dict), f"{base_path} runtime must be a mapping")
    runtime = copy.deepcopy(base_runtime)

    overlay_runtime = selected_overlay.get("runtime")
    if overlay_runtime is not None:
        require(
            isinstance(overlay_runtime, dict),
            f"{overlay_path} variants.{overlay_variant_ref}.runtime must be a mapping",
        )
        runtime = deep_merge_dict(runtime, overlay_runtime)

    if "libs" not in runtime:
        runtime["libs"] = {}
    if "tools" not in runtime:
        runtime["tools"] = {}
    require(isinstance(runtime["libs"], dict), f"{path} runtime.libs must be a mapping")
    require(isinstance(runtime["tools"], dict), f"{path} runtime.tools must be a mapping")

    expanded = copy.deepcopy(data)
    build_out: dict[str, dict] = {}
    for family, family_entry in topology_targets.items():
        require(
            isinstance(family_entry, dict),
            f"{topology_file} targets.{family} must be a mapping",
        )
        build_out[family] = {}
        for os_name, topology_os_entry in family_entry.items():
            require(
                isinstance(topology_os_entry, dict),
                f"{topology_file} targets.{family}.{os_name} must be a mapping",
            )

            topology_packagers = topology_os_entry.get("packagers", {})
            require(
                isinstance(topology_packagers, dict) and bool(topology_packagers),
                f"{topology_file} targets.{family}.{os_name}.packagers must be a non-empty mapping",
            )

            profile_name = topology_os_entry.get("profile")
            profile: dict = {}
            require(
                isinstance(profile_name, str) and profile_name.strip(),
                f"{topology_file} targets.{family}.{os_name}.profile must be a non-empty string",
            )
            require(
                profile_name in profiles,
                f"{topology_file} targets.{family}.{os_name}.profile references unknown profile '{profile_name}'",
            )
            profile = profiles[profile_name]

            packagers: dict[str, dict] = {}
            for pkg_name, topology_pkg_entry in topology_packagers.items():
                if topology_pkg_entry is None:
                    topology_pkg_entry = {}
                require(
                    isinstance(topology_pkg_entry, dict),
                    (
                        f"{topology_file} targets.{family}.{os_name}.packagers."
                        f"{pkg_name} must be a mapping"
                    ),
                )

                merged_pkg = copy.deepcopy(topology_pkg_entry)
                for section in ("libs", "tools"):
                    section_map: dict = {}
                    profile_section = profile.get(section)
                    if profile_section is not None:
                        require(
                            isinstance(profile_section, dict),
                            f"{path} profiles.{profile_name}.{section} must be a mapping",
                        )
                        section_map.update(copy.deepcopy(profile_section))

                    pkg_section = merged_pkg.get(section)
                    if pkg_section is not None:
                        require(
                            isinstance(pkg_section, dict),
                            f"{path} build.{family}.{os_name}.packagers.{pkg_name}.{section} must be a mapping",
                        )
                        section_map.update(copy.deepcopy(pkg_section))

                    if section_map:
                        merged_pkg[section] = section_map

                packagers[pkg_name] = merged_pkg

            build_out[family][os_name] = {
                "profile": profile_name,
                "packagers": packagers,
            }

    resolved_version_notes = copy.deepcopy(shared_version_notes)

    expanded["build"] = build_out
    expanded["runtime"] = runtime
    expanded["version_notes"] = resolved_version_notes
    return expanded


def check_file(
    path: Path,
    topology: dict,
    topology_file: Path,
    shared_version_notes: dict,
    version_notes_file: Path,
) -> None:
    data = expand_variant_profiles(
        load_yaml(path),
        path,
        topology,
        topology_file,
        shared_version_notes,
        version_notes_file,
    )
    require("runtime" in data, f"{path} missing runtime section")

    build = data["build"]
    for family, family_entry in build.items():
        require(isinstance(family_entry, dict), f"{path} build.{family} must be a mapping")
        for os_name, os_entry in family_entry.items():
            require(
                isinstance(os_entry, dict),
                f"{path} build.{family}.{os_name} must be a mapping",
            )
            require(
                "packagers" in os_entry,
                f"{path} missing build.{family}.{os_name}.packagers",
            )
            for pkg_name, pkg in os_entry.get("packagers", {}).items():
                require(
                    "libs" in pkg,
                    f"{path} missing libs for build.{family}.{os_name}.packagers.{pkg_name}",
                )
                require(
                    isinstance(pkg.get("libs"), dict),
                    f"{path} build.{family}.{os_name}.packagers.{pkg_name}.libs must be a mapping",
                )
                require(
                    "mandatory" in pkg["libs"],
                    f"{path} missing libs.mandatory for build.{family}.{os_name}.packagers.{pkg_name}",
                )
                normalize_string_list(
                    pkg["libs"]["mandatory"],
                    f"{path} build.{family}.{os_name}.packagers.{pkg_name}.libs.mandatory",
                )

    # Runtime
    runtime = data["runtime"]
    require("libs" in runtime, f"{path} missing runtime.libs")
    require("tools" in runtime, f"{path} missing runtime.tools")

    # Optional metadata
    if "version_notes" in data:
        require(isinstance(data["version_notes"], dict), f"{path} version_notes must be a mapping")


def packages_from_yaml_list(
    variant: str,
    family: str,
    os_name: str,
    pkgmgr: str,
    enable_ldap: str,
    enable_snmp: str,
) -> list[str]:
    script = ROOT / "ci" / "deps" / "packages-from-yaml.sh"
    out = subprocess.check_output(
        [
            str(script),
            "--variant",
            variant,
            "--family",
            family,
            "--os",
            os_name,
            "--pkgmgr",
            pkgmgr,
            "--enable-ldap",
            enable_ldap,
            "--enable-snmp",
            enable_snmp,
        ],
        text=True,
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def diff(label: str, expected: list[str], actual: list[str]) -> bool:
    exp_set = set(expected)
    act_set = set(actual)
    missing = sorted(exp_set - act_set)
    extra = sorted(act_set - exp_set)
    ok = True
    print(f"-- {label}")
    print(f"   expected: {', '.join(sorted(exp_set))}")
    print(f"   actual:   {', '.join(sorted(act_set))}")
    if missing:
        ok = False
        print(f"   MISSING:  {', '.join(missing)}")
    if extra:
        ok = False
        print(f"   EXTRA:    {', '.join(extra)}")
    return ok


def print_diff(label: str, expected: list[str], actual: list[str]) -> None:
    exp_set = set(expected)
    act_set = set(actual)
    print(f"-- {label}")
    print(f"   expected: {', '.join(sorted(exp_set))}")
    print(f"   actual:   {', '.join(sorted(act_set))}")


def scan_runtime_tools(tokens: set[str]) -> set[str]:
    patterns = {token: re.compile(rf"\\b{re.escape(token)}\\b") for token in tokens if token}
    found = set()
    for path in ROOT.rglob("*.sh"):
        text = path.read_text(errors="ignore")
        for token, pat in patterns.items():
            if pat.search(text):
                found.add(token)
    return found


def gather_build_combinations(data: dict) -> list[tuple[str, str, str]]:
    combos: list[tuple[str, str, str]] = []
    for family, family_entry in data.get("build", {}).items():
        if not isinstance(family_entry, dict):
            continue
        for os_name, os_entry in family_entry.items():
            if not isinstance(os_entry, dict):
                continue
            packagers = os_entry.get("packagers", {})
            if not isinstance(packagers, dict):
                continue
            for pkgmgr in packagers:
                combos.append((family, os_name, pkgmgr))
    return combos


def check_packages_from_yaml_mapping(data: dict, variant: str) -> bool:
    combos = gather_build_combinations(data)
    if not combos:
        return True
    script = ROOT / "ci" / "deps" / "packages-from-yaml.sh"
    if not script.exists():
        print("   ERROR: packages-from-yaml.sh missing; cannot validate mappings")
        return False
    ok = True
    for family, os_name, pkgmgr in combos:
        cmd = [
            str(script),
            "--variant",
            variant,
            "--family",
            family,
            "--os",
            os_name,
            "--pkgmgr",
            pkgmgr,
            "--enable-ldap",
            "ON",
            "--enable-snmp",
            "ON",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            ok = False
            print(
                f"   ERROR: packages-from-yaml.sh failed for variant={variant} family={family} "
                f"os={os_name} pkgmgr={pkgmgr}"
            )
            if result.stdout.strip():
                print(f"      stdout: {result.stdout.strip()}")
            if result.stderr.strip():
                print(f"      stderr: {result.stderr.strip()}")
    return ok


def iter_ref_validation_lanes() -> list[tuple[str, Path, str, dict]]:
    lanes: list[tuple[str, Path, str, dict]] = []

    if not REF_FAMILIES_MANIFEST.exists():
        print(f"   ERROR: missing ref families manifest: {REF_FAMILIES_MANIFEST}")
        return lanes

    try:
        manifest = load_purpose_manifest_common(
            REF_FAMILIES_MANIFEST,
            purpose="validation",
            supported_runtimes=(
                "linux_host",
                "linux_container",
                "bsd_vm",
                "macos_host",
            ),
        )
    except SystemExit as exc:
        print(f"   ERROR: {exc}")
        return lanes

    for entry in manifest["entries"]:
        family = entry["family"]
        lane_file = entry["lane_file"]

        lane_path = ROOT / lane_file
        if not lane_path.exists():
            print(f"   ERROR: lane file for family '{family}' does not exist: {lane_path}")
            continue

        lane_doc = yaml.safe_load(lane_path.read_text()) or {}
        try:
            include = extract_lane_include(lane_doc, lane_path)
        except LaneSpecError as exc:
            print(f"   ERROR: {exc}")
            continue

        for lane_index, lane in enumerate(include):
            if not isinstance(lane, dict):
                continue
            try:
                lane_variants = expand_lane_variants(lane, lane_path, lane_index)
            except LaneSpecError as exc:
                print(f"   ERROR: {exc}")
                continue

            for lane_variant in lane_variants:
                variant = lane_variant.get("variant")
                if not isinstance(variant, str):
                    continue
                variant = variant.strip()
                if variant not in SUPPORTED_LANE_VARIANTS:
                    continue
                lane_variant["variant"] = variant
                lanes.append((family, lane_path, variant, lane_variant))

    return lanes


def check_ref_workflow_deps_coverage(
    variant_index: dict[str, dict[str, set[str]]],
    platform_releases: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_releases:
        print(f"   ERROR: platform releases missing or invalid: {PLATFORM_RELEASES_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid in {PLATFORM_CATALOG_FILE}")
        return False

    ok = True
    lanes = iter_ref_validation_lanes()
    image_to_platform, duplicate_images = build_docker_image_index(platform_releases)

    if duplicate_images:
        ok = False
        for image_ref, platform_ids in sorted(duplicate_images.items()):
            print(
                f"   ERROR: duplicate runtime=docker image '{image_ref}' in platform releases: "
                f"{', '.join(sorted(platform_ids))}"
            )

    if not lanes:
        print("   NOTE: no ref-validation lane entries found")
        return True

    for family, lane_path, variant, lane in lanes:
        lane_name = lane.get("name", "<unnamed>")
        lane_ref = f"{family}:{lane_name}"
        req_type, req_value = map_ref_lane_to_platform_requirement(family, lane)
        platform_id = ""
        if req_type == "docker_image":
            platform_id = image_to_platform.get(req_value, "")
            if not platform_id:
                ok = False
                print(
                    f"   ERROR: {lane_ref} requires docker image '{req_value}' "
                    "missing from platform releases"
                )
                continue
        elif req_type == "platform_id":
            platform_id = req_value
            if not platform_id:
                ok = False
                print(f"   ERROR: {lane_ref} could not derive a platform id")
                continue
            if platform_id not in platform_releases:
                ok = False
                print(
                    f"   ERROR: {lane_ref} requires platform '{platform_id}' "
                    "missing from platform releases"
                )
                continue
        else:
            ok = False
            print(
                f"   ERROR: {lane_ref} has unknown platform mapping: {(req_type, req_value)} "
                f"(source: {lane_path})"
            )
            continue

        binding = platform_bindings.get(platform_id)
        if not isinstance(binding, dict):
            ok = False
            print(
                f"   ERROR: {lane_ref} maps to platform '{platform_id}' "
                "without a deps binding"
            )
            continue

        binding_family = binding.get("package_family")
        os_name = binding.get("platform_os")
        version = binding.get("deps_key")
        if (
            not isinstance(binding_family, str)
            or not binding_family.strip()
            or not isinstance(os_name, str)
            or not os_name.strip()
        ):
            ok = False
            print(
                f"   ERROR: platform '{platform_id}' has invalid deps binding "
                "(missing non-empty package_family/platform_os)"
            )
            continue

        os_key = compose_os_key(os_name, version)
        families = variant_index.get(variant, {})
        if binding_family not in families:
            ok = False
            print(
                f"   ERROR: {lane_ref} uses variant={variant} family={binding_family} "
                f"but deps-{variant}.yaml has no family '{binding_family}'"
            )
            continue
        if os_key not in families[binding_family]:
            ok = False
            print(
                f"   ERROR: {lane_ref} expects deps key {binding_family}.{os_key} "
                f"for variant={variant}, but it is missing in deps-{variant}.yaml"
            )

    if ok:
        print("   OK: ref-validation lanes are covered by deps keys")
    return ok


def check_platform_catalog_bindings_consistency(
    platform_catalog: dict[str, dict],
    platform_releases: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_catalog:
        print(f"   ERROR: platform catalog missing or invalid: {PLATFORM_CATALOG_FILE}")
        return False
    if not platform_releases:
        print(f"   ERROR: platform releases missing or invalid: {PLATFORM_RELEASES_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid in {PLATFORM_CATALOG_FILE}")
        return False

    ok = True
    catalog_ids = set(platform_releases.keys())
    binding_ids = set(platform_bindings.keys())

    missing_bindings = sorted(catalog_ids - binding_ids)
    extra_bindings = sorted(binding_ids - catalog_ids)

    for platform_id in missing_bindings:
        ok = False
        print(f"   ERROR: platform '{platform_id}' is in catalog but missing deps mapping under 'deps'")
    for platform_id in extra_bindings:
        ok = False
        print(f"   ERROR: platform '{platform_id}' has deps mapping but is missing from catalog")

    for platform_id, binding in platform_bindings.items():
        family = binding.get("package_family")
        os_name = binding.get("platform_os")
        if not isinstance(family, str) or not family.strip() or not isinstance(os_name, str) or not os_name.strip():
            ok = False
            print(
                f"   ERROR: deps binding for platform '{platform_id}' "
                "must include non-empty 'package_family' and 'platform_os'"
            )

    if ok:
        print("   OK: platform catalog and releases deps mappings are aligned")
    return ok


def check_docker_platforms_map_to_deps(
    variant_index: dict[str, dict[str, set[str]]],
    platform_releases: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_releases:
        print(f"   ERROR: platform releases missing or invalid: {PLATFORM_RELEASES_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid in {PLATFORM_CATALOG_FILE}")
        return False

    ok = True
    found_docker = False
    for platform_id, entry in platform_releases.items():
        runtime = str(entry.get("runtime", "docker")).strip().lower()
        if runtime != "docker":
            continue
        found_docker = True

        image_ref = entry.get("image")

        if not isinstance(image_ref, str) or not image_ref.strip():
            ok = False
            print(f"   ERROR: platform '{platform_id}' (runtime=docker) missing non-empty 'image' field")
            continue

        binding = platform_bindings.get(platform_id)
        if not isinstance(binding, dict):
            ok = False
            print(f"   ERROR: platform '{platform_id}' (runtime=docker) missing deps binding")
            continue

        family = binding.get("package_family")
        os_name = binding.get("platform_os")
        version = binding.get("deps_key")

        if not isinstance(family, str) or not isinstance(os_name, str):
            ok = False
            print(
                f"   ERROR: platform '{platform_id}' (runtime=docker) deps binding "
                "missing 'package_family' or 'platform_os' field"
            )
            continue

        os_key = compose_os_key(os_name, version)
        for variant, families in variant_index.items():
            if family not in families or os_key not in families[family]:
                ok = False
                print(
                    f"   ERROR: platform '{platform_id}' (runtime=docker) expects deps key {family}.{os_key} "
                    f"for variant={variant}, but it is missing"
                )

    if not found_docker:
        print("   ERROR: platform releases have no runtime=docker entries")
        return False

    if ok:
        print("   OK: runtime=docker platform entries map to deps keys")
    return ok


def map_ref_lane_to_platform_requirement(
    family: str,
    lane: dict,
) -> tuple[str, str]:
    platform_id = lane.get("platform_id")
    if isinstance(platform_id, str) and platform_id.strip():
        return "platform_id", platform_id.strip()

    container = lane.get("container")
    if isinstance(container, str) and container:
        return "docker_image", normalize_container_ref(container)

    if family == "freebsd" or "freebsd_version" in lane:
        version = str(lane.get("freebsd_version", "")).strip()
        return "platform_id", f"freebsd-{version.replace('.', '_')}" if version else ""
    if family == "netbsd" or "netbsd_version" in lane:
        version = str(lane.get("netbsd_version", "")).strip()
        return "platform_id", f"netbsd-{version.replace('.', '_')}" if version else ""
    if family == "openbsd" or "openbsd_version" in lane:
        version = str(lane.get("openbsd_version", "")).strip()
        return "platform_id", f"openbsd-{version.replace('.', '_')}" if version else ""
    if family == "macos" or "macos_version" in lane:
        version = str(lane.get("macos_version", "")).strip()
        if version:
            return "platform_id", f"macos-{version}"
        runner = lane.get("runner")
        if isinstance(runner, str) and runner.strip():
            return "platform_id", runner.strip()
        return "platform_id", ""
    return "unknown", family


def check_ref_workflow_platform_catalog_coverage(platform_releases: dict[str, dict]) -> bool:
    if not platform_releases:
        print(f"   ERROR: platform releases missing or invalid: {PLATFORM_RELEASES_FILE}")
        return False

    image_to_platform, duplicate_images = build_docker_image_index(platform_releases)
    platform_ids = set(platform_releases.keys())

    ok = True
    if duplicate_images:
        ok = False
        for image_ref, platform_id_set in sorted(duplicate_images.items()):
            print(
                f"   ERROR: duplicate runtime=docker image '{image_ref}' in platform releases: "
                f"{', '.join(sorted(platform_id_set))}"
            )

    lanes = iter_ref_validation_lanes()
    if not lanes:
        print("   NOTE: no ref-validation lane entries found")
        return True

    for family, lane_path, _, lane in lanes:
        lane_name = lane.get("name", "<unnamed>")
        lane_ref = f"{family}:{lane_name}"
        req_type, req_value = map_ref_lane_to_platform_requirement(family, lane)
        if not req_type:
            ok = False
            print(f"   ERROR: {lane_ref} could not be mapped to platform requirement")
            continue

        if req_type == "docker_image":
            if req_value not in image_to_platform:
                ok = False
                print(
                    f"   ERROR: {lane_ref} requires docker image '{req_value}' "
                    "missing from platform releases"
                )
            continue

        if req_type == "platform_id":
            platform_id = req_value
            if not platform_id:
                ok = False
                print(f"   ERROR: {lane_ref} could not derive a platform id")
                continue
            if platform_id not in platform_ids:
                ok = False
                print(
                    f"   ERROR: {lane_ref} requires platform '{platform_id}' "
                    "missing from platform releases"
                )
                continue

            runtime = str(platform_releases[platform_id].get("runtime", "")).strip().lower()
            if platform_id.startswith(("freebsd-", "netbsd-", "openbsd-")) and runtime != "vm":
                ok = False
                print(
                    f"   ERROR: {lane_ref} expects platform '{platform_id}' "
                    f"to use runtime=vm (found runtime={runtime})"
                )
            if platform_id.startswith("macos-"):
                if runtime != "host":
                    ok = False
                    print(
                        f"   ERROR: {lane_ref} expects platform '{platform_id}' "
                        f"to use runtime=host (found runtime={runtime})"
                    )
                lane_runner = lane.get("runner")
                catalog_runner = platform_releases[platform_id].get("runner")
                if (
                    isinstance(lane_runner, str)
                    and lane_runner.strip()
                    and isinstance(catalog_runner, str)
                    and catalog_runner.strip()
                    and lane_runner.strip() != catalog_runner.strip()
                ):
                    ok = False
                    print(
                        f"   ERROR: {lane_ref} runner='{lane_runner}' "
                        f"does not match catalog runner='{catalog_runner}' for platform '{platform_id}'"
                    )
            continue

        ok = False
        print(
            f"   ERROR: {lane_ref} has unknown platform mapping: {(req_type, req_value)} "
            f"(source: {lane_path})"
        )

    if ok:
        print("   OK: ref-validation lanes are declared in platform releases")
    return ok


def parse_linux_families(client_data: dict) -> set[str]:
    families = set(client_data.get("build", {}).keys())
    return {family for family in families if family in {"debian", "gh-debian", "ubuntu"}}


def build_family_os_index(data: dict) -> dict[str, set[str]]:
    index: dict[str, set[str]] = {}
    build = data.get("build", {})
    if not isinstance(build, dict):
        return index
    for family, family_entry in build.items():
        if not isinstance(family_entry, dict):
            continue
        index[family] = {os_name for os_name in family_entry.keys() if isinstance(os_name, str)}
    return index


def check_platform_normalization_against_topology(topology: dict, normalization_rules: dict[str, dict]) -> bool:
    build = topology.get("build", {})
    if not isinstance(build, dict):
        print(f"   ERROR: invalid topology build structure in {DEFAULT_TOPOLOGY_FILE}")
        return False
    if not normalization_rules:
        print(f"   ERROR: platform normalization missing or invalid: {PLATFORM_NORMALIZATION_FILE}")
        return False

    ok = True
    for os_id, rule in sorted(normalization_rules.items()):
        family = rule.get("family")
        os_name = rule.get("os")
        pkgmgr = rule.get("pkgmgr")
        mode = rule.get("version_mode")
        versions = rule.get("versions", {})
        version_default = rule.get("version_default")
        version_fixed = rule.get("version_fixed")

        if not all(isinstance(v, str) and v.strip() for v in (family, os_name, pkgmgr, mode)):
            ok = False
            print(
                f"   ERROR: normalization rule '{os_id}' must define non-empty "
                "family/os/pkgmgr/version_mode"
            )
            continue

        family_entry = build.get(family, {})
        if not isinstance(family_entry, dict):
            ok = False
            print(
                f"   ERROR: normalization rule '{os_id}' targets missing topology family '{family}'"
            )
            continue

        try:
            strict_keys, candidate_keys = candidate_os_keys_for_rule(rule)
        except ValueError as exc:
            ok = False
            if "versions must be a mapping" in str(exc):
                print(f"   ERROR: normalization rule '{os_id}' versions must be a mapping")
            else:
                print(f"   ERROR: normalization rule '{os_id}' has {exc}")
            continue

        if strict_keys:
            for os_key in sorted(candidate_keys):
                os_entry = family_entry.get(os_key)
                if not isinstance(os_entry, dict):
                    ok = False
                    print(
                        f"   ERROR: normalization rule '{os_id}' maps to missing topology key "
                        f"{family}.{os_key}"
                    )
                    continue
                packagers = os_entry.get("packagers", {})
                if not isinstance(packagers, dict) or pkgmgr not in packagers:
                    ok = False
                    print(
                        f"   ERROR: normalization rule '{os_id}' maps to topology key "
                        f"{family}.{os_key} without pkgmgr '{pkgmgr}'"
                    )
        else:
            matching_keys = [
                key
                for key in family_entry.keys()
                if isinstance(key, str) and (key == os_name or key.startswith(f"{os_name}_"))
            ]
            if not matching_keys:
                ok = False
                print(
                    f"   ERROR: normalization rule '{os_id}' has no matching topology keys "
                    f"under family '{family}' for os prefix '{os_name}'"
                )
                continue

            pkgmgr_match = False
            for os_key in matching_keys:
                os_entry = family_entry.get(os_key, {})
                packagers = os_entry.get("packagers", {}) if isinstance(os_entry, dict) else {}
                if isinstance(packagers, dict) and pkgmgr in packagers:
                    pkgmgr_match = True
                    break
            if not pkgmgr_match:
                ok = False
                print(
                    f"   ERROR: normalization rule '{os_id}' matched topology keys for {family}.{os_name}* "
                    f"but none expose pkgmgr '{pkgmgr}'"
                )

    if ok:
        print("   OK: platform normalization rules align with deps topology")
    return ok


def normalize_container_ref(image: str) -> str:
    return image.strip().lower().split("@", 1)[0]


def parse_bsd_pkgmgrs() -> dict[str, str]:
    # Dispatcher defaults in ci/deps/install-bsd-packages.sh.
    return {
        "FreeBSD": "pkg",
        "NetBSD": "pkg_add",
        "OpenBSD": "pkg_add",
    }


def parse_bsd_pkgmgr_keys() -> set[str]:
    return {"pkg", "pkgin", "pkg_add"}


def normalize_bsd_os_key(os_name: str) -> str:
    lowered = os_name.lower()
    if lowered in {"freebsd", "netbsd", "openbsd"}:
        return lowered
    return os_name


def parse_ldap_pkg_name() -> str | None:
    paths = [
        ROOT / "ci" / "deps" / "install-bsd-packages.sh",
        ROOT / "ci" / "deps" / "lib" / "install-bsd-common.sh",
    ]
    for path in paths:
        if not path.exists():
            continue
        script = path.read_text()
        if re.search(r"openldap-client", script):
            return "openldap-client"
    return None


def extract_cmake_deps(text: str) -> set[str]:
    deps = set()
    for pattern in (
        r"find_package\(([^)]+)\)",
        r"find_library\(([^)\s]+)",
        r"find_path\(([^)\s]+)",
    ):
        for match in re.finditer(pattern, text, flags=re.IGNORECASE):
            name = match.group(1).split()[0]
            name = re.sub(r"[^A-Za-z0-9_]+", "", name)
            if name:
                deps.add(name)
    return deps


def normalize_token(token: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", token.lower())


def load_deps_map() -> dict:
    if not MAP_FILE.exists():
        return {}
    data = load_yaml(MAP_FILE)
    if not isinstance(data, dict):
        return {}
    return data


def resolve_alias(dep: str, dep_map: dict) -> str:
    aliases = dep_map.get("aliases", {})
    if isinstance(aliases, dict) and dep in aliases:
        return aliases[dep]
    return dep


def infer_required_flags_from_script(script_path: Path) -> set[str]:
    """Infer required CLI flags from install script implementation."""
    text = script_path.read_text(errors="ignore")
    match = re.search(r"\bci_deps_parse_cli\s+([01])\s+([01])\b", text)
    if not match:
        return set()

    require_family = match.group(1) == "1"
    require_os = match.group(2) == "1"
    required: set[str] = set()
    if require_family:
        required.add("--family")
    if require_os:
        required.add("--os")
    return required


def extract_flag_values(run_snippet: str, flag: str) -> list[str]:
    pattern = re.compile(rf"{re.escape(flag)}(?:=|[ \t\r\n]+)([^\s\\]+)")
    values: list[str] = []
    for match in pattern.finditer(run_snippet):
        raw = match.group(1).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {'"', "'"}:
            raw = raw[1:-1]
        values.append(raw)
    return values


MAP_RESOLVE_CACHE: dict[tuple[tuple[str, ...], str, str, str], list[str]] = {}


def resolve_packages(
    items: list[str],
    family: str,
    os_name: str,
    pkgmgr: str,
) -> list[str]:
    normalized = tuple(str(item).strip() for item in items if isinstance(item, str) and str(item).strip())
    if not normalized:
        return []

    key = (normalized, family, os_name, pkgmgr)
    cached = MAP_RESOLVE_CACHE.get(key)
    if cached is not None:
        return list(cached)

    if not MAP_RESOLVER_AWK.exists():
        print(f"ERROR: map resolver missing: {MAP_RESOLVER_AWK}")
        sys.exit(2)

    result = subprocess.run(
        [
            "awk",
            "-v",
            f"MAP_FILE={MAP_FILE}",
            "-v",
            f"FAMILY={family}",
            "-v",
            f"OS={os_name}",
            "-v",
            f"PKGMGR={pkgmgr}",
            "-f",
            str(MAP_RESOLVER_AWK),
        ],
        input="\n".join(normalized) + "\n",
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        print(
            "ERROR: map resolver failed for "
            f"family={family} os={os_name} pkgmgr={pkgmgr} using {MAP_FILE}"
        )
        if result.stderr.strip():
            print(result.stderr.strip())
        sys.exit(2)

    resolved = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    MAP_RESOLVE_CACHE[key] = resolved
    return list(resolved)


def main() -> int:
    missing = [p for p in FILES if not p.exists()]
    if missing:
        print("Missing required files:")
        for p in missing:
            print(f"  - {p}")
        return 2

    targets_name: str | None = None
    base_name: str | None = None
    overlay_name: str | None = None
    seen_overlay_variants: set[str] = set()
    for path in FILES:
        variant_data = load_yaml(path)
        variant_name = path.stem.removeprefix("deps-")
        require(
            "topology" not in variant_data,
            f"{path} uses deprecated key 'topology'; strict v2 requires 'targets_file'",
        )
        require(
            "bindings_file" not in variant_data,
            f"{path} uses deprecated key 'bindings_file'; strict v2 uses targets only",
        )
        require(
            "version_notes_file" not in variant_data,
            f"{path} must not define version_notes_file; strict v2 sources it from base_file",
        )

        variant_targets = variant_data.get("targets_file")
        variant_base = variant_data.get("base_file")
        variant_overlay = variant_data.get("overlay_file")
        variant_overlay_variant = variant_data.get("overlay_variant")
        require(
            isinstance(variant_targets, str) and variant_targets.strip(),
            f"{path} targets_file must be a non-empty string when provided",
        )
        require(
            isinstance(variant_base, str) and variant_base.strip(),
            f"{path} base_file must be a non-empty string",
        )
        require(
            isinstance(variant_overlay, str) and variant_overlay.strip(),
            f"{path} overlay_file must be a non-empty string",
        )
        require(
            isinstance(variant_overlay_variant, str) and variant_overlay_variant.strip(),
            f"{path} overlay_variant must be a non-empty string",
        )
        require(
            variant_overlay_variant == variant_name,
            (
                f"{path} overlay_variant='{variant_overlay_variant}' must match variant file "
                f"'{variant_name}'"
            ),
        )
        require(
            variant_overlay_variant not in seen_overlay_variants,
            f"duplicate overlay_variant '{variant_overlay_variant}' across variant files",
        )
        seen_overlay_variants.add(variant_overlay_variant)
        if targets_name is None:
            targets_name = variant_targets
        else:
            require(
                variant_targets == targets_name,
                f"{path} targets_file '{variant_targets}' does not match '{targets_name}' used by other variants",
            )
        if base_name is None:
            base_name = variant_base
        else:
            require(
                variant_base == base_name,
                f"{path} base_file '{variant_base}' does not match '{base_name}' used by other variants",
            )
        if overlay_name is None:
            overlay_name = variant_overlay
        else:
            require(
                variant_overlay == overlay_name,
                f"{path} overlay_file '{variant_overlay}' does not match '{overlay_name}' used by other variants",
            )

    assert targets_name is not None
    assert base_name is not None
    assert overlay_name is not None
    topology_file = DATA_DIR / targets_name
    base_file = DATA_DIR / base_name
    require(base_file.exists(), f"missing base file: {base_file}")
    base_data = load_yaml(base_file)
    version_notes_name = base_data.get("version_notes_file")
    require(
        isinstance(version_notes_name, str) and version_notes_name.strip(),
        f"{base_file} version_notes_file must be a non-empty string",
    )
    version_notes_file = DATA_DIR / version_notes_name

    topology = load_topology(topology_file)
    normalization_rules = load_platform_normalization_rules()
    shared_version_notes = load_shared_version_notes(version_notes_file)
    for path in FILES:
        check_file(
            path,
            topology,
            topology_file,
            shared_version_notes,
            version_notes_file,
        )

    print("deps YAML structure OK")

    client = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-client.yaml"),
        DATA_DIR / "deps-client.yaml",
        topology,
        topology_file,
        shared_version_notes,
        version_notes_file,
    )
    localclient = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-localclient.yaml"),
        DATA_DIR / "deps-localclient.yaml",
        topology,
        topology_file,
        shared_version_notes,
        version_notes_file,
    )
    server = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-server.yaml"),
        DATA_DIR / "deps-server.yaml",
        topology,
        topology_file,
        shared_version_notes,
        version_notes_file,
    )
    dep_map = load_deps_map()
    variant_index = {
        "client": build_family_os_index(client),
        "localclient": build_family_os_index(localclient),
        "server": build_family_os_index(server),
    }
    platform_catalog = load_platform_catalog(PLATFORM_CATALOG_FILE, load_yaml, require)
    platform_releases = load_platform_releases(PLATFORM_RELEASES_FILE, load_yaml, require)
    platform_bindings = load_platform_deps_bindings(
        platform_catalog, platform_releases, normalization_rules
    )

    # --- normalization -> topology coverage ---
    ok = True
    print("-- normalization: topology coverage")
    if not check_platform_normalization_against_topology(topology, normalization_rules):
        ok = False

    # --- schema completeness ---
    print("-- schema: completeness")
    for name, data in ("client", client), ("server", server):
        for family, family_entry in data["build"].items():
            for os_name, os_entry in family_entry.items():
                packagers = os_entry.get("packagers", {})
                for pkg_name, pkg in packagers.items():
                    if "libs" not in pkg or "tools" not in pkg:
                        print(f"   ERROR: {name} missing libs/tools for {family}.{os_name}.{pkg_name}")
                        return 1
                    if "mandatory" not in pkg["libs"]:
                        print(f"   ERROR: {name} missing libs.mandatory for {family}.{os_name}.{pkg_name}")
                        return 1
        if "libs" not in data.get("runtime", {}) or "tools" not in data.get("runtime", {}):
            print(f"   ERROR: {name} missing runtime.libs/tools")
            return 1
        print(f"   OK: {name} schema")

    # --- build: compare against package scripts (all families) ---
    linux_families = parse_linux_families(client)
    bsd_pkgmgrs = parse_bsd_pkgmgrs()
    bsd_pkgmgr_keys = parse_bsd_pkgmgr_keys()
    ldap_pkg_name = parse_ldap_pkg_name()
    for family, family_entry in client["build"].items():
        for os_name, os_entry in family_entry.items():
            # Validate BSD package manager keys align with installer expectations.
            if os_name.lower() in (name.lower() for name in bsd_pkgmgrs.keys()):
                expected = None
                for key, val in bsd_pkgmgrs.items():
                    if key.lower() == os_name.lower():
                        expected = val
                        break
                if expected:
                    actual_mgrs = set(os_entry.get("packagers", {}).keys())
                    if expected not in actual_mgrs:
                        ok = False
                        print(
                            f"   ERROR: {os_name} packagers missing expected '{expected}' "
                            f"(found: {', '.join(sorted(actual_mgrs)) or 'none'})"
                        )
            for pkg_name, pkg in os_entry.get("packagers", {}).items():
                label = f"build {family} {os_name} {pkg_name}"
                actual_client_raw = pkg["libs"]["mandatory"]
                actual_server_raw = (
                    server["build"][family][os_name]["packagers"][pkg_name]["libs"]["mandatory"]
                    if family in server["build"] and os_name in server["build"][family]
                    else []
                )
                actual_client = resolve_packages(actual_client_raw, family, os_name, pkg_name)
                actual_server = resolve_packages(actual_server_raw, family, os_name, pkg_name)

                if family in linux_families:
                    expected_sets = []
                    for enable_ldap in ("ON", "OFF"):
                        for enable_snmp in ("ON", "OFF"):
                            exp_client = packages_from_yaml_list(
                                "client",
                                family,
                                os_name,
                                pkg_name,
                                enable_ldap,
                                enable_snmp,
                            )
                            exp_server = packages_from_yaml_list(
                                "server",
                                family,
                                os_name,
                                pkg_name,
                                enable_ldap,
                                enable_snmp,
                            )
                            expected_sets.append((enable_ldap, enable_snmp, exp_client, exp_server))
                    matched_client = next(
                        (exp for _, _, exp, _ in expected_sets if set(exp) == set(actual_client)),
                        None,
                    )
                    matched_server = next(
                        (exp for _, _, _, exp in expected_sets if set(exp) == set(actual_server)),
                        None,
                    )
                    print_diff(
                        f"{label} client (linux)",
                        matched_client if matched_client is not None else expected_sets[0][2],
                        actual_client,
                    )
                    print_diff(
                        f"{label} server (linux)",
                        matched_server if matched_server is not None else expected_sets[0][3],
                        actual_server,
                    )
                    if matched_client is None:
                        ok &= diff(f"{label} client (linux)", expected_sets[0][2], actual_client)
                    if matched_server is None:
                        ok &= diff(f"{label} server (linux)", expected_sets[0][3], actual_server)
                elif pkg_name in bsd_pkgmgr_keys:
                    expected_sets = []
                    bsd_os_key = normalize_bsd_os_key(os_name)
                    for enable_snmp in ("ON", "OFF"):
                        exp_client = packages_from_yaml_list(
                            "client",
                            "bsd",
                            bsd_os_key,
                            pkg_name,
                            "OFF",
                            enable_snmp,
                        )
                        exp_server = packages_from_yaml_list(
                            "server",
                            "bsd",
                            bsd_os_key,
                            pkg_name,
                            "ON",
                            enable_snmp,
                        )
                        if ldap_pkg_name and ldap_pkg_name in actual_server:
                            if ldap_pkg_name not in exp_server:
                                exp_server = exp_server + [ldap_pkg_name]
                        expected_sets.append((enable_snmp, exp_client, exp_server))
                    matched_client = next(
                        (exp for _, exp, _ in expected_sets if set(exp) == set(actual_client)),
                        None,
                    )
                    matched_server = next(
                        (exp for _, _, exp in expected_sets if set(exp) == set(actual_server)),
                        None,
                    )
                    print_diff(
                        f"{label} client (bsd)",
                        matched_client if matched_client is not None else expected_sets[0][1],
                        actual_client,
                    )
                    print_diff(
                        f"{label} server (bsd)",
                        matched_server if matched_server is not None else expected_sets[0][2],
                        actual_server,
                    )
                    if matched_client is None:
                        ok &= diff(f"{label} client (bsd)", expected_sets[0][1], actual_client)
                    if matched_server is None:
                        ok &= diff(f"{label} server (bsd)", expected_sets[0][2], actual_server)
                else:
                    print(f"-- NOTE: build: no package-script expectations for {label}")

    # --- parse CMakeLists to validate linked libs (heuristic cross-check) ---
    print("-- build: CMake linkage checks")
    linux_client = []
    linux_server = []
    for family, family_entry in client["build"].items():
        if family not in linux_families:
            continue
        for os_name, os_entry in family_entry.items():
            for pkg_name, pkg in os_entry.get("packagers", {}).items():
                linux_client = resolve_packages(pkg["libs"]["mandatory"], family, os_name, pkg_name)
                linux_server = resolve_packages(
                    server["build"][family][os_name]["packagers"][pkg_name]["libs"]["mandatory"],
                    family,
                    os_name,
                    pkg_name,
                )
                break
            if linux_client:
                break
        if linux_client:
            break

    client_cmake = (ROOT / "client" / "CMakeLists.txt").read_text()
    xymonnet_cmake = (ROOT / "xymonnet" / "CMakeLists.txt").read_text()
    client_deps = extract_cmake_deps(client_cmake)
    server_deps = extract_cmake_deps(xymonnet_cmake)

    def ensure_dep(deps: set[str], pkgs: list[str], label: str) -> None:
        for dep in sorted(deps):
            dep_key = resolve_alias(dep, dep_map)
            map_block = dep_map.get("map", {})
            if dep_key in map_block:
                mapped = []
                for family_entry in map_block[dep_key].values():
                    if not isinstance(family_entry, dict):
                        continue
                    for os_entry in family_entry.values():
                        if not isinstance(os_entry, dict):
                            continue
                        for pkg_list in os_entry.values():
                            mapped += list(pkg_list or [])
                if mapped and not any(normalize_token(pkg) in {normalize_token(p) for p in pkgs} for pkg in mapped):
                    print(f"   NOTE: {label} dependency '{dep}' not found in YAML package names")
            else:
                token = normalize_token(dep)
                if not token:
                    continue
                if not any(token in normalize_token(pkg) for pkg in pkgs):
                    print(f"   NOTE: {label} dependency '{dep}' not found in YAML package names")

    ensure_dep(client_deps, linux_client, "client")
    ensure_dep(server_deps, linux_server, "server")

    # --- runtime tools checks ---
    print("-- runtime: tools checks")
    def normalize_tool_list(value) -> list[str]:
        if value is None:
            return []
        if isinstance(value, list):
            return value
        return []

    runtime_tools = set(normalize_tool_list(client["runtime"]["tools"].get("mandatory")))
    runtime_tools |= set(normalize_tool_list(client["runtime"]["tools"].get("optional")))
    runtime_tools |= set(normalize_tool_list(server["runtime"]["tools"].get("mandatory")))
    runtime_tools |= set(normalize_tool_list(server["runtime"]["tools"].get("optional")))
    runtime_tokens = {normalize_token(tool.split()[0]) for tool in runtime_tools if tool}
    used_tokens = scan_runtime_tools(runtime_tokens)

    missing_in_scripts = sorted(t for t in runtime_tokens if t and t not in used_tokens)
    if missing_in_scripts:
        print(f"   NOTE: runtime.tools not referenced in scripts: {', '.join(missing_in_scripts)}")
    else:
        print("   OK: runtime tools referenced in scripts")

    # --- workflow checks ---
    print("-- workflows: install checks")
    known_families = set(client.get("build", {}).keys())
    known_os = {
        str(entry.get("platform_os")).strip()
        for entry in platform_bindings.values()
        if isinstance(entry, dict)
        and isinstance(entry.get("platform_os"), str)
        and str(entry.get("platform_os")).strip()
    }
    required_flags_cache: dict[Path, set[str]] = {}
    workflow_dir = ROOT / ".github" / "workflows"
    workflow_files = sorted(
        set(workflow_dir.glob("*.yml")) | set(workflow_dir.glob("*.yaml"))
    )
    for wf in workflow_files:
        data = parse_workflow_yaml(wf)
        run_snippets = find_package_steps(data)
        if not run_snippets:
            continue
        # Validate required flags from install script implementations.
        for snippet in run_snippets:
            match = re.search(r"(ci/deps/[^\\s]+packages[^\\s]+\\.sh)", snippet)
            if not match:
                continue
            script_path = ROOT / match.group(1)
            if not script_path.exists():
                continue
            if script_path not in required_flags_cache:
                required_flags_cache[script_path] = infer_required_flags_from_script(script_path)
            required_flags = required_flags_cache[script_path]

            for flag in sorted(required_flags):
                if flag not in snippet:
                    ok = False
                    print(f"   ERROR: {wf} runs {script_path.name} without {flag}")
            if "--family" in required_flags:
                family_values = extract_flag_values(snippet, "--family")
                for family in family_values:
                    # Skip dynamic interpolation expressions.
                    if "$" in family:
                        continue
                    if family not in known_families:
                        ok = False
                        print(
                            f"   ERROR: {wf} runs {script_path.name} with unknown --family '{family}' "
                            f"(known: {', '.join(sorted(known_families))})"
                        )
            if "--os" in required_flags:
                os_values = extract_flag_values(snippet, "--os")
                for os_name in os_values:
                    # Skip dynamic interpolation expressions.
                    if "$" in os_name:
                        continue
                    if os_name not in known_os:
                        ok = False
                        print(
                            f"   ERROR: {wf} runs {script_path.name} with unknown --os '{os_name}' "
                            "for current platform catalog/releases deps mappings"
                        )

    print("-- platforms: catalog deps consistency")
    if not check_platform_catalog_bindings_consistency(
        platform_catalog, platform_releases, platform_bindings
    ):
        ok = False

    print("-- workflows: ref-validation deps coverage")
    if not check_ref_workflow_deps_coverage(
        variant_index, platform_releases, platform_bindings
    ):
        ok = False

    print("-- platforms: catalog coverage for ref-validation lanes")
    if not check_ref_workflow_platform_catalog_coverage(platform_releases):
        ok = False

    print("-- platforms: runtime=docker entries -> deps coverage")
    if not check_docker_platforms_map_to_deps(
        variant_index, platform_releases, platform_bindings
    ):
        ok = False

    # --- packager keys sanity ---
    print("-- packagers: key sanity")
    bsd_packagers = set()
    bsd_os_names = {name.lower() for name in bsd_pkgmgrs.keys()}
    for family_entry in client["build"].values():
        for os_name, os_entry in family_entry.items():
            if os_name.lower() in bsd_os_names:
                bsd_packagers |= set(os_entry.get("packagers", {}).keys())
    unknown_bsd = sorted(bsd_packagers - bsd_pkgmgr_keys)
    if unknown_bsd:
        ok = False
        print(f"   ERROR: BSD packagers not supported by install-bsd-packages.sh: {', '.join(unknown_bsd)}")
    else:
        print("   OK: BSD packager keys align with install-bsd-packages.sh")

    print("-- packages-from-yaml: validation")
    yaml_ok = check_packages_from_yaml_mapping(client, "client")
    yaml_ok &= check_packages_from_yaml_mapping(localclient, "localclient")
    yaml_ok &= check_packages_from_yaml_mapping(server, "server")
    if not yaml_ok:
        ok = False

    print("-- shellcheck: local + CI helpers")
    if not check_shell_scripts(ROOT):
        ok = False

    if not ok:
        return 1

    print("deps content + CMake + runtime + workflow checks OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
