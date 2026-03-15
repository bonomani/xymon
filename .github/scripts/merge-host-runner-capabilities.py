#!/usr/bin/env python3
"""Merge per-runner probe JSON files into a YAML catalog."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import yaml


def normalize_capabilities(payload: dict[str, Any]) -> dict[str, Any]:
    container = payload.get("container", {})
    virtualization = payload.get("virtualization", {})
    tools = payload.get("tools", {})

    def tool_present(name: str) -> bool:
        entry = tools.get(name, {})
        return isinstance(entry, dict) and bool(entry.get("present"))

    dev_kvm_exists = bool(virtualization.get("dev_kvm_exists"))
    dev_kvm_readable = bool(virtualization.get("dev_kvm_readable"))
    dev_kvm_writable = bool(virtualization.get("dev_kvm_writable"))
    nested_state = str(virtualization.get("nested", "")).strip().lower() or "unknown"

    return {
        "container_runtime_available": bool(container.get("docker_socket")),
        "binfmt_misc_available": bool(container.get("binfmt_misc_mounted")),
        "container_tooling": {
            "docker": tool_present("docker"),
            "podman": tool_present("podman"),
        },
        "emulation_tooling": {
            "qemu_system_x86_64": tool_present("qemu-system-x86_64"),
            "qemu_aarch64_static": tool_present("qemu-aarch64-static"),
        },
        "virtualization": {
            "kvm_device_present": dev_kvm_exists,
            "kvm_accessible": dev_kvm_exists and dev_kvm_readable and dev_kvm_writable,
            "nested_state": nested_state,
            "nested_enabled": nested_state == "enabled",
        },
    }


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: merge-host-runner-capabilities.py <input-dir> <output-yaml>")
    input_dir = Path(sys.argv[1])
    output_yaml = Path(sys.argv[2])
    runners: dict[str, dict[str, Any]] = {}
    for path in sorted(input_dir.glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        label = str(payload.get("runner_label", "")).strip()
        if not label:
            raise SystemExit(f"missing runner_label in {path}")
        payload["capabilities"] = normalize_capabilities(payload)
        runners[label] = payload
    output_yaml.parent.mkdir(parents=True, exist_ok=True)
    output_yaml.write_text(
        yaml.safe_dump({"runners": runners}, sort_keys=False),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
