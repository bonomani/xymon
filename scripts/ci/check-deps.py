#!/usr/bin/env python3
"""Sanity-check packaging deps YAML structure."""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except Exception as exc:  # pragma: no cover
    print(f"Failed to import PyYAML: {exc}")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[2]
FILES = [
    ROOT / "packaging" / "deps-client.yaml",
    ROOT / "packaging" / "deps-server.yaml",
]


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
    require("linux_github" in build, f"{path} missing build.linux_github")
    require("bsd" in build, f"{path} missing build.bsd")

    # Build: linux
    linux = build["linux_github"]
    require("ubuntu_latest" in linux, f"{path} missing build.linux_github.ubuntu_latest")
    ubuntu = linux["ubuntu_latest"]
    require("packagers" in ubuntu, f"{path} missing build.linux_github.ubuntu_latest.packagers")
    for pkg_name, pkg in ubuntu["packagers"].items():
        require("libs" in pkg, f"{path} missing libs for linux_github.ubuntu_latest.packagers.{pkg_name}")
        require(
            "mandatory" in pkg["libs"],
            f"{path} missing libs.mandatory for linux_github.ubuntu_latest.packagers.{pkg_name}",
        )

    # Build: BSD
    bsd = build["bsd"]
    for os_name in ("freebsd", "netbsd", "openbsd"):
        require(os_name in bsd, f"{path} missing build.bsd.{os_name}")
        os_entry = bsd[os_name]
        require("packagers" in os_entry, f"{path} missing build.bsd.{os_name}.packagers")
        for pkg_name, pkg in os_entry["packagers"].items():
            require("libs" in pkg, f"{path} missing libs for bsd.{os_name}.packagers.{pkg_name}")
            require(
                "mandatory" in pkg["libs"],
                f"{path} missing libs.mandatory for bsd.{os_name}.packagers.{pkg_name}",
            )

    # Runtime
    runtime = data["runtime"]
    require("libs" in runtime, f"{path} missing runtime.libs")
    require("tools" in runtime, f"{path} missing runtime.tools")

    # Optional metadata
    if "version_notes" in data:
        notes = data["version_notes"]
        require("linux" in notes, f"{path} missing version_notes.linux")
        require("bsd" in notes, f"{path} missing version_notes.bsd")


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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
