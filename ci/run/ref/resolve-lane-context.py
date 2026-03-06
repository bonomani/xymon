#!/usr/bin/env python3

import argparse
import json
import os
import sys
from pathlib import Path

from execution_model import (
    derive_dep_mode,
    normalize_allow_failure_mode,
    validate_allow_failure_mode,
    validate_goal_ref_publish,
    validate_lane_build_tool,
)
from lane_env_contract import as_text, validate_known_lane_env_keys
from runtime_model import DEFAULT_RUNTIME_MODEL_PATH, load_runtime_model


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Resolve lane_json + normalized mode inputs into lane context outputs"
    )
    parser.add_argument("--lane-json", required=True)
    parser.add_argument("--goal", required=True)
    parser.add_argument("--ref-mode", required=True)
    parser.add_argument("--publish", required=True)
    parser.add_argument("--allow-failure-mode", required=True)
    parser.add_argument(
        "--runtime-model",
        default=str(DEFAULT_RUNTIME_MODEL_PATH),
        help="Path to runtime model JSON",
    )
    parser.add_argument("--github-output", default="")
    return parser.parse_args()


def main():
    args = parse_args()
    goal = as_text(args.goal)
    ref_mode = as_text(args.ref_mode)
    publish = as_text(args.publish)
    allow_failure_mode = normalize_allow_failure_mode(as_text(args.allow_failure_mode))
    try:
        validate_goal_ref_publish(goal, ref_mode, publish)
        validate_allow_failure_mode(allow_failure_mode)
    except ValueError as exc:
        fail(str(exc))

    try:
        lane = json.loads(args.lane_json)
    except Exception as exc:  # pragma: no cover - defensive
        fail(f"lane_json is not valid JSON: {exc}")
    if not isinstance(lane, dict):
        fail("lane_json must decode to an object")

    runtime_model = load_runtime_model(Path(args.runtime_model))
    supported_runtimes = set(runtime_model["ordered_keys"])

    build_tool = as_text(lane.get("build_tool"))
    lane_name = as_text(lane.get("name"))
    variant = as_text(lane.get("variant"))
    runtime = as_text(lane.get("runtime"))

    try:
        validate_lane_build_tool(build_tool)
    except ValueError as exc:
        fail(str(exc))
    if not lane_name:
        fail("lane_json missing name")
    if not variant:
        fail("lane_json missing variant")
    if runtime not in supported_runtimes:
        fail(f"lane_json has unsupported runtime: {runtime}")
    runtime_execution = runtime_model["execution_by_key"][runtime]
    runtime_outcome_channel = runtime_model["outcome_channel_by_key"][runtime]

    runtime_default_ref_os = runtime_model["default_ref_os_by_key"][runtime]

    ref_os = as_text(lane.get("ref_os"))
    if not ref_os:
        if runtime_default_ref_os == "family":
            fail(
                f"lane_json missing ref_os for runtime '{runtime}' "
                "(runtime default is family-specific)"
            )
        ref_os = runtime_default_ref_os
    platform_os = as_text(lane.get("platform_os")) or ref_os
    platform_id = as_text(lane.get("platform_id")) or platform_os
    artifact_arch = as_text(lane.get("artifact_arch")) or "amd64"
    os_version = as_text(lane.get("os_version"))

    baseline_root = as_text(lane.get("baseline_root"))
    if goal == "ref" and not baseline_root:
        fail("lane_json missing baseline_root")

    # Normalize to avoid empty artifact namespaces in logs/artifact names.
    artifact_family = as_text(lane.get("artifact_family")) or ref_os

    upload_artifacts = "1" if publish == "artifact" else "0"
    lane_allow_failure = "1" if lane.get("allow_failure") is True else "0"

    enable = "ON" if variant == "server" else "OFF"

    workspace = as_text(os.environ.get("GITHUB_WORKSPACE"))
    if workspace:
        ref_stage_root = os.path.join(workspace, "tmp", "xymon-refs")
    else:
        ref_stage_root = "tmp/xymon-refs"

    dep_mode = derive_dep_mode(goal, ref_mode)
    if dep_mode == "compare":
        deps_report_path = (
            f".ci-artifacts/ref-valid-{artifact_family}/"
            f"{build_tool}-{platform_id}-{variant}/deps-report.json"
        )
    else:
        deps_report_path = (
            f"{ref_stage_root}/{build_tool}.{ref_os}.{variant}/meta/deps-report.json"
        )

    lane_env = {
        "LEGACY_APPLY_OWNERSHIP": "ON",
        "XYMONUSER": "_www",
        "XYMONGROUP": "_www",
        "ALLOW_FAILURE_MODE": allow_failure_mode,
        "LANE_ALLOW_FAILURE": lane_allow_failure,
        "ENABLE_LDAP": enable,
        "ENABLE_SNMP": enable,
        "BUILD_TOOL": build_tool,
        "LANE_NAME": lane_name,
        "DEP_MODE": dep_mode,
        "GOAL": goal,
        "REF_MODE": ref_mode,
        "PUBLISH": publish,
        "VARIANT": variant,
        "BASELINE_ROOT": baseline_root,
        "REF_OS": ref_os,
        "PLATFORM_OS": platform_os,
        "OS_VERSION": os_version,
        "ARTIFACT_FAMILY": artifact_family,
        "ARTIFACT_ARCH": artifact_arch,
        "PLATFORM_ID": platform_id,
        "REF_STAGE_ROOT": ref_stage_root,
        "UPLOAD_ARTIFACTS": upload_artifacts,
        "CMAKE_BIN": as_text(lane.get("cmake_bin")),
        "CI_DEPS_REPORT_JSON": deps_report_path,
        "PREPARE_PROFILE": as_text(lane.get("prepare_profile")),
        "CHECKOUT_MODE": as_text(lane.get("checkout_mode")),
        "CONTAINER_IMAGE": as_text(lane.get("container")),
        "CONTAINER_OPTIONS": as_text(lane.get("container_options")),
        "RUNTIME": runtime,
        "RUNTIME_EXECUTION": runtime_execution,
        "RUNTIME_OUTCOME_CHANNEL": runtime_outcome_channel,
        "ARCHITECTURE": as_text(lane.get("architecture")),
        "VM_MEMORY": as_text(lane.get("vm_memory")),
        "VM_CPU_COUNT": as_text(lane.get("vm_cpu_count")),
    }
    unknown_keys = validate_known_lane_env_keys(lane_env)
    if unknown_keys:
        fail(f"Internal error: lane_env has unknown keys: {', '.join(unknown_keys)}")
    output_lines = [
        "lane_env_json="
        + json.dumps(
            lane_env,
            separators=(",", ":"),
            sort_keys=True,
        )
    ]

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in output_lines:
                fh.write(f"{line}\n")
    else:
        for line in output_lines:
            print(line)


if __name__ == "__main__":
    main()
