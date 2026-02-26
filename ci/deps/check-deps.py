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
DEFAULT_TOPOLOGY_FILE = DATA_DIR / "deps-topology.yaml"
DEFAULT_BINDINGS_FILE = DATA_DIR / "deps-variant-bindings.yaml"
DEFAULT_VERSION_NOTES_FILE = DATA_DIR / "deps-version-notes.yaml"
MAP_RESOLVER_AWK = ROOT / "ci" / "deps" / "lib" / "resolve-map.awk"
PLATFORM_NORMALIZATION_FILE = ROOT / "ci" / "deps" / "platform-normalization.yaml"
PLATFORM_CATALOG_FILE = ROOT / "ci" / "deps" / "platform-catalog.yaml"
PLATFORM_BINDINGS_FILE = ROOT / "ci" / "deps" / "platform-deps-bindings.yaml"
REF_VALID_WORKFLOW_GLOB = "ref-valid-*.yml"


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
    build = data.get("build")
    require(isinstance(build, dict), f"{topology_file} build must be a mapping")
    for family, family_entry in build.items():
        require(isinstance(family_entry, dict), f"{topology_file} build.{family} must be a mapping")
        for os_name, os_entry in family_entry.items():
            require(
                isinstance(os_entry, dict),
                f"{topology_file} build.{family}.{os_name} must be a mapping",
            )
            packagers = os_entry.get("packagers")
            require(
                isinstance(packagers, dict) and bool(packagers),
                f"{topology_file} build.{family}.{os_name}.packagers must be a non-empty mapping",
            )
            for pkg_name, pkg_entry in packagers.items():
                if pkg_entry is None:
                    continue
                require(
                    isinstance(pkg_entry, dict),
                    f"{topology_file} build.{family}.{os_name}.packagers.{pkg_name} must be a mapping",
                )
    return data


