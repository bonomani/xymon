#!/usr/bin/env python3
"""Emit package list from ci/deps/data/deps-*.yaml and deps-map.yaml.

Usage:
  packages-from-yaml.py --variant server|client --family FAMILY --os OS --pkgmgr PKG [--enable-ldap ON|OFF] [--enable-snmp ON|OFF]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except Exception as exc:  # pragma: no cover
    print(f"Failed to import PyYAML: {exc}", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[2]


def load_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"Unexpected YAML root for {path}")
    return data


def normalize_onoff(val: str | None, default: str) -> str:
    if val is None:
        return default
    val = val.strip().upper()
    if val in {"ON", "YES", "Y", "TRUE", "1"}:
        return "ON"
    if val in {"OFF", "NO", "N", "FALSE", "0"}:
        return "OFF"
    return val


def resolve_packages(items: list[str], dep_map: dict, family: str, os_name: str, pkgmgr: str) -> list[str]:
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
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", required=True, choices=("server", "client"))
    parser.add_argument("--family", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--pkgmgr", required=True)
    parser.add_argument("--enable-ldap")
    parser.add_argument("--enable-snmp")
    args = parser.parse_args()

    enable_ldap = normalize_onoff(args.enable_ldap, "OFF")
    enable_snmp = normalize_onoff(args.enable_snmp, "OFF")

    deps_dir = ROOT / "ci" / "deps" / "data"
    deps_file = deps_dir / f"deps-{args.variant}.yaml"
    dep_map_file = deps_dir / "deps-map.yaml"
    data = load_yaml(deps_file)
    dep_map = load_yaml(dep_map_file) if dep_map_file.exists() else {}

    try:
        pkg_block = (
            data["build"][args.family][args.os]["packagers"][args.pkgmgr]["libs"]["mandatory"]
        )
    except Exception as exc:
        print(f"Failed to locate package list: {exc}", file=sys.stderr)
        return 1

    items = list(pkg_block or [])

    if args.variant == "server":
        if enable_ldap == "OFF":
            items = [item for item in items if item != "LDAP"]
        if enable_snmp == "OFF":
            items = [item for item in items if item != "NETSNMP"]
    if args.family == "bsd":
        # LDAP is resolved separately for BSD to handle pkg_add ambiguity.
        items = [item for item in items if item != "LDAP"]

    resolved = resolve_packages(items, dep_map, args.family, args.os, args.pkgmgr)
    for pkg in resolved:
        print(pkg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
