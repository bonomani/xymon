#!/usr/bin/env python3
"""Sanity-check packaging deps YAML structure and content."""
from __future__ import annotations

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
META_FILE = DATA_DIR / "deps-meta.yaml"


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


def check_file(path: Path) -> None:
    data = load_yaml(path)
    require("build" in data, f"{path} missing build section")
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
                    "mandatory" in pkg["libs"],
                    f"{path} missing libs.mandatory for build.{family}.{os_name}.packagers.{pkg_name}",
                )

    # Runtime
    runtime = data["runtime"]
    require("libs" in runtime, f"{path} missing runtime.libs")
    require("tools" in runtime, f"{path} missing runtime.tools")

    # Optional metadata
    if "version_notes" in data:
        require(isinstance(data["version_notes"], dict), f"{path} version_notes must be a mapping")


def bash_list(cmd: str) -> list[str]:
    out = subprocess.check_output(["bash", "-lc", cmd], text=True)
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


def find_install_steps(workflow: dict) -> list[str]:
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
            if isinstance(run, str) and "install-gh-debian-packages.sh" in run:
                hits.append(run)
    return hits


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


def parse_linux_families() -> set[str]:
    data = load_yaml(DATA_DIR / "deps-client.yaml")
    families = set(data.get("build", {}).keys())
    families.discard("bsd")
    return families


def parse_bsd_pkgmgrs() -> dict[str, str]:
    script = (ROOT / "ci" / "deps" / "install-bsd-packages.sh").read_text()
    mapping: dict[str, str] = {}
    in_case = False
    for line in script.splitlines():
        stripped = line.strip()
        if stripped.startswith("case \"${OS_NAME}\""):
            in_case = True
            continue
        if in_case and stripped.startswith("esac"):
            break
        if in_case and stripped.endswith(") PKG_MGR=\"pkg\" ;;"):
            os_name = stripped.split(")")[0].strip()
            mapping[os_name] = "pkg"
        if in_case and stripped.endswith(") PKG_MGR=\"pkg_add\" ;;"):
            os_name = stripped.split(")")[0].strip()
            mapping[os_name] = "pkg_add"
    return mapping


def parse_bsd_pkgmgr_keys() -> set[str]:
    return {"pkg", "pkgin", "pkg_add"}


def parse_ldap_pkg_name() -> str | None:
    script = (ROOT / "ci" / "deps" / "install-bsd-packages.sh").read_text()
    match = re.search(r"openldap-client", script)
    if match:
        return "openldap-client"
    return None