def load_shared_bindings(bindings_file: Path) -> dict:
    require(bindings_file.exists(), f"missing bindings file: {bindings_file}")
    data = load_yaml(bindings_file)
    bindings = data.get("bindings")
    require(isinstance(bindings, dict), f"{bindings_file} bindings must be a mapping")
    return bindings


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
    shared_bindings: dict,
    bindings_file: Path,
    shared_version_notes: dict,
    version_notes_file: Path,
) -> dict:
    topology_build = topology.get("build", {})
    require(isinstance(topology_build, dict), f"{topology_file} build must be a mapping")

    topology_ref = data.get("topology")
    if topology_ref is not None:
        require(isinstance(topology_ref, str) and topology_ref.strip(), f"{path} topology must be a non-empty string")
        require(
            Path(topology_ref).name == topology_file.name,
            f"{path} topology='{topology_ref}' does not match active topology '{topology_file.name}'",
        )

    bindings_ref = data.get("bindings_file")
    if bindings_ref is not None:
        require(
            isinstance(bindings_ref, str) and bindings_ref.strip(),
            f"{path} bindings_file must be a non-empty string",
        )
        require(
            Path(bindings_ref).name == bindings_file.name,
            f"{path} bindings_file='{bindings_ref}' does not match active bindings '{bindings_file.name}'",
        )

    version_notes_ref = data.get("version_notes_file")
    if version_notes_ref is not None:
        require(
            isinstance(version_notes_ref, str) and version_notes_ref.strip(),
            f"{path} version_notes_file must be a non-empty string",
        )
        require(
            Path(version_notes_ref).name == version_notes_file.name,
            f"{path} version_notes_file='{version_notes_ref}' does not match active notes '{version_notes_file.name}'",
        )

    profiles_raw = data.get("profiles", {})
    require(isinstance(profiles_raw, dict), f"{path} profiles must be a mapping")
    profiles: dict[str, dict] = {}
    for profile_name, profile_entry in profiles_raw.items():
        require(isinstance(profile_name, str) and profile_name.strip(), f"{path} profile names must be non-empty strings")
        require(isinstance(profile_entry, dict), f"{path} profiles.{profile_name} must be a mapping")
        libs = profile_entry.get("libs")
        if libs is not None:
            require(isinstance(libs, dict), f"{path} profiles.{profile_name}.libs must be a mapping")
            if "mandatory" in libs:
                normalize_string_list(libs["mandatory"], f"{path} profiles.{profile_name}.libs.mandatory")
        tools = profile_entry.get("tools")
        if tools is not None:
            require(isinstance(tools, dict), f"{path} profiles.{profile_name}.tools must be a mapping")
        profiles[profile_name] = copy.deepcopy(profile_entry)

    expanded = copy.deepcopy(data)
    bindings = copy.deepcopy(shared_bindings)
    inline_bindings = expanded.get("bindings")
    if inline_bindings is not None:
        require(isinstance(inline_bindings, dict), f"{path} bindings must be a mapping when provided")
        bindings = deep_merge_dict(bindings, inline_bindings)
    require(isinstance(bindings, dict), f"{path} resolved bindings must be a mapping")

    build_out: dict[str, dict] = {}
    for family, family_entry in topology_build.items():
        require(isinstance(family_entry, dict), f"{topology_file} build.{family} must be a mapping")
        family_binding = bindings.get(family)
        require(
            isinstance(family_binding, dict),
            f"{path} bindings.{family} missing or invalid for topology family '{family}'",
        )
        build_out[family] = {}
        for os_name, topology_os_entry in family_entry.items():
            require(
                isinstance(topology_os_entry, dict),
                f"{topology_file} build.{family}.{os_name} must be a mapping",
            )
            os_entry = family_binding.get(os_name)
            require(
                isinstance(os_entry, dict),
                f"{path} bindings.{family}.{os_name} missing or invalid",
            )

            topology_packagers = topology_os_entry.get("packagers", {})
            require(
                isinstance(topology_packagers, dict) and bool(topology_packagers),
                f"{topology_file} build.{family}.{os_name}.packagers must be a non-empty mapping",
            )

            profile_name = os_entry.get("profile")
            profile: dict = {}
            if profile_name is not None:
                require(
                    isinstance(profile_name, str) and profile_name.strip(),
                    f"{path} build.{family}.{os_name}.profile must be a non-empty string",
                )
                require(
                    profile_name in profiles,
                    f"{path} bindings.{family}.{os_name}.profile references unknown profile '{profile_name}'",
                )
                profile = profiles[profile_name]

            binding_packagers = os_entry.get("packagers", {})
            if binding_packagers is None:
                binding_packagers = {}
            require(
                isinstance(binding_packagers, dict),
                f"{path} bindings.{family}.{os_name}.packagers must be a mapping when provided",
            )

            extra_packagers = sorted(set(binding_packagers.keys()) - set(topology_packagers.keys()))
            require(
                not extra_packagers,
                f"{path} bindings.{family}.{os_name}.packagers has keys not in topology: {', '.join(extra_packagers)}",
            )

            packagers: dict[str, dict] = {}
            for pkg_name in topology_packagers.keys():
                pkg_entry = binding_packagers.get(pkg_name, {})
                if pkg_entry is None:
                    pkg_entry = {}
                require(
                    isinstance(pkg_entry, dict),
                    f"{path} bindings.{family}.{os_name}.packagers.{pkg_name} must be a mapping",
                )

                merged_pkg = copy.deepcopy(pkg_entry)
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

    for family, family_binding in bindings.items():
        if not isinstance(family_binding, dict):
            continue
        if family not in topology_build:
            require(False, f"{path} bindings contains family not present in topology: {family}")
        extra_os = sorted(set(family_binding.keys()) - set(topology_build.get(family, {}).keys()))
        require(
            not extra_os,
            f"{path} bindings.{family} contains OS keys not present in topology: {', '.join(extra_os)}",
        )

    resolved_version_notes = copy.deepcopy(shared_version_notes)
    inline_version_notes = expanded.get("version_notes")
    if inline_version_notes is not None:
        require(
            isinstance(inline_version_notes, dict),
            f"{path} version_notes must be a mapping when provided",
        )
        resolved_version_notes = deep_merge_dict(resolved_version_notes, inline_version_notes)

    expanded["build"] = build_out
    expanded["version_notes"] = resolved_version_notes
    return expanded


def check_file(
    path: Path,
    topology: dict,
    topology_file: Path,
    shared_bindings: dict,
    bindings_file: Path,
    shared_version_notes: dict,
    version_notes_file: Path,
) -> None:
    data = expand_variant_profiles(
        load_yaml(path),
        path,
        topology,
        topology_file,
        shared_bindings,
        bindings_file,
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


def parse_workflow_yaml(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text())
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def find_package_steps(workflow: dict) -> list[str]:
    hits: list[str] = []
    jobs = workflow.get("jobs", {})
    if not isinstance(jobs, dict):
        return hits
    for job in jobs.values():
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict):
                continue
            run = step.get("run", "")
            if isinstance(run, str) and "ci/deps/" in run and "packages" in run:
                hits.append(run)
    return hits


