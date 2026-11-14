#!/usr/bin/env python3

from typing import Dict


SUPPORTED_PROFILES = {"auto", "default", "debian", "gnuinstall", "packaging"}
SUPPORTED_INSTALL_MODES = {"auto", "source", "package"}


def normalize_allow_failure_mode(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"false", "0", "no"}:
        return "off"
    if value in {"true", "1", "yes"}:
        return "allow"
    return value


def normalize_ref_mode(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"", "false", "0", "no"}:
        return "off"
    return value


def normalize_goal(raw: str) -> str:
    value = (raw or "").strip()
    if value in {"", "auto"}:
        return ""
    return value


def derive_goal(requested_goal: str, ref_mode: str) -> str:
    if requested_goal:
        return requested_goal
    if ref_mode == "off":
        return "verify"
    return "ref"


def validate_goal_ref_publish(goal: str, ref_mode: str, publish: str) -> None:
    if goal not in {"verify", "ref", "compare"}:
        raise ValueError(f"Unsupported goal: {goal}")
    if ref_mode not in {"off", "generate"}:
        raise ValueError(f"Unsupported ref_mode: {ref_mode}")
    if publish not in {"none", "artifact"}:
        raise ValueError(f"Unsupported publish: {publish}")

    if goal == "verify":
        if ref_mode != "off":
            raise ValueError("goal=verify requires ref_mode=off")
        if publish != "none":
            raise ValueError("goal=verify requires publish=none")
        return

    if goal == "ref":
        if ref_mode != "generate":
            raise ValueError("goal=ref requires ref_mode=generate")
        return

    if ref_mode != "off":
        raise ValueError("goal=compare requires ref_mode=off")


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
    if profile not in {"", *SUPPORTED_PROFILES}:
        raise ValueError(f"Unsupported requested_profile: {profile}")


def validate_requested_install_mode(install_mode: str) -> None:
    if install_mode not in {"", *SUPPORTED_INSTALL_MODES}:
        raise ValueError(f"Unsupported requested_install_mode: {install_mode}")


def validate_requested_verify_depth(verify_depth: str) -> None:
    if verify_depth not in {"configure", "build", "install", "test"}:
        raise ValueError(f"Unsupported requested_verify_depth: {verify_depth}")


def validate_lane_build_tool(build_tool: str) -> None:
    if build_tool not in {"make", "cmake"}:
        raise ValueError(f"Unsupported lane build_tool: {build_tool}")


def explicit_requested_profile(requested_profile: str) -> str:
    explicit_profile = "" if requested_profile in {"", "auto"} else requested_profile
    return explicit_profile


def explicit_requested_install_mode(requested_install_mode: str) -> str:
    explicit_install_mode = (
        "" if requested_install_mode in {"", "auto"} else requested_install_mode
    )
    return explicit_install_mode


def resolve_build_tool(
    requested_build_tool: str,
    requested_profile: str,
    goal: str,
) -> str:
    if requested_build_tool != "auto":
        return requested_build_tool

    explicit_profile = explicit_requested_profile(requested_profile)
    if explicit_profile == "gnuinstall":
        return "cmake"
    if explicit_profile == "packaging":
        return "cmake"
    if explicit_profile == "debian":
        return "make"
    if goal == "compare":
        return "cmake"
    return "make"


def resolve_compiler(requested_compiler: str) -> str:
    return requested_compiler


def resolve_profile(requested_profile: str, build_tool: str) -> str:
    explicit_profile = explicit_requested_profile(requested_profile)
    if explicit_profile:
        if build_tool == "make":
            if explicit_profile in {"default", "debian"}:
                return explicit_profile
            raise ValueError(f"profile={explicit_profile} requires build_tool=cmake")
        if explicit_profile in {"default", "gnuinstall", "packaging"}:
            return explicit_profile
        raise ValueError(f"profile={explicit_profile} requires build_tool=make")

    return "default"


def default_install_mode(build_tool: str, profile: str) -> str:
    if build_tool == "make" and profile == "debian":
        return "package"
    return "source"


def validate_install_mode_for_combo(
    build_tool: str,
    profile: str,
    install_mode: str,
) -> None:
    if install_mode not in {"source", "package"}:
        raise ValueError(f"Unsupported install_mode: {install_mode}")
    if build_tool == "make" and profile == "debian" and install_mode != "package":
        raise ValueError(
            f"make profile={profile} currently requires install_mode=package"
        )


def resolve_install_mode(
    requested_install_mode: str,
    build_tool: str,
    profile: str,
) -> str:
    explicit_install_mode = explicit_requested_install_mode(requested_install_mode)
    if explicit_install_mode:
        validate_install_mode_for_combo(build_tool, profile, explicit_install_mode)
        return explicit_install_mode

    install_mode = default_install_mode(build_tool, profile)
    validate_install_mode_for_combo(build_tool, profile, install_mode)
    return install_mode


def resolve_verify_depth(goal: str, requested_verify_depth: str) -> str:
    if goal in {"ref", "compare"}:
        return "install"
    return requested_verify_depth


def derive_dep_mode(goal: str) -> str:
    if goal == "compare":
        return "compare"
    return "generate"


def resolve_execution_model(
    *,
    requested_build_tool: str,
    requested_compiler: str,
    requested_profile: str,
    requested_install_mode: str,
    requested_verify_depth: str,
    requested_goal: str,
    ref_mode: str,
    publish: str,
    allow_failure_mode_raw: str,
) -> Dict[str, str]:
    allow_failure_mode = normalize_allow_failure_mode(allow_failure_mode_raw)
    goal = normalize_goal(requested_goal)
    ref_mode = normalize_ref_mode(ref_mode)
    goal = derive_goal(goal, ref_mode)

    validate_goal_ref_publish(goal, ref_mode, publish)
    validate_allow_failure_mode(allow_failure_mode)
    validate_requested_build_tool(requested_build_tool)
    validate_requested_compiler(requested_compiler)
    validate_requested_profile(requested_profile)
    validate_requested_install_mode(requested_install_mode)
    validate_requested_verify_depth(requested_verify_depth)
    build_tool = resolve_build_tool(
        requested_build_tool,
        requested_profile,
        goal,
    )
    verify_depth = resolve_verify_depth(goal, requested_verify_depth)
    profile = resolve_profile(requested_profile, build_tool)
    install_mode = resolve_install_mode(requested_install_mode, build_tool, profile)

    return {
        "build_tool": build_tool,
        "compiler": resolve_compiler(requested_compiler),
        "profile": profile,
        "install_mode": install_mode,
        "verify_depth": verify_depth,
        "goal": goal,
        "ref_mode": ref_mode,
        "publish": publish,
        "allow_failure_mode": allow_failure_mode,
        "dep_mode": derive_dep_mode(goal),
    }
