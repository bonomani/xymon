from __future__ import annotations

from collections.abc import Mapping

CATEGORY_ORDER = [
    "success",
    "success_with_allow_failure",
    "fails_with_allow_failure",
    "fails_hard",
]

CATEGORY_LABELS = {
    "success": "Passed jobs on normal lanes",
    "success_with_allow_failure": "Passed jobs on masked lanes",
    "fails_with_allow_failure": "Failed jobs on masked lanes",
    "fails_hard": "Failed jobs on normal lanes",
}


def normalize_conclusion(conclusion: str) -> str:
    return str(conclusion or "").strip().lower() or "unknown"


def effective_lane_conclusion(
    github_conclusion: str,
    *,
    allow_failure: bool,
    recorded_outcome: str = "",
) -> tuple[str, bool]:
    normalized_recorded = normalize_conclusion(recorded_outcome)
    if normalized_recorded and normalized_recorded != "unknown":
        return normalized_recorded, True

    normalized_github = normalize_conclusion(github_conclusion)
    if allow_failure and normalized_github == "success":
        return "unknown", False
    return normalized_github, False


def classify_lane_category(conclusion: str, allow_failure: bool) -> str:
    normalized = normalize_conclusion(conclusion)
    if normalized == "success":
        return "success_with_allow_failure" if allow_failure else "success"
    return "fails_with_allow_failure" if allow_failure else "fails_hard"


def build_category_counts(categorized: Mapping[str, list[dict]]) -> dict[str, int]:
    return {key: len(categorized.get(key, [])) for key in CATEGORY_ORDER}


def total_fail_count(category_counts: Mapping[str, int]) -> int:
    return category_counts.get("fails_with_allow_failure", 0) + category_counts.get("fails_hard", 0)
