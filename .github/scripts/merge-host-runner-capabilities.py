#!/usr/bin/env python3
"""Merge per-runner probe JSON files into a YAML catalog."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import yaml


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
        runners[label] = payload
    output_yaml.parent.mkdir(parents=True, exist_ok=True)
    output_yaml.write_text(
        yaml.safe_dump({"runners": runners}, sort_keys=False),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
