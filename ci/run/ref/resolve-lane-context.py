#!/usr/bin/env python3

import argparse
import json
import os
import sys
from pathlib import Path

from runtime_model import DEFAULT_RUNTIME_MODEL_PATH, load_runtime_model


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def as_text(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Resolve lane_json + normalized mode inputs into lane context outputs"
    )
    parser.add_argument("--lane-json", required=True)
    parser.add_argument("--goal", required=True, choices=["verify", "ref"])
    parser.add_argument("--ref-mode", required=True, choices=["generate", "compare"])
    parser.add_argument("--publish", required=True, choices=["none", "artifact"])
    parser.add_argument(
        "--allow-failure-mode",
        required=True,
        choices=["off", "allow", "expect_fail"],
    )
    parser.add_argument("--dep-mode", required=True, choices=["generate", "compare"])
    parser.add_argument(
        "--runtime-model",
        default=str(DEFAULT_RUNTIME_MODEL_PATH),
        help="Path to runtime model JSON",
    )
    parser.add_argument("--github-output", default="")
    return parser.parse_args()


def main():
    args = parse_args()

    try:
        lane = json.loads(args.lane_json)
    except Exception as exc:  # pragma: no cover - defensive
        fail(f"lane_json is not valid JSON: {exc}")
    if not isinstance(lane, dict):
        fail("lane_json must decode to an object")

    runtime_model = load_runtime_model(Path(args.runtime_model))
    supported_runtimes = set(runtime_model["ordered_keys"])

    build_tool = as_text(lane.get("build_tool"))
    variant = as_text(lane.get("variant"))
    runtime = as_text(lane.get("runtime"))

    if build_tool not in {"make", "cmake"}:
        fail(f"Unsupported lane build_tool: {build_tool}")
    if not variant:
        fail("lane_json missing variant")
    if runtime not in supported_runtimes:
        fail(f"lane_json has unsupported runtime: {runtime}")

    ref_os = as_text(lane.get("ref_os")) or "linux"
    platform_os = as_text(lane.get("platform_os")) or ref_os
    platform_id = as_text(lane.get("platform_id")) or platform_os
    artifact_arch = as_text(lane.get("artifact_arch")) or "amd64"
    os_version = as_text(lane.get("os_version"))

    baseline_root = as_text(lane.get("baseline_root"))
    if args.goal == "ref" and not baseline_root:
        fail("lane_json missing baseline_root")

    # Normalize to avoid empty artifact namespaces in logs/artifact names.
    artifact_family = as_text(lane.get("artifact_family")) or ref_os

    upload_artifacts = "1" if args.publish == "artifact" else "0"
    lane_allow_failure = "1" if lane.get("allow_failure") is True else "0"

    enable = "ON" if variant == "server" else "OFF"

    workspace = as_text(os.environ.get("GITHUB_WORKSPACE"))
    if workspace:
        ref_stage_root = os.path.join(workspace, "tmp", "xymon-refs")
    else:
        ref_stage_root = "tmp/xymon-refs"

    outputs = {
        "goal": args.goal,
        "ref_mode": args.ref_mode,
        "publish": args.publish,
        "dep_mode": args.dep_mode,
        "allow_failure_mode": args.allow_failure_mode,
        "runtime": runtime,
        "build_tool": build_tool,
        "variant": variant,
        "lane_allow_failure": lane_allow_failure,
        "ref_os": ref_os,
        "platform_os": platform_os,
        "platform_id": platform_id,
        "os_version": os_version,
        "artifact_arch": artifact_arch,
        "baseline_root": baseline_root,
        "artifact_family": artifact_family,
        "ref_stage_root": ref_stage_root,
        "upload_artifacts": upload_artifacts,
        "enable_ldap": enable,
        "enable_snmp": enable,
        "cmake_bin": as_text(lane.get("cmake_bin")),
        "prepare_profile": as_text(lane.get("prepare_profile")),
        "checkout_mode": as_text(lane.get("checkout_mode")),
        "container": as_text(lane.get("container")),
        "container_options": as_text(lane.get("container_options")),
        "architecture": as_text(lane.get("architecture")),
        "vm_memory": as_text(lane.get("vm_memory")),
        "vm_cpu_count": as_text(lane.get("vm_cpu_count")),
    }

    output_lines = [f"{key}={value}" for key, value in outputs.items()]

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in output_lines:
                fh.write(f"{line}\n")
    else:
        for line in output_lines:
            print(line)


if __name__ == "__main__":
    main()
