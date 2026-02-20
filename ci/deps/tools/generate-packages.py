#!/usr/bin/env python3
"""Generate shell tables from ci/deps/data YAML for pure POSIX resolution."""

from __future__ import annotations

import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT / "ci" / "deps" / "data"
OUTPUT = ROOT / "ci" / "deps" / "generated-packages.sh"


def load_yaml(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def flatten_packages(variant: str, path: Path) -> dict[str, list[str]]:
    data = load_yaml(path)
    results: dict[str, list[str]] = {}
    for family, family_entry in data.get("build", {}).items():
        if not isinstance(family_entry, dict):
            continue
        for os_name, os_entry in family_entry.items():
            packagers = os_entry.get("packagers", {})
            for pkgmgr, pkg_entry in packagers.items():
                libs = pkg_entry.get("libs", {}).get("mandatory", [])
                key = f"{variant}:{family}:{os_name}:{pkgmgr}"
                results[key] = list(libs or [])
    return results


def flatten_map() -> dict[str, list[str]]:
    data = load_yaml(DATA_DIR / "deps-map.yaml").get("map", {})
    results: dict[str, list[str]] = {}
    for dep, families in data.items():
        if not isinstance(families, dict):
            continue
        for family, os_map in families.items():
            if not isinstance(os_map, dict):
                continue
            for os_name, pkgmgr_map in os_map.items():
                if not isinstance(pkgmgr_map, dict):
                    continue
                for pkgmgr, pkg_list in pkgmgr_map.items():
                    key = f"{dep}:{family}:{os_name}:{pkgmgr}"
                    results[key] = list(pkg_list or [])
    return results


def flatten_aliases() -> dict[str, str]:
    data = load_yaml(DATA_DIR / "deps-map.yaml").get("aliases", {})
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


def line(items: list[str]) -> str:
    return " ".join(items)


def generate():
    raw = {}
    raw.update(flatten_packages("client", DATA_DIR / "deps-client.yaml"))
    raw.update(flatten_packages("server", DATA_DIR / "deps-server.yaml"))
    mapping = flatten_map()
    aliases = flatten_aliases()

    with OUTPUT.open("w") as fh:
        fh.write("#!/usr/bin/env bash\n")
        fh.write("# Generated file: do not edit directly. Run ci/deps/tools/generate-packages.py\n\n")
        fh.write("declare -A ci_deps_raw_packages\n")
        for key, deps in sorted(raw.items()):
            fh.write(f"ci_deps_raw_packages[{json.dumps(key)}]={json.dumps(line(deps))}\n")
        fh.write("\n")
        fh.write("declare -A ci_deps_map\n")
        for key, pkgs in sorted(mapping.items()):
            fh.write(f"ci_deps_map[{json.dumps(key)}]={json.dumps(line(pkgs))}\n")
        fh.write("\n")
        fh.write("declare -A ci_deps_aliases\n")
        for alias, target in sorted(aliases.items()):
            fh.write(f"ci_deps_aliases[{json.dumps(alias)}]={json.dumps(target)}\n")


if __name__ == "__main__":
    generate()
