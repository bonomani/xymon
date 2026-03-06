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


def derive_lane_paths(
    *,
    goal: str,
    dep_mode: str,
    build_tool: str,
    variant: str,
    ref_os: str,
    platform_id: str,
    artifact_arch: str,
    artifact_family: str,
    baseline_root: str,
    ref_stage_root: str,
) -> dict[str, str]:
    lane_ref_key = f"{build_tool}.{ref_os}.{variant}"
    ref_valid_root = f".ci-artifacts/ref-valid-{artifact_family}"
    refs_root = f"{ref_valid_root}/refs"
    artifact_root = f"{ref_valid_root}/{build_tool}-{platform_id}-{variant}"
    candidate_dir = f"{refs_root}/{lane_ref_key}"
    baseline_prefix = ""
    legacy_hostname_config = ""
    if goal == "ref":
        baseline_prefix = f"docs/cmake-legacy-migration/refs/{baseline_root}/{variant}"
        legacy_hostname_config = (
            "docs/cmake-legacy-migration/refs/"
            f"{baseline_root}/server/var/lib/xymon/server/etc/xymonserver.cfg"
        )

    if dep_mode == "compare":
        deps_report_path = f"{artifact_root}/deps-report.json"
    else:
        deps_report_path = f"{ref_stage_root}/{lane_ref_key}/meta/deps-report.json"

    return {
        "lane_ref_key": lane_ref_key,
        "refs_root": refs_root,
        "artifact_root": artifact_root,
        "candidate_dir": candidate_dir,
        "baseline_prefix": baseline_prefix,
        "legacy_hostname_config": legacy_hostname_config,
        "deps_report_path": deps_report_path,
        "ref_generate_artifact_name": (
            f"ref_{build_tool}_{ref_os}-{variant}__{platform_id}__{artifact_arch}"
        ),
        "ref_generate_artifact_path": f"{candidate_dir}/**",
        "ref_compare_artifact_path": f"{artifact_root}/**",
        "ref_compare_refs_path": f"{candidate_dir}/**",
    }


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
    compiler = as_text(lane.get("compiler"))
    preset = as_text(lane.get("preset"))
    lane_name = as_text(lane.get("name"))
    variant = as_text(lane.get("variant"))
    runtime = as_text(lane.get("runtime"))

    try:
        validate_lane_build_tool(build_tool)
    except ValueError as exc:
        fail(str(exc))
    if compiler not in {"gcc", "clang"}:
        fail(f"lane_json has unsupported compiler: {compiler}")
    if preset not in {"default", "gnuinstall", "packaging"}:
        fail(f"lane_json has unsupported preset: {preset}")
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
    lane_paths = derive_lane_paths(
        goal=goal,
        dep_mode=dep_mode,
        build_tool=build_tool,
        variant=variant,
        ref_os=ref_os,
        platform_id=platform_id,
        artifact_arch=artifact_arch,
        artifact_family=artifact_family,
        baseline_root=baseline_root,
        ref_stage_root=ref_stage_root,
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
        "CI_COMPILER": compiler,
        "PRESET": preset,
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
        "REFS_ROOT": lane_paths["refs_root"],
        "ARTIFACT_ROOT": lane_paths["artifact_root"],
        "BASELINE_PREFIX": lane_paths["baseline_prefix"],
        "CANDIDATE_DIR": lane_paths["candidate_dir"],
        "LEGACY_HOSTNAME_CONFIG": lane_paths["legacy_hostname_config"],
        "UPLOAD_ARTIFACTS": upload_artifacts,
        "CMAKE_BIN": as_text(lane.get("cmake_bin")),
        "CI_DEPS_REPORT_JSON": lane_paths["deps_report_path"],
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
    lane_post = {
        "allow_failure_mode": allow_failure_mode,
        "lane_allow_failure": lane_allow_failure,
        "goal": goal,
        "dep_mode": dep_mode,
        "ref_mode": ref_mode,
        "ci_deps_report_json": lane_paths["deps_report_path"],
        "upload_artifacts": upload_artifacts,
        "build_tool": build_tool,
        "platform_id": platform_id,
        "variant": variant,
        "artifact_arch": artifact_arch,
        "lane_name": lane_name,
        "artifact_family": artifact_family,
        "ref_stage_root": ref_stage_root,
        "ref_os": ref_os,
        "ref_generate_artifact_name": lane_paths["ref_generate_artifact_name"],
        "ref_generate_artifact_path": lane_paths["ref_generate_artifact_path"],
        "ref_compare_artifact_path": lane_paths["ref_compare_artifact_path"],
        "ref_compare_refs_path": lane_paths["ref_compare_refs_path"],
    }
    output_lines = [
        "lane_env_json="
        + json.dumps(
            lane_env,
            separators=(",", ":"),
            sort_keys=True,
        ),
        "lane_post_json="
        + json.dumps(
            lane_post,
            separators=(",", ":"),
            sort_keys=True,
        ),
    ]
    continue_on_error = (
        "true"
        if allow_failure_mode != "off" and lane_allow_failure == "1"
        else "false"
    )
    output_lines.extend(
        [
            f"runtime_execution={runtime_execution}",
            f"continue_on_error={continue_on_error}",
            f"ref_os={ref_os}",
            f"architecture={as_text(lane.get('architecture'))}",
            f"os_version={os_version}",
            f"vm_memory={as_text(lane.get('vm_memory'))}",
            f"vm_cpu_count={as_text(lane.get('vm_cpu_count'))}",
            f"runtime={runtime}",
            f"runtime_outcome_channel={runtime_outcome_channel}",
        ]
    )

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in output_lines:
                fh.write(f"{line}\n")
    else:
        for line in output_lines:
            print(line)


if __name__ == "__main__":
    main()