def iter_ref_validation_lanes() -> list[tuple[Path, str, dict]]:
    lanes: list[tuple[Path, str, dict]] = []
    workflow_dir = ROOT / ".github" / "workflows"
    for wf in sorted(workflow_dir.glob(REF_VALID_WORKFLOW_GLOB)):
        data = parse_workflow_yaml(wf)
        jobs = data.get("jobs", {})
        if not isinstance(jobs, dict):
            continue
        for job in jobs.values():
            if not isinstance(job, dict):
                continue
            strategy = job.get("strategy", {})
            if not isinstance(strategy, dict):
                continue
            matrix = strategy.get("matrix", {})
            if not isinstance(matrix, dict):
                continue
            include = matrix.get("include", [])
            if not isinstance(include, list):
                continue
            for lane in include:
                if not isinstance(lane, dict):
                    continue
                variant = lane.get("variant")
                if isinstance(variant, str) and variant in {"server", "client", "localclient"}:
                    lanes.append((wf, variant, lane))
    return lanes


def check_ref_workflow_deps_coverage(
    variant_index: dict[str, dict[str, set[str]]],
    platform_catalog: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_catalog:
        print(f"   ERROR: platform catalog missing or invalid: {PLATFORM_CATALOG_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid: {PLATFORM_BINDINGS_FILE}")
        return False

    ok = True
    lanes = iter_ref_validation_lanes()
    image_to_platform, duplicate_images = build_docker_image_index(platform_catalog)

    if duplicate_images:
        ok = False
        for image_ref, platform_ids in sorted(duplicate_images.items()):
            print(
                f"   ERROR: duplicate runtime=docker image '{image_ref}' in platform catalog: "
                f"{', '.join(sorted(platform_ids))}"
            )

    if not lanes:
        print("   NOTE: no ref-valid workflow matrix lanes found")
        return True

    for wf, variant, lane in lanes:
        lane_name = lane.get("name", "<unnamed>")
        req_type, req_value = map_ref_lane_to_platform_requirement(wf, lane)
        platform_id = ""
        if req_type == "docker_image":
            platform_id = image_to_platform.get(req_value, "")
            if not platform_id:
                ok = False
                print(
                    f"   ERROR: {wf.name} lane '{lane_name}' requires docker image '{req_value}' "
                    "missing from platform catalog"
                )
                continue
        elif req_type == "platform_id":
            platform_id = req_value
            if not platform_id:
                ok = False
                print(f"   ERROR: {wf.name} lane '{lane_name}' could not derive a platform id")
                continue
            if platform_id not in platform_catalog:
                ok = False
                print(
                    f"   ERROR: {wf.name} lane '{lane_name}' requires platform '{platform_id}' "
                    "missing from platform catalog"
                )
                continue
        else:
            ok = False
            print(f"   ERROR: {wf.name} lane '{lane_name}' has unknown platform mapping: {(req_type, req_value)}")
            continue

        binding = platform_bindings.get(platform_id)
        if not isinstance(binding, dict):
            ok = False
            print(
                f"   ERROR: {wf.name} lane '{lane_name}' maps to platform '{platform_id}' "
                "without a deps binding"
            )
            continue

        family = binding.get("family")
        os_name = binding.get("os")
        version = binding.get("version")
        if not isinstance(family, str) or not family.strip() or not isinstance(os_name, str) or not os_name.strip():
            ok = False
            print(
                f"   ERROR: platform '{platform_id}' has invalid deps binding "
                "(missing non-empty family/os)"
            )
            continue

        os_key = compose_os_key(os_name, version)
        families = variant_index.get(variant, {})
        if family not in families:
            ok = False
            print(
                f"   ERROR: {wf.name} lane '{lane_name}' uses variant={variant} family={family} "
                f"but deps-{variant}.yaml has no family '{family}'"
            )
            continue
        if os_key not in families[family]:
            ok = False
            print(
                f"   ERROR: {wf.name} lane '{lane_name}' expects deps key {family}.{os_key} "
                f"for variant={variant}, but it is missing in deps-{variant}.yaml"
            )

    if ok:
        print("   OK: ref-valid workflow lanes are covered by deps keys")
    return ok


def load_platform_catalog() -> dict[str, dict]:
    if not PLATFORM_CATALOG_FILE.exists():
        return {}
    data = load_yaml(PLATFORM_CATALOG_FILE)
    platforms = data.get("platforms", {})
    if not isinstance(platforms, dict):
        return {}
    normalized: dict[str, dict] = {}
    for platform_id, entry in platforms.items():
        if isinstance(platform_id, str) and isinstance(entry, dict):
            normalized[platform_id] = entry
    return normalized


def load_platform_deps_bindings() -> dict[str, dict]:
    if not PLATFORM_BINDINGS_FILE.exists():
        return {}
    data = load_yaml(PLATFORM_BINDINGS_FILE)
    profiles = data.get("binding_profiles", {})
    if profiles is None:
        profiles = {}
    if not isinstance(profiles, dict):
        return {}

    bindings = data.get("bindings", {})
    if not isinstance(bindings, dict):
        return {}
    normalized: dict[str, dict] = {}
    normalized_profiles: dict[str, dict] = {}
    for profile_name, profile_entry in profiles.items():
        if isinstance(profile_name, str) and isinstance(profile_entry, dict):
            normalized_profiles[profile_name] = profile_entry

    for platform_id, entry in bindings.items():
        if not isinstance(platform_id, str) or not isinstance(entry, dict):
            continue

        merged: dict = {}
        profile_name = entry.get("profile")
        if profile_name is not None:
            if isinstance(profile_name, str) and profile_name in normalized_profiles:
                merged.update(copy.deepcopy(normalized_profiles[profile_name]))
            else:
                print(
                    f"   ERROR: {PLATFORM_BINDINGS_FILE} binding '{platform_id}' "
                    f"references unknown profile '{profile_name}'"
                )
        for key, value in entry.items():
            if key == "profile":
                continue
            merged[key] = value
        if profile_name is not None:
            merged["profile"] = profile_name
        normalized[platform_id] = merged
    return normalized


def build_docker_image_index(platform_catalog: dict[str, dict]) -> tuple[dict[str, str], dict[str, set[str]]]:
    image_to_platform: dict[str, str] = {}
    duplicate_images: dict[str, set[str]] = {}

    for platform_id, entry in platform_catalog.items():
        runtime = str(entry.get("runtime", "")).strip().lower()
        if runtime != "docker":
            continue
        image_ref = entry.get("image")
        if not isinstance(image_ref, str) or not image_ref.strip():
            continue
        normalized_ref = normalize_container_ref(image_ref)
        current = image_to_platform.get(normalized_ref)
        if current is None:
            image_to_platform[normalized_ref] = platform_id
            continue
        if current != platform_id:
            duplicate_images.setdefault(normalized_ref, {current}).add(platform_id)

    return image_to_platform, duplicate_images


def check_platform_catalog_bindings_consistency(
    platform_catalog: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_catalog:
        print(f"   ERROR: platform catalog missing or invalid: {PLATFORM_CATALOG_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid: {PLATFORM_BINDINGS_FILE}")
        return False

    ok = True
    catalog_ids = set(platform_catalog.keys())
    binding_ids = set(platform_bindings.keys())

    missing_bindings = sorted(catalog_ids - binding_ids)
    extra_bindings = sorted(binding_ids - catalog_ids)

    for platform_id in missing_bindings:
        ok = False
        print(f"   ERROR: platform '{platform_id}' is in catalog but missing from deps bindings")
    for platform_id in extra_bindings:
        ok = False
        print(f"   ERROR: platform '{platform_id}' is in deps bindings but missing from catalog")

    for platform_id, binding in platform_bindings.items():
        family = binding.get("family")
        os_name = binding.get("os")
        if not isinstance(family, str) or not family.strip() or not isinstance(os_name, str) or not os_name.strip():
            ok = False
            print(
                f"   ERROR: deps binding for platform '{platform_id}' "
                "must include non-empty 'family' and 'os'"
            )

    if ok:
        print("   OK: platform catalog and deps bindings are aligned")
    return ok


def check_docker_platforms_map_to_deps(
    variant_index: dict[str, dict[str, set[str]]],
    platform_catalog: dict[str, dict],
    platform_bindings: dict[str, dict],
) -> bool:
    if not platform_catalog:
        print(f"   ERROR: platform catalog missing or invalid: {PLATFORM_CATALOG_FILE}")
        return False
    if not platform_bindings:
        print(f"   ERROR: platform deps bindings missing or invalid: {PLATFORM_BINDINGS_FILE}")
        return False

    ok = True
    found_docker = False
    for platform_id, entry in platform_catalog.items():
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

        family = binding.get("family")
        os_name = binding.get("os")
        version = binding.get("version")

        if not isinstance(family, str) or not isinstance(os_name, str):
            ok = False
            print(
                f"   ERROR: platform '{platform_id}' (runtime=docker) deps binding "
                "missing 'family' or 'os' field"
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
        print("   ERROR: platform catalog has no runtime=docker entries")
        return False

    if ok:
        print("   OK: runtime=docker platform entries map to deps keys")
    return ok


def map_ref_lane_to_platform_requirement(
    workflow_path: Path,
    lane: dict,
) -> tuple[str, str]:
    container = lane.get("container")
    if isinstance(container, str) and container:
        return "docker_image", normalize_container_ref(container)

    if "freebsd_version" in lane or "freebsd" in workflow_path.name:
        version = str(lane.get("freebsd_version", "")).strip()
        return "platform_id", f"freebsd-{version.replace('.', '_')}" if version else ""
    if "netbsd_version" in lane or "netbsd" in workflow_path.name:
        version = str(lane.get("netbsd_version", "")).strip()
        return "platform_id", f"netbsd-{version.replace('.', '_')}" if version else ""
    if "openbsd_version" in lane or "openbsd" in workflow_path.name:
        version = str(lane.get("openbsd_version", "")).strip()
        return "platform_id", f"openbsd-{version.replace('.', '_')}" if version else ""
    if "macos_version" in lane or "macos" in workflow_path.name:
        version = str(lane.get("macos_version", "")).strip()
        if version:
            return "platform_id", f"macos-{version}"
        runner = lane.get("runner")
        if isinstance(runner, str) and runner.strip():
            return "platform_id", runner.strip()
        return "platform_id", ""

    return "unknown", workflow_path.name


def check_ref_workflow_platform_catalog_coverage(platform_catalog: dict[str, dict]) -> bool:
    if not platform_catalog:
        print(f"   ERROR: platform catalog missing or invalid: {PLATFORM_CATALOG_FILE}")
        return False

    image_to_platform, duplicate_images = build_docker_image_index(platform_catalog)
    platform_ids = set(platform_catalog.keys())

    ok = True
    if duplicate_images:
        ok = False
        for image_ref, platform_id_set in sorted(duplicate_images.items()):
            print(
                f"   ERROR: duplicate runtime=docker image '{image_ref}' in platform catalog: "
                f"{', '.join(sorted(platform_id_set))}"
            )

    lanes = iter_ref_validation_lanes()
    if not lanes:
        print("   NOTE: no ref-valid workflow matrix lanes found")
        return True

    for wf, _, lane in lanes:
        lane_name = lane.get("name", "<unnamed>")
        req_type, req_value = map_ref_lane_to_platform_requirement(wf, lane)
        if not req_type:
            ok = False
            print(f"   ERROR: {wf.name} lane '{lane_name}' could not be mapped to platform requirement")
            continue

        if req_type == "docker_image":
            if req_value not in image_to_platform:
                ok = False
                print(
                    f"   ERROR: {wf.name} lane '{lane_name}' requires docker image '{req_value}' "
                    "missing from platform catalog"
                )
            continue

        if req_type == "platform_id":
            platform_id = req_value
            if not platform_id:
                ok = False
                print(f"   ERROR: {wf.name} lane '{lane_name}' could not derive a platform id")
                continue
            if platform_id not in platform_ids:
                ok = False
                print(
                    f"   ERROR: {wf.name} lane '{lane_name}' requires platform '{platform_id}' "
                    "missing from platform catalog"
                )
                continue

            runtime = str(platform_catalog[platform_id].get("runtime", "")).strip().lower()
            if platform_id.startswith(("freebsd-", "netbsd-", "openbsd-")) and runtime != "vm":
                ok = False
                print(
                    f"   ERROR: {wf.name} lane '{lane_name}' expects platform '{platform_id}' "
                    f"to use runtime=vm (found runtime={runtime})"
                )
            if platform_id.startswith("macos-"):
                if runtime != "host":
                    ok = False
                    print(
                        f"   ERROR: {wf.name} lane '{lane_name}' expects platform '{platform_id}' "
                        f"to use runtime=host (found runtime={runtime})"
                    )
                lane_runner = lane.get("runner")
                catalog_runner = platform_catalog[platform_id].get("runner")
                if (
                    isinstance(lane_runner, str)
                    and lane_runner.strip()
                    and isinstance(catalog_runner, str)
                    and catalog_runner.strip()
                    and lane_runner.strip() != catalog_runner.strip()
                ):
                    ok = False
                    print(
                        f"   ERROR: {wf.name} lane '{lane_name}' runner='{lane_runner}' "
                        f"does not match catalog runner='{catalog_runner}' for platform '{platform_id}'"
                    )
            continue

        ok = False
        print(f"   ERROR: {wf.name} lane '{lane_name}' has unknown platform mapping: {(req_type, req_value)}")

    if ok:
        print("   OK: ref-valid workflow lanes are declared in platform catalog")
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


def compose_os_key(os_name: str, version: str | int | None) -> str:
    version_text = "" if version is None else str(version).strip()
    if not version_text:
        return os_name
    return f"{os_name}_{version_text.replace('.', '_')}"


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

        candidate_keys: set[str] = set()
        strict_keys = False

        if mode == "fixed":
            strict_keys = True
            version = version_fixed if isinstance(version_fixed, str) else ""
            if not version and isinstance(version_default, str):
                version = version_default
            candidate_keys.add(compose_os_key(os_name, version))
        elif mode in {"exact_map", "prefix_map"}:
            strict_keys = True
            if versions is None:
                versions = {}
            if not isinstance(versions, dict):
                ok = False
                print(f"   ERROR: normalization rule '{os_id}' versions must be a mapping")
                continue
            for value in versions.values():
                if isinstance(value, (str, int, float)):
                    text = str(value).strip()
                    if text:
                        candidate_keys.add(compose_os_key(os_name, text))
            if isinstance(version_default, str) and version_default.strip():
                candidate_keys.add(compose_os_key(os_name, version_default.strip()))
            if not candidate_keys:
                strict_keys = False
        elif mode in {"major", "dot_to_underscore"}:
            strict_keys = False
        else:
            ok = False
            print(f"   ERROR: normalization rule '{os_id}' has unknown version_mode '{mode}'")
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


def check_shell_scripts() -> bool:
    scripts = [
        ROOT / "cmake-local-setup.sh",
        ROOT / "cmake-local-build.sh",
        ROOT / "cmake-local-install.sh",
        ROOT / "ci" / "deps" / "install-default-packages.sh",
        ROOT / "ci" / "deps" / "install-apt-packages.sh",
        ROOT / "ci" / "deps" / "install-apk-packages.sh",
        ROOT / "ci" / "deps" / "install-bsd-packages.sh",
        ROOT / "ci" / "deps" / "install-brew-packages.sh",
        ROOT / "ci" / "deps" / "install-pkg-packages.sh",
        ROOT / "ci" / "deps" / "install-pkg-add-packages.sh",
        ROOT / "ci" / "deps" / "install-pkgin-packages.sh",
        ROOT / "ci" / "deps" / "install-dnf-packages.sh",
        ROOT / "ci" / "deps" / "install-pacman-packages.sh",
        ROOT / "ci" / "deps" / "install-yum-packages.sh",
        ROOT / "ci" / "deps" / "install-zypper-packages.sh",
        ROOT / "ci" / "deps" / "lib" / "install-common.sh",
        ROOT / "ci" / "deps" / "lib" / "install-bsd-common.sh",
    ]
    existing = [str(path) for path in scripts if path.exists()]
    if not existing:
        print("   NOTE: no shell scripts found for linting")
        return True

    try:
        subprocess.run(
            ["shellcheck", "--version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print("   NOTE: shellcheck not installed; skipping shell lint")
        return True

    cmd = ["shellcheck", "--external-sources", "--shell", "bash"] + existing
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("   ERROR: shellcheck reported issues")
        return False
    return True


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

    topology_name: str | None = None
    bindings_name: str | None = None
    version_notes_name: str | None = None
    for path in FILES:
        variant_data = load_yaml(path)
        variant_topology = variant_data.get("topology", DEFAULT_TOPOLOGY_FILE.name)
        variant_bindings = variant_data.get("bindings_file", DEFAULT_BINDINGS_FILE.name)
        variant_version_notes = variant_data.get("version_notes_file", DEFAULT_VERSION_NOTES_FILE.name)
        require(
            isinstance(variant_topology, str) and variant_topology.strip(),
            f"{path} topology must be a non-empty string when provided",
        )
        require(
            isinstance(variant_bindings, str) and variant_bindings.strip(),
            f"{path} bindings_file must be a non-empty string when provided",
        )
        require(
            isinstance(variant_version_notes, str) and variant_version_notes.strip(),
            f"{path} version_notes_file must be a non-empty string when provided",
        )
        if topology_name is None:
            topology_name = variant_topology
        else:
            require(
                variant_topology == topology_name,
                f"{path} topology '{variant_topology}' does not match '{topology_name}' used by other variants",
            )
        if bindings_name is None:
            bindings_name = variant_bindings
        else:
            require(
                variant_bindings == bindings_name,
                f"{path} bindings_file '{variant_bindings}' does not match '{bindings_name}' used by other variants",
            )
        if version_notes_name is None:
            version_notes_name = variant_version_notes
        else:
            require(
                variant_version_notes == version_notes_name,
                f"{path} version_notes_file '{variant_version_notes}' does not match '{version_notes_name}' used by other variants",
            )

    assert topology_name is not None
    assert bindings_name is not None
    assert version_notes_name is not None
    topology_file = DATA_DIR / topology_name
    bindings_file = DATA_DIR / bindings_name
    version_notes_file = DATA_DIR / version_notes_name
    topology = load_topology(topology_file)
    normalization_rules = load_platform_normalization_rules()
    shared_bindings = load_shared_bindings(bindings_file)
    shared_version_notes = load_shared_version_notes(version_notes_file)
    for path in FILES:
        check_file(
            path,
            topology,
            topology_file,
            shared_bindings,
            bindings_file,
            shared_version_notes,
            version_notes_file,
        )

    print("deps YAML structure OK")

    client = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-client.yaml"),
        DATA_DIR / "deps-client.yaml",
        topology,
        topology_file,
        shared_bindings,
        bindings_file,
        shared_version_notes,
        version_notes_file,
    )
    localclient = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-localclient.yaml"),
        DATA_DIR / "deps-localclient.yaml",
        topology,
        topology_file,
        shared_bindings,
        bindings_file,
        shared_version_notes,
        version_notes_file,
    )
    server = expand_variant_profiles(
        load_yaml(DATA_DIR / "deps-server.yaml"),
        DATA_DIR / "deps-server.yaml",
        topology,
        topology_file,
        shared_bindings,
        bindings_file,
        shared_version_notes,
        version_notes_file,
    )
    dep_map = load_deps_map()
    variant_index = {
        "client": build_family_os_index(client),
        "localclient": build_family_os_index(localclient),
        "server": build_family_os_index(server),
    }
    platform_catalog = load_platform_catalog()
    platform_bindings = load_platform_deps_bindings()

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
        str(entry.get("os")).strip()
        for entry in platform_bindings.values()
        if isinstance(entry, dict) and isinstance(entry.get("os"), str) and str(entry.get("os")).strip()
    }
    required_flags_cache: dict[Path, set[str]] = {}
    workflow_files = list((ROOT / ".github" / "workflows").glob("*.yml"))
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
                            "for current platform bindings"
                        )

    print("-- platforms: catalog/bindings consistency")
    if not check_platform_catalog_bindings_consistency(platform_catalog, platform_bindings):
        ok = False

    print("-- workflows: ref-valid deps coverage")
    if not check_ref_workflow_deps_coverage(variant_index, platform_catalog, platform_bindings):
        ok = False

    print("-- platforms: catalog coverage for ref-valid lanes")
    if not check_ref_workflow_platform_catalog_coverage(platform_catalog):
        ok = False

    print("-- platforms: runtime=docker entries -> deps coverage")
    if not check_docker_platforms_map_to_deps(variant_index, platform_catalog, platform_bindings):
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
    yaml_ok &= check_packages_from_yaml_mapping(server, "server")
    if not yaml_ok:
        ok = False

    print("-- shellcheck: local + CI helpers")
    if not check_shell_scripts():
        ok = False

    if not ok:
        return 1

    print("deps content + CMake + runtime + workflow checks OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
