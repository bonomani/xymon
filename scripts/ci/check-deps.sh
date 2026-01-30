#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "== deps: structure =="
python3 "${root_dir}/scripts/ci/check-deps.py"

echo "== deps: content checks =="
python3 - <<'PY'
from __future__ import annotations
import re
import subprocess
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[2]

client = yaml.safe_load((ROOT / "packaging" / "deps-client.yaml").read_text())
server = yaml.safe_load((ROOT / "packaging" / "deps-server.yaml").read_text())

# --- helpers ---

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


def scan_runtime_tools() -> set[str]:
    patterns = {
        "sendmail": re.compile(r"\bsendmail\b"),
        "fping": re.compile(r"\bfping\b"),
        "perl": re.compile(r"\bperl\b"),
        "python": re.compile(r"\bpython\b"),
    }
    found = set()
    for path in ROOT.rglob("*.sh"):
        text = path.read_text(errors="ignore")
        for key, pat in patterns.items():
            if pat.search(text):
                found.add(key)
    return found

# --- schema completeness ---
print("-- schema: completeness")
for name, data in ("client", client), ("server", server):
    for family, family_entry in data["build"].items():
        for os_name, os_entry in family_entry.items():
            packagers = os_entry.get("packagers", {})
            for pkg_name, pkg in packagers.items():
                if "libs" not in pkg or "tools" not in pkg:
                    print(f"   ERROR: {name} missing libs/tools for {family}.{os_name}.{pkg_name}")
                    raise SystemExit(1)
                if "mandatory" not in pkg["libs"]:
                    print(f"   ERROR: {name} missing libs.mandatory for {family}.{os_name}.{pkg_name}")
                    raise SystemExit(1)
                # tools.mandatory can be omitted (treated as empty)
    if "libs" not in data.get("runtime", {}) or "tools" not in data.get("runtime", {}):
        print(f"   ERROR: {name} missing runtime.libs/tools")
        raise SystemExit(1)
    print(f"   OK: {name} schema")

# --- build: compare against package scripts (all families) ---
ok = True
for family, family_entry in client["build"].items():
    for os_name, os_entry in family_entry.items():
        for pkg_name, pkg in os_entry.get("packagers", {}).items():
            label = f"build {family} {os_name} {pkg_name}"
            actual_client = pkg["libs"]["mandatory"]
            actual_server = (
                server["build"][family][os_name]["packagers"][pkg_name]["libs"]["mandatory"]
                if family in server["build"] and os_name in server["build"][family]
                else []
            )

            if family == "linux_github" and pkg_name == "apt":
                exp_client = bash_list(
                    f"cd '{ROOT}'; source scripts/ci/packages-linux.sh; ci_linux_packages linux_github ubuntu latest client OFF '' OFF"
                )
                exp_server = bash_list(
                    f"cd '{ROOT}'; source scripts/ci/packages-linux.sh; ci_linux_packages linux_github ubuntu latest server ON '' ON"
                )
                ok &= diff(f"{label} client mandatory", exp_client, actual_client)
                ok &= diff(f"{label} server mandatory", exp_server, actual_server)
            elif family == "bsd":
                exp_client = bash_list(
                    f"cd '{ROOT}'; source scripts/ci/packages-bsd.sh; ci_bsd_packages {pkg_name} client OFF"
                )
                exp_server = bash_list(
                    f"cd '{ROOT}'; source scripts/ci/packages-bsd.sh; ci_bsd_packages {pkg_name} server ON"
                )
                # install-bsd-packages.sh adds LDAP client packages when ENABLE_LDAP=ON for server
                if "openldap-client" not in exp_server:
                    exp_server = exp_server + ["openldap-client"]
                ok &= diff(f"{label} client mandatory", exp_client, actual_client)
                ok &= diff(f"{label} server mandatory", exp_server, actual_server)
            else:
                print(f"-- NOTE: build: no package-script expectations for {label}")

# --- parse CMakeLists to validate linked libs ---
print("-- build: CMake linkage checks")
linux_client = client["build"]["linux_github"]["ubuntu_latest"]["packagers"]["apt"]["libs"]["mandatory"]
linux_server = server["build"]["linux_github"]["ubuntu_latest"]["packagers"]["apt"]["libs"]["mandatory"]
client_cmake = (ROOT / "client" / "CMakeLists.txt").read_text()
if re.search(r"\bssl\b", client_cmake) or re.search(r"\bcrypto\b", client_cmake):
    if "libssl-dev" not in linux_client:
        ok = False
        print("   ERROR: linux client missing libssl-dev (client links ssl/crypto)")
    else:
        print("   OK: linux client libssl-dev present")

for os_name, mgr in (("freebsd", "pkg"), ("netbsd", "pkgin"), ("openbsd", "pkg_add")):
    pkg = client["build"]["bsd"][os_name]["packagers"][mgr]["libs"]
    if "openssl" in set(pkg.get("mandatory", [])):
        print(f"   OK: {os_name} client openssl present (mandatory)")
    elif "openssl" in set(pkg.get("base_system", [])):
        print(f"   OK: {os_name} client openssl present (base_system)")
    else:
        print(f"   NOTE: {os_name} client openssl not listed")

xymonnet_cmake = (ROOT / "xymonnet" / "CMakeLists.txt").read_text()
if re.search(r"LDAP_LIBRARY", xymonnet_cmake):
    if "libldap-dev" not in linux_server:
        ok = False
        print("   ERROR: linux server missing libldap-dev (LDAP linked by xymonnet)")
    else:
        print("   OK: linux server libldap-dev present")
if re.search(r"NETSNMP", xymonnet_cmake):
    if "net-snmp" not in linux_server:
        print("   NOTE: linux server net-snmp not listed (SNMP optional; xymonnet skips if not found)")
    else:
        print("   OK: linux server net-snmp present")
if re.search(r"TIRPC", xymonnet_cmake):
    if "libtirpc-dev" not in linux_server:
        ok = False
        print("   ERROR: linux server missing libtirpc-dev (tirpc linked by xymonnet)")
    else:
        print("   OK: linux server libtirpc-dev present")

# --- runtime tools checks ---
print("-- runtime: tools checks")
used_tools = scan_runtime_tools()
runtime_tools = set(client["runtime"]["tools"]["mandatory"])

def covered(tool: str) -> bool:
    if tool in runtime_tools:
        return True
    if tool == "sendmail":
        return any(entry.startswith("sendmail") for entry in runtime_tools)
    return False

missing_tools = sorted(tool for tool in used_tools if not covered(tool))
if missing_tools:
    ok = False
    print(f"   ERROR: runtime.tools.mandatory missing: {', '.join(missing_tools)}")
else:
    print("   OK: runtime tools cover script usage")

# --- workflow checks ---
print("-- workflows: install checks")
workflow_files = list((ROOT / ".github" / "workflows").glob("*.yml"))
for wf in workflow_files:
    text = wf.read_text()
    if "install-linux-packages.sh" in text:
        if "--distro-family linux_github" not in text:
            ok = False
            print(f"   ERROR: {wf} uses install-linux-packages.sh without --distro-family linux_github")
        else:
            print(f"   OK: {wf} uses linux_github")

if not ok:
    raise SystemExit(1)

print("deps content + CMake + runtime + workflow checks OK")
PY