def check_shell_scripts() -> bool:
    scripts = [
        ROOT / "cmake-local-setup.sh",
        ROOT / "cmake-local-build.sh",
        ROOT / "cmake-local-install.sh",
        ROOT / "ci" / "deps" / "install-bsd-packages.sh",
        ROOT / "ci" / "deps" / "install-debian-packages.sh",
        ROOT / "ci" / "deps" / "install-gh-debian-packages.sh",
        ROOT / "ci" / "deps" / "packages-bsd.sh",
        ROOT / "ci" / "deps" / "packages-debian.sh",
        ROOT / "ci" / "deps" / "packages-gh-debian.sh",
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


def load_deps_meta() -> dict:
    if not META_FILE.exists():
        return {}
    data = load_yaml(META_FILE)
    if not isinstance(data, dict):
        return {}
    return data


def resolve_packages(
    items: list[str],
    dep_map: dict,
    family: str,
    os_name: str,
    pkgmgr: str,
) -> list[str]:
    resolved: list[str] = []
    map_block = dep_map.get("map", {})
    for item in items:
        mapped = map_block.get(item, {})
        if isinstance(mapped, dict):
            family_entry = mapped.get(family, {})
            if isinstance(family_entry, dict):
                os_entry = family_entry.get(os_name, {})
                if isinstance(os_entry, dict):
                    pkg_list = os_entry.get(pkgmgr, [])
                    if pkg_list:
                        resolved.extend(pkg_list)
                        continue
        resolved.append(item)
    return resolved


def main() -> int:
    missing = [p for p in FILES if not p.exists()]
    if missing:
        print("Missing required files:")
        for p in missing:
            print(f"  - {p}")
        return 2

    for path in FILES:
        check_file(path)

    print("deps YAML structure OK")

    client = load_yaml(DATA_DIR / "deps-client.yaml")
    server = load_yaml(DATA_DIR / "deps-server.yaml")
    dep_map = load_deps_map()
    dep_meta = load_deps_meta()

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
    ok = True
    linux_families = parse_linux_families()
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
                actual_client = resolve_packages(actual_client_raw, dep_map, family, os_name, pkg_name)
                actual_server = resolve_packages(actual_server_raw, dep_map, family, os_name, pkg_name)

                if family in linux_families:
                    pkg_script = "packages-debian.sh" if family == "debian" else "packages-gh-debian.sh"
                    distro = os_name.split("_", 1)[0]
                    version = os_name.split("_", 1)[1] if "_" in os_name else ""
                    expected_sets = []
                    for enable_ldap in ("ON", "OFF"):
                        for enable_snmp in ("ON", "OFF"):
                            exp_client = bash_list(
                                f"cd '{ROOT}'; source ci/deps/{pkg_script}; "
                                f"ci_linux_packages {family} {distro} {version} client "
                                f"{enable_ldap} '' {enable_snmp}"
                            )
                            exp_server = bash_list(
                                f"cd '{ROOT}'; source ci/deps/{pkg_script}; "
                                f"ci_linux_packages {family} {distro} {version} server "
                                f"{enable_ldap} '' {enable_snmp}"
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
                    for enable_snmp in ("ON", "OFF"):
                        exp_client = bash_list(
                        f"cd '{ROOT}'; source ci/deps/packages-bsd.sh; "
                            f"ci_bsd_packages {pkg_name} client {enable_snmp} {os_name}"
                        )
                        exp_server = bash_list(
                        f"cd '{ROOT}'; source ci/deps/packages-bsd.sh; "
                            f"ci_bsd_packages {pkg_name} server {enable_snmp} {os_name}"
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
                linux_client = resolve_packages(pkg["libs"]["mandatory"], dep_map, family, os_name, pkg_name)
                linux_server = resolve_packages(
                    server["build"][family][os_name]["packagers"][pkg_name]["libs"]["mandatory"],
                    dep_map,
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
    workflow_files = list((ROOT / ".github" / "workflows").glob("*.yml"))
    for wf in workflow_files:
        data = parse_workflow_yaml(wf)
        run_snippets = find_package_steps(data)
        if not run_snippets:
            continue
        text = wf.read_text()
        # Validate args/envs based on the referenced package script usage.
        for snippet in run_snippets:
            match = re.search(r"(ci/deps/[^\\s]+packages[^\\s]+\\.sh)", snippet)
            if not match:
                continue
            script_path = ROOT / match.group(1)
            if not script_path.exists():
                continue
            script_meta = dep_meta.get("scripts", {}).get(match.group(1), {})
            required_flags = script_meta.get("requires_flags", [])
            required_env = script_meta.get("requires_env", [])
            accepts = script_meta.get("accepts", {})

            for flag in required_flags:
                if flag not in text:
                    ok = False
                    print(f"   ERROR: {wf} runs {script_path.name} without {flag}")
            for env_key in required_env:
                if env_key not in text:
                    ok = False
                    print(f"   ERROR: {wf} runs {script_path.name} without {env_key} in env")

            if "--distro-family" in required_flags:
                family_match = re.search(r"--distro-family\\s+(\\S+)", text)
                if family_match:
                    family = family_match.group(1)
                    allowed = set(accepts.get("family", []))
                    if allowed and family not in allowed:
                        ok = False
                        print(f"   ERROR: {wf} uses unsupported distro-family '{family}'")
                    elif family not in client["build"]:
                        ok = False
                        print(f"   ERROR: {wf} uses distro-family '{family}' not present in YAML")
                    else:
                        print(f"   OK: {wf} uses known distro-family '{family}'")

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
        print(f"   ERROR: BSD packagers not supported by packages-bsd.sh: {', '.join(unknown_bsd)}")
    else:
        print("   OK: BSD packager keys align with packages-bsd.sh")

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
