#!/usr/bin/env python3

import json
from pathlib import Path


DEFAULT_RUNTIME_MODEL_PATH = Path(__file__).with_name("runtime-model.json")


def _die(message: str) -> None:
    raise SystemExit(message)


def _require_mapping(value, context: str):
    if not isinstance(value, dict):
        _die(f"{context} must be a mapping")
    return value


def _require_non_empty_string(value, context: str) -> str:
    if not isinstance(value, str) or not value:
        _die(f"{context} must be a non-empty string")
    return value


def load_runtime_model(path: Path | None = None):
    model_path = path or DEFAULT_RUNTIME_MODEL_PATH
    if not model_path.exists():
        _die(f"Missing runtime model: {model_path}")

    data = json.loads(model_path.read_text(encoding="utf-8"))
    data = _require_mapping(data, f"Runtime model root in {model_path}")

    entries = data.get("runtimes")
    if not isinstance(entries, list) or not entries:
        _die(f"Runtime model has no 'runtimes' list: {model_path}")

    ordered_keys = []
    platform_runtime_by_key = {}
    execution_by_key = {}
    outcome_channel_by_key = {}
    default_ref_os_by_key = {}
    requires_runs_on_by_key = {}

    seen = set()
    for index, raw in enumerate(entries):
        entry = _require_mapping(raw, f"Runtime model entry #{index}")
        key = _require_non_empty_string(entry.get("key"), f"Runtime entry #{index}.key")
        if key in seen:
            _die(f"Duplicate runtime key in model: {key}")
        seen.add(key)

        platform_runtime = _require_non_empty_string(
            entry.get("platform_runtime"),
            f"Runtime entry {key}.platform_runtime",
        )
        execution = _require_non_empty_string(
            entry.get("execution"),
            f"Runtime entry {key}.execution",
        )
        outcome_channel = _require_non_empty_string(
            entry.get("outcome_channel"),
            f"Runtime entry {key}.outcome_channel",
        )
        default_ref_os = _require_non_empty_string(
            entry.get("default_ref_os"),
            f"Runtime entry {key}.default_ref_os",
        )
        if default_ref_os not in {"linux", "macos", "family"}:
            _die(
                f"Runtime entry {key}.default_ref_os must be one of "
                "'linux', 'macos', or 'family'"
            )
        requires_runs_on = entry.get("requires_runs_on")
        if not isinstance(requires_runs_on, bool):
            _die(f"Runtime entry {key}.requires_runs_on must be a boolean")

        ordered_keys.append(key)
        platform_runtime_by_key[key] = platform_runtime
        execution_by_key[key] = execution
        outcome_channel_by_key[key] = outcome_channel
        default_ref_os_by_key[key] = default_ref_os
        requires_runs_on_by_key[key] = requires_runs_on

    return {
        "ordered_keys": ordered_keys,
        "platform_runtime_by_key": platform_runtime_by_key,
        "execution_by_key": execution_by_key,
        "outcome_channel_by_key": outcome_channel_by_key,
        "default_ref_os_by_key": default_ref_os_by_key,
        "requires_runs_on_by_key": requires_runs_on_by_key,
    }
