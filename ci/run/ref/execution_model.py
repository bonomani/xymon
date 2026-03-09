#!/usr/bin/env python3

from typing import Dict


SUPPORTED_LAYOUTS = {"auto", "default", "debian", "gnuinstall", "packaging"}


def normalize_allow_failure_mode(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"false", "0", "no"}:
        return "off"
    if value in {"true", "1", "yes"}:
        return "allow"
    return value


def normalize_ref_mode(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"false", "0", "no"}:
        return "off"
    return value


def derive_goal_from_ref_mode(ref_mode: str) -> str:
    if ref_mode == "off":
        return "verify"
    return "ref"


def validate_goal_ref_publish(goal: str, ref_mode: str, publish: str) -> None:
    if goal not in {"verify", "ref"}:
        raise ValueError(f"Unsupported goal: {goal}")
    if ref_mode not in {"off", "generate", "compare"}:
        raise ValueError(f"Unsupported ref_mode: {ref_mode}")
    if publish not in {"none", "artifact"}:
        raise ValueError(f"Unsupported publish: {publish}")

    expected_goal = derive_goal_from_ref_mode(ref_mode)
    if goal != expected_goal:
        raise ValueError(f"goal={goal} is inconsistent with ref_mode={ref_mode}")
    if ref_mode == "off" and publish != "none":
        raise ValueError("ref_mode=off requires publish=none")


def validate_allow_failure_mode(mode: str) -> None:
    if mode not in {"off", "allow", "expect_fail"}:
        raise ValueError(f"Unsupported allow_failure_mode: {mode}")


def validate_requested_build_tool(build_tool: str) -> None:
    if build_tool not in {"auto", "make", "cmake"}:
        raise ValueError(f"Unsupported requested_build_tool: {build_tool}")


def validate_requested_compiler(compiler: str) -> None:
    if compiler not in {"auto", "gcc", "clang"}:
        raise ValueError(f"Unsupported requested_compiler: {compiler}")


def validate_requested_profile(profile: str) -> None:
    if profile not in {"", *SUPPORTED_LAYOUTS}:
        raise ValueError(f"Unsupported requested_profile: {profile}")


def validate_requested_verify_depth(verify_depth: str) -> None:
    if verify_depth not in {"configure", "build", "install"}:
        raise ValueError(f"Unsupported requested_verify_depth: {verify_depth}")


def validate_lane_build_tool(build_tool: str) -> None:
    if build_tool not in {"make", "cmake"}:
        raise ValueError(f"Unsupported lane build_tool: {build_tool}")


def explicit_requested_profile(requested_profile: str) -> str:
    explicit_profile = "" if requested_profile in {"", "auto"} else requested_profile
    return explicit_profile


def resolve_build_tool(
    requested_build_tool: str,
    requested_profile: str,
    ref_mode: str,
) -> str:
    if requested_build_tool != "auto":
        return requested_build_tool

    explicit_profile = explicit_requested_profile(requested_profile)
    if explicit_profile == "gnuinstall":
        return "cmake"
    if explicit_profile == "debian":
        return "make"
    if ref_mode == "compare":
        return "cmake"
    return "make"


def resolve_compiler(requested_compiler: str) -> str:
    return requested_compiler


def resolve_profile(requested_profile: str, build_tool: str) -> str:
    explicit_profile = explicit_requested_profile(requested_profile)
    if explicit_profile:
        if build_tool == "make":
            if explicit_profile in {"default", "debian", "packaging"}:
                return explicit_profile
            raise ValueError(f"profile={explicit_profile} requires build_tool=cmake")
        if explicit_profile in {"default", "gnuinstall", "packaging"}:
            return explicit_profile
        raise ValueError(f"profile={explicit_profile} requires build_tool=make")

    return "default"


def resolve_verify_depth(ref_mode: str, requested_verify_depth: str) -> str:
    if ref_mode != "off":
        return "install"
    return requested_verify_depth


def derive_dep_mode(ref_mode: str) -> str:
    if ref_mode == "compare":
        return "compare"
    return "generate"


def resolve_execution_model(
    *,
    requested_build_tool: str,
    requested_compiler: str,
    requested_profile: str,
    requested_verify_depth: str,
    ref_mode: str,
    publish: str,
    allow_failure_mode_raw: str,
) -> Dict[str, str]:
    allow_failure_mode = normalize_allow_failure_mode(allow_failure_mode_raw)
    ref_mode = normalize_ref_mode(ref_mode)
    goal = derive_goal_from_ref_mode(ref_mode)

    validate_goal_ref_publish(goal, ref_mode, publish)
    validate_allow_failure_mode(allow_failure_mode)
    validate_requested_build_tool(requested_build_tool)
    validate_requested_compiler(requested_compiler)
    validate_requested_profile(requested_profile)
    validate_requested_verify_depth(requested_verify_depth)
    build_tool = resolve_build_tool(
        requested_build_tool,
        requested_profile,
        ref_mode,
    )
    verify_depth = resolve_verify_depth(ref_mode, requested_verify_depth)
    profile = resolve_profile(requested_profile, build_tool)

    return {
        "build_tool": build_tool,
        "compiler": resolve_compiler(requested_compiler),
        "profile": profile,
        "verify_depth": verify_depth,
        "goal": goal,
        "ref_mode": ref_mode,
        "publish": publish,
        "allow_failure_mode": allow_failure_mode,
        "dep_mode": derive_dep_mode(ref_mode),
    }
