"""Shared Python helpers for platform normalization rules."""

from __future__ import annotations

import re


def compose_os_key(os_name: str, version: str | int | None) -> str:
    version_text = "" if version is None else str(version).strip()
    if not version_text:
        return os_name
    return f"{os_name}_{version_text.replace('.', '_')}"


def find_matching_rule(
    normalization_rules: dict[str, dict] | None,
    family: str,
    os_name: str,
) -> dict | None:
    if not normalization_rules:
        return None

    preferred_rule = normalization_rules.get(os_name)
    matching_rule = preferred_rule if isinstance(preferred_rule, dict) else None
    if matching_rule is None or str(matching_rule.get("family", "")).strip() != family or str(
        matching_rule.get("os", "")
    ).strip() != os_name:
        matching_rule = None
        for rule in normalization_rules.values():
            if not isinstance(rule, dict):
                continue
            if str(rule.get("family", "")).strip() != family:
                continue
            if str(rule.get("os", "")).strip() != os_name:
                continue
            matching_rule = rule
            break
    return matching_rule


def normalize_rule_version(rule: dict | None, version: str | None) -> str | None:
    if not isinstance(rule, dict):
        return version

    version_text = "" if version is None else str(version).strip()
    mode = str(rule.get("version_mode", "")).strip()
    version_default = str(rule.get("version_default", "")).strip()
    version_fixed = str(rule.get("version_fixed", "")).strip()
    version_fallback = str(rule.get("version_fallback", "")).strip()
    versions = rule.get("versions", {})

    if mode == "fixed":
        resolved = version_fixed or version_default or version_text
        return resolved or None
    if mode == "major":
        if version_text:
            match = re.search(r"\d+(?:\.\d+)?", version_text)
            if match:
                return match.group(0).split(".", 1)[0]
        return version_default or None
    if mode == "dot_to_underscore":
        if version_text:
            return version_text.replace(".", "_")
        return version_default or None
    if mode == "exact_map":
        if isinstance(versions, dict):
            mapped = versions.get(version_text)
            if mapped is None and "." in version_text:
                mapped = versions.get(version_text.split(".", 1)[0])
            if mapped is None:
                digit_match = re.match(r"(\d+)", version_text)
                if digit_match:
                    mapped = versions.get(digit_match.group(1))
            if mapped is not None:
                resolved = str(mapped).strip()
                return resolved or None
        if version_fallback == "default" and version_default:
            return version_default
        if version_fallback == "passthrough":
            digit_match = re.match(r"(\d+)", version_text)
            if digit_match:
                return digit_match.group(1)
            return version_text or None
        return version_default or version_text or None
    if mode == "prefix_map":
        if isinstance(versions, dict) and version_text:
            best_match = ""
            best_value = ""
            for raw_prefix, raw_value in versions.items():
                prefix = str(raw_prefix).strip()
                value = str(raw_value).strip()
                if prefix and value and version_text.startswith(prefix) and len(prefix) > len(best_match):
                    best_match = prefix
                    best_value = value
            if best_value:
                return best_value
        return version_default or version_text or None

    return version_text or None


def candidate_os_keys_for_rule(rule: dict) -> tuple[bool, set[str]]:
    os_name = str(rule.get("os", "")).strip()
    mode = str(rule.get("version_mode", "")).strip()
    version_default = rule.get("version_default")
    versions = rule.get("versions", {})

    strict_keys = False
    candidate_keys: set[str] = set()

    if mode == "fixed":
        strict_keys = True
        normalized = normalize_rule_version(rule, None)
        candidate_keys.add(compose_os_key(os_name, normalized))
    elif mode in {"exact_map", "prefix_map"}:
        strict_keys = True
        if versions is None:
            versions = {}
        if not isinstance(versions, dict):
            raise ValueError("versions must be a mapping")
        for value in versions.values():
            if isinstance(value, (str, int, float)):
                text = str(value).strip()
                if text:
                    candidate_keys.add(compose_os_key(os_name, text))
        if isinstance(version_default, str) and version_default.strip():
            candidate_keys.add(compose_os_key(os_name, version_default.strip()))
        if not candidate_keys:
            strict_keys = False
    elif mode in {"major", "dot_to_underscore"}:
        strict_keys = False
    else:
        raise ValueError(f"unknown version_mode '{mode}'")

    return strict_keys, candidate_keys
