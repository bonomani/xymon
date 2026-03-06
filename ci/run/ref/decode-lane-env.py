#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Decode lane_env_json into normalized GITHUB_OUTPUT fields"
    )
    parser.add_argument("--lane-env-json", required=True)
    parser.add_argument(
        "--profile",
        required=True,
        choices=["lane_meta", "lane_post"],
        help="Output profile to produce",
    )
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT", ""),
        help="Path to GITHUB_OUTPUT file. If empty, print to stdout.",
    )
    return parser.parse_args()


def as_text(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def require_key(payload: dict[str, object], key: str) -> str:
    value = as_text(payload.get(key, ""))
    if not value:
        fail(f"lane_env_json missing required key: {key}")
    return value


def build_lane_meta_outputs(payload: dict[str, object]) -> dict[str, str]:
    required = [
        "RUNTIME_EXECUTION",
        "ALLOW_FAILURE_MODE",
        "LANE_ALLOW_FAILURE",
        "REF_OS",
        "RUNTIME",
        "RUNTIME_OUTCOME_CHANNEL",
    ]
    values = {key: require_key(payload, key) for key in required}

    continue_on_error = (
        "true"
        if values["ALLOW_FAILURE_MODE"] != "off"
        and values["LANE_ALLOW_FAILURE"] == "1"
        else "false"
    )

    return {
        "runtime_execution": values["RUNTIME_EXECUTION"],
        "continue_on_error": continue_on_error,
        "ref_os": values["REF_OS"],
        "architecture": as_text(payload.get("ARCHITECTURE", "")),
        "os_version": as_text(payload.get("OS_VERSION", "")),
        "vm_memory": as_text(payload.get("VM_MEMORY", "")),
        "vm_cpu_count": as_text(payload.get("VM_CPU_COUNT", "")),
        "runtime": values["RUNTIME"],
        "runtime_outcome_channel": values["RUNTIME_OUTCOME_CHANNEL"],
    }


def build_lane_post_outputs(payload: dict[str, object]) -> dict[str, str]:
    required = [
        "ALLOW_FAILURE_MODE",
        "LANE_ALLOW_FAILURE",
        "GOAL",
        "DEP_MODE",
        "REF_MODE",
        "CI_DEPS_REPORT_JSON",
        "UPLOAD_ARTIFACTS",
        "BUILD_TOOL",
        "PLATFORM_ID",
        "VARIANT",
        "ARTIFACT_ARCH",
        "LANE_NAME",
        "ARTIFACT_FAMILY",
        "REF_STAGE_ROOT",
        "REF_OS",
    ]
    return {key.lower(): require_key(payload, key) for key in required}


def main() -> None:
    args = parse_args()

    try:
        payload = json.loads(args.lane_env_json)
    except Exception as exc:
        fail(f"lane_env_json is invalid JSON: {exc}")
    if not isinstance(payload, dict):
        fail("lane_env_json must decode to an object")

    if args.profile == "lane_meta":
        outputs = build_lane_meta_outputs(payload)
    else:
        outputs = build_lane_post_outputs(payload)

    lines = [f"{key}={value}" for key, value in outputs.items()]
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(f"{line}\n")
    else:
        for line in lines:
            print(line)


if __name__ == "__main__":
    main()
