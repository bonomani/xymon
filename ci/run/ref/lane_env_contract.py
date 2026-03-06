#!/usr/bin/env python3

from __future__ import annotations

LANE_ENV_KEYS = frozenset(
    {
        "ALLOW_FAILURE_MODE",
        "ARCHITECTURE",
        "ARTIFACT_ARCH",
        "ARTIFACT_FAMILY",
        "BASELINE_ROOT",
        "BUILD_TOOL",
        "CHECKOUT_MODE",
        "CI_DEPS_REPORT_JSON",
        "CMAKE_BIN",
        "CONTAINER_IMAGE",
        "CONTAINER_OPTIONS",
        "DEP_MODE",
        "ENABLE_LDAP",
        "ENABLE_SNMP",
        "GOAL",
        "LANE_ALLOW_FAILURE",
        "LANE_NAME",
        "LEGACY_APPLY_OWNERSHIP",
        "OS_VERSION",
        "PLATFORM_ID",
        "PLATFORM_OS",
        "PREPARE_PROFILE",
        "PUBLISH",
        "REF_MODE",
        "REF_OS",
        "REF_STAGE_ROOT",
        "RUNTIME",
        "RUNTIME_EXECUTION",
        "RUNTIME_OUTCOME_CHANNEL",
        "UPLOAD_ARTIFACTS",
        "VARIANT",
        "VM_CPU_COUNT",
        "VM_MEMORY",
        "XYMONGROUP",
        "XYMONUSER",
    }
)

LANE_META_REQUIRED_KEYS = (
    "RUNTIME_EXECUTION",
    "ALLOW_FAILURE_MODE",
    "LANE_ALLOW_FAILURE",
    "REF_OS",
    "RUNTIME",
    "RUNTIME_OUTCOME_CHANNEL",
)

LANE_POST_REQUIRED_KEYS = (
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
)


def as_text(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def validate_known_lane_env_keys(payload: dict[str, object]) -> list[str]:
    unknown = sorted(set(payload.keys()) - set(LANE_ENV_KEYS))
    return unknown
