#!/usr/bin/env python3
"""Probe host-runner execution capabilities and emit JSON."""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def run_command(*argv: str) -> tuple[bool, str]:
    path = shutil.which(argv[0])
    if not path:
        return False, ""
    try:
        completed = subprocess.run(
            [path, *argv[1:]],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return True, ""
    return True, completed.stdout.strip()


def read_text(path: str) -> str | None:
    try:
        value = Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def detect_nested_virtualization() -> str:
    for candidate in (
        "/sys/module/kvm_intel/parameters/nested",
        "/sys/module/kvm_amd/parameters/nested",
    ):
        value = read_text(candidate)
        if value is None:
            continue
        lowered = value.lower()
        if lowered in {"1", "y", "yes"}:
            return "enabled"
        if lowered in {"0", "n", "no"}:
            return "disabled"
        return lowered
    return "unknown"


def tool_record(name: str, *version_argv: str) -> dict[str, object]:
    present, output = run_command(*version_argv)
    return {
        "present": present,
        **({"version": output.splitlines()[0]} if output else {}),
        "path": shutil.which(name) or "",
    }


def main() -> None:
    runner_label = os.environ.get("RUNNER_LABEL", "").strip()
    payload = {
        "runner_label": runner_label,
        "probed_at": datetime.now(timezone.utc).isoformat(),
        "system": {
            "platform": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "tools": {
            "docker": tool_record("docker", "docker", "version", "--format", "{{.Server.Version}}"),
            "podman": tool_record("podman", "podman", "--version"),
            "qemu-system-x86_64": tool_record("qemu-system-x86_64", "qemu-system-x86_64", "--version"),
            "qemu-aarch64-static": tool_record("qemu-aarch64-static", "qemu-aarch64-static", "--version"),
        },
        "container": {
            "binfmt_misc_mounted": Path("/proc/sys/fs/binfmt_misc").exists(),
            "docker_socket": Path("/var/run/docker.sock").exists(),
        },
        "virtualization": {
            "dev_kvm_exists": Path("/dev/kvm").exists(),
            "dev_kvm_readable": os.access("/dev/kvm", os.R_OK),
            "dev_kvm_writable": os.access("/dev/kvm", os.W_OK),
            "nested": detect_nested_virtualization(),
        },
    }
    json.dump(payload, fp=os.sys.stdout, indent=2, sort_keys=True)
    os.sys.stdout.write("\n")


if __name__ == "__main__":
    main()
