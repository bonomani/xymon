#!/usr/bin/env python3

from typing import Dict


def normalize_allow_failure_mode(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"false", "0", "no"}:
        return "off"
    if value in {"true", "1", "yes"}:
        return "allow"
    return value


def validate_goal_ref_publish(goal: str, ref_mode: str, publish: str) -> None:
    if goal not in {"verify", "ref"}:
        raise ValueError(f"Unsupported goal: {goal}")
    if ref_mode not in {"generate", "compare"}:
        raise ValueError(f"Unsupported ref_mode: {ref_mode}")
    if publish not in {"none", "artifact"}:
        raise ValueError(f"Unsupported publish: {publish}")

    if goal != "ref" and ref_mode == "compare":
        raise ValueError("ref_mode=compare is only valid when goal=ref")
    if goal == "verify" and ref_mode != "generate":
        raise ValueError("goal=verify requires ref_mode=generate")
    if goal == "verify" and publish != "none":
        raise ValueError("goal=verify requires publish=none")


def validate_allow_failure_mode(mode: str) -> None:
    if mode not in {"off", "allow", "expect_fail"}:
        raise ValueError(f"Unsupported allow_failure_mode: {mode}")


def validate_requested_build_tool(build_tool: str) -> None:
    if build_tool not in {"auto", "make", "cmake"}:
        raise ValueError(f"Unsupported requested_build_tool: {build_tool}")


def validate_requested_compiler(compiler: str) -> None:
    if compiler not in {"auto", "gcc", "clang"}:
        raise ValueError(f"Unsupported requested_compiler: {compiler}")


def validate_requested_preset(preset: str) -> None:
    if preset not in {"auto", "default", "gnuinstall", "packaging"}:
        raise ValueError(f"Unsupported requested_preset: {preset}")


def validate_requested_verify_depth(verify_depth: str) -> None:
    if verify_depth not in {"configure", "build", "install"}:
        raise ValueError(f"Unsupported requested_verify_depth: {verify_depth}")


def validate_lane_build_tool(build_tool: str) -> None:
    if build_tool not in {"make", "cmake"}:
        raise ValueError(f"Unsupported lane build_tool: {build_tool}")


def resolve_build_tool(requested_build_tool: str, goal: str, ref_mode: str) -> str:
    if requested_build_tool == "auto":
        if goal == "ref" and ref_mode == "compare":
            return "cmake"
        return "make"
    return requested_build_tool


def resolve_compiler(requested_compiler: str) -> str:
    return requested_compiler


def resolve_preset(requested_preset: str, build_tool: str) -> str:
    if build_tool == "make":
        if requested_preset in {"auto", "default"}:
            return "default"
        raise ValueError(f"preset={requested_preset} requires build_tool=cmake")

    if requested_preset == "auto":
        return "default"
    return requested_preset


def resolve_verify_depth(goal: str, requested_verify_depth: str) -> str:
    if goal == "ref":
        return "install"
    return requested_verify_depth


def derive_dep_mode(goal: str, ref_mode: str) -> str:
    if goal == "ref" and ref_mode == "compare":
        return "compare"
    return "generate"


def derive_purpose(goal: str, ref_mode: str) -> str:
    if goal == "ref" and ref_mode == "compare":
        return "validation"
    return "generation"


def resolve_execution_model(
    *,
    requested_build_tool: str,
    requested_compiler: str,
    requested_preset: str,
    requested_verify_depth: str,
    goal: str,
    ref_mode: str,
    publish: str,
    allow_failure_mode_raw: str,
) -> Dict[str, str]:
    allow_failure_mode = normalize_allow_failure_mode(allow_failure_mode_raw)

    validate_goal_ref_publish(goal, ref_mode, publish)
    validate_allow_failure_mode(allow_failure_mode)
    validate_requested_build_tool(requested_build_tool)
    validate_requested_compiler(requested_compiler)
    validate_requested_preset(requested_preset)
    validate_requested_verify_depth(requested_verify_depth)
    build_tool = resolve_build_tool(requested_build_tool, goal, ref_mode)
    verify_depth = resolve_verify_depth(goal, requested_verify_depth)

    return {
        "build_tool": build_tool,
        "compiler": resolve_compiler(requested_compiler),
        "preset": resolve_preset(requested_preset, build_tool),
        "verify_depth": verify_depth,
        "goal": goal,
        "ref_mode": ref_mode,
        "publish": publish,
        "allow_failure_mode": allow_failure_mode,
        "dep_mode": derive_dep_mode(goal, ref_mode),
        "purpose": derive_purpose(goal, ref_mode),
    }
