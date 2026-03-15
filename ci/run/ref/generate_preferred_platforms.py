#!/usr/bin/env python3
"""Generate preferred platform candidates from the catalog for each lane family."""
from __future__ import annotations

import argparse
import dataclasses
import re
from pathlib import Path

import yaml

ROOT_DIR = Path(__file__).resolve().parents[3]
AVAILABILITY_PATH = ROOT_DIR / ".github" / "data" / "platform-availability.yml"
LANES_DIR = ROOT_DIR / "ci" / "run" / "ref" / "lanes"
PREFERRED_OUTPUT = ROOT_DIR / "ci" / "run" / "ref" / "preferred-platforms.yml"
POLICY_PATH = ROOT_DIR / "ci" / "run" / "ref" / "preferred-platform-policy.yaml"
STYLE_KEYWORDS = {"slim", "minimal", "lite", "micro", "core"}
LATEST_KEYWORDS = {"latest", "rolling", "tumbleweed", "edge", "current"}
ARCH_PRIORITY = ["amd64", "x86-64", "x86_64", "arm64", "aarch64", "arm32v7", "armhf", "arm/v7", "arm", "ppc64le", "ppc64", "riscv64", "s390x"]


def load_availability(path: Path) -> dict[str, dict]:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        raise SystemExit(f"platform availability missing 'platforms' mapping: {path}")
    return platforms


def load_policy(path: Path) -> dict[str, dict]:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    families = data.get("families")
    if not isinstance(families, dict):
        raise SystemExit(f"preferred platform policy missing 'families' mapping: {path}")
    normalized = {}
    for family, raw in families.items():
        if not isinstance(raw, dict):
            raise SystemExit(f"preferred platform policy entry must be a mapping: {family}")
        normalized[str(family)] = raw
    if "default" not in normalized:
        raise SystemExit(f"preferred platform policy requires a 'default' entry: {path}")
    return normalized


@dataclasses.dataclass
class PlatformCandidate:
    platform_id: str
    entry: dict

    def display_name(self) -> str:
        return str(self.entry.get("display_name", "")) or str(self.entry.get("image", ""))

    def text(self) -> str:
        return f"{self.platform_id} {self.display_name()}".lower()

    def is_slim_variant(self) -> bool:
        text = self.text()
        return any(keyword in text for keyword in STYLE_KEYWORDS)

    def is_latest_variant(self) -> bool:
        text = self.text()
        return any(keyword in text for keyword in LATEST_KEYWORDS)

    def is_alias(self) -> bool:
        alias_of = str(self.entry.get("alias_of", "") or "").strip()
        return bool(alias_of)

    def excluded_from_primary(self) -> bool:
        return self.is_latest_variant() or self.is_alias()

    def version_tuple(self) -> tuple[int, ...]:
        candidates = []
        platform_version = str(self.entry.get("platform_version", "")) or ""
        candidates.append(platform_version)
        candidates.append(self.platform_id)
        candidates.append(self.display_name())
        for value in candidates:
            digits = tuple(int(num) for num in re.findall(r"\d+", str(value)))
            if digits:
                return digits
        return ()

    def version_sort_key(self) -> tuple[int, ...]:
        version = self.version_tuple()
        if not version:
            return (0,)
        return tuple(-component for component in version)

    def arch_priority(self) -> int:
        arches = self.entry.get("discovered_arches", []) or []
        for index, arch in enumerate(ARCH_PRIORITY):
            if arch in arches:
                return index
        return len(ARCH_PRIORITY)

    def primary_arch(self) -> str:
        arches = self.entry.get("discovered_arches", []) or []
        for arch in ARCH_PRIORITY:
            if arch in arches:
                return arch
        return ""

    def has_capability(self, capability: str) -> bool:
        capability = capability.strip()
        if capability == "direct_runner":
            host_support = self.entry.get("host_support", {}) or {}
            return any(
                isinstance(record, dict) and bool(record.get("direct_runner_labels"))
                for record in host_support.values()
            )
        if capability == "container_runner":
            host_support = self.entry.get("host_support", {}) or {}
            return any(
                isinstance(record, dict)
                and bool(record.get("container_runner_labels") or record.get("direct_runner_labels"))
                for record in host_support.values()
            )
        capabilities = self.entry.get("capabilities", {}) or {}
        if not isinstance(capabilities, dict):
            return False
        if capability in capabilities:
            return bool(capabilities.get(capability))
        container_tooling = capabilities.get("container_tooling", {})
        if isinstance(container_tooling, dict) and capability in container_tooling:
            return bool(container_tooling.get(capability))
        emulation_tooling = capabilities.get("emulation_tooling", {})
        if isinstance(emulation_tooling, dict) and capability in emulation_tooling:
            return bool(emulation_tooling.get(capability))
        virtualization = capabilities.get("virtualization", {})
        if isinstance(virtualization, dict) and capability in virtualization:
            return bool(virtualization.get(capability))
        return False


def family_policy(policy: dict[str, dict], family: str) -> dict:
    merged = dict(policy["default"])
    merged.update(policy.get(family, {}))
    return merged


def preferred_capability_score(candidate: PlatformCandidate, family_cfg: dict) -> int:
    preferred = family_cfg.get("preferred_capabilities", []) or []
    return sum(1 for capability in preferred if candidate.has_capability(str(capability)))


def missing_required_capabilities(candidate: PlatformCandidate, family_cfg: dict) -> bool:
    required = family_cfg.get("required_capabilities", []) or []
    return any(not candidate.has_capability(str(capability)) for capability in required)


def excluded_from_primary(candidate: PlatformCandidate, family_cfg: dict) -> bool:
    if candidate.is_alias() and not family_cfg.get("allow_alias_as_primary", False):
        return True
    if candidate.is_latest_variant():
        text = candidate.text()
        if "rolling" in text or "tumbleweed" in text or "edge" in text:
            return not family_cfg.get("allow_rolling_as_primary", False)
        return not family_cfg.get("allow_latest_as_primary", False)
    return False


def load_lane_platform_ids(lane_file: Path) -> list[str]:
    data = yaml.safe_load(lane_file.read_text()) or {}
    generated = data.get("generated", {})
    platforms = generated.get("platforms", [])
    ids = []
    for entry in platforms:
        platform_id = entry.get("platform_id")
        if platform_id:
            ids.append(platform_id)
    return ids


def build_candidates(availability: dict[str, dict], platform_ids: list[str]) -> list[PlatformCandidate]:
    candidates = []
    for platform_id in platform_ids:
        entry = availability.get(platform_id)
        if entry is None:
            continue
        candidates.append(PlatformCandidate(platform_id=platform_id, entry=entry))
    return candidates


def candidate_sort_key(
    candidate: PlatformCandidate,
    family_cfg: dict,
) -> tuple[int, int, int, tuple[int, ...], int, str]:
    return (
        1 if missing_required_capabilities(candidate, family_cfg) else 0,
        0 if family_cfg.get("prefer_slim", False) and candidate.is_slim_variant() else 1,
        -preferred_capability_score(candidate, family_cfg),
        candidate.version_sort_key(),
        candidate.arch_priority(),
        candidate.platform_id,
    )


def ordered_candidates(candidates: list[PlatformCandidate], family_cfg: dict) -> list[PlatformCandidate]:
    eligible = [
        candidate
        for candidate in candidates
        if not excluded_from_primary(candidate, family_cfg)
        and not missing_required_capabilities(candidate, family_cfg)
    ]
    excluded = [
        candidate
        for candidate in candidates
        if excluded_from_primary(candidate, family_cfg)
        or missing_required_capabilities(candidate, family_cfg)
    ]
    return sorted(eligible, key=lambda candidate: candidate_sort_key(candidate, family_cfg)) + sorted(
        excluded, key=lambda candidate: candidate_sort_key(candidate, family_cfg)
    )


def primary_candidate(candidates: list[PlatformCandidate], family_cfg: dict) -> PlatformCandidate | None:
    ordered = ordered_candidates(candidates, family_cfg)
    if not ordered:
        return None
    return ordered[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute preferred platform per lane family.")
    parser.add_argument("--lanes-dir", default=LANES_DIR, type=Path)
    parser.add_argument("--availability", default=AVAILABILITY_PATH, type=Path)
    parser.add_argument("--policy", default=POLICY_PATH, type=Path)
    parser.add_argument("--output", default=PREFERRED_OUTPUT, type=Path)
    args = parser.parse_args()

    availability = load_availability(args.availability)
    policy = load_policy(args.policy)
    lanes_dir = args.lanes_dir
    if not lanes_dir.is_dir():
        raise SystemExit(f"Missing lanes directory: {lanes_dir}")

    all_ok = True
    results = []
    for lane_file in sorted(lanes_dir.glob("*.yml")):
        family = lane_file.stem
        family_cfg = family_policy(policy, family)
        platform_ids = load_lane_platform_ids(lane_file)
        candidates = build_candidates(availability, platform_ids)
        primary = primary_candidate(candidates, family_cfg)
        ordered = ordered_candidates(candidates, family_cfg)
        if primary is None:
            print(f"{family}: no matching catalog entries for {platform_ids}")
            all_ok = False
            continue
        first_entry = platform_ids[0] if platform_ids else "<none>"
        preferred_note = "preferred" if primary.platform_id != first_entry else "default"
        excluded = [
            candidate.platform_id
            for candidate in ordered
            if excluded_from_primary(candidate, family_cfg)
            or missing_required_capabilities(candidate, family_cfg)
        ]
        results.append(
            {
                "family": family,
                "primary_platform_id": primary.platform_id,
                "ordered_platform_ids": [candidate.platform_id for candidate in ordered],
                "primary_arch": primary.primary_arch(),
                "excluded_from_primary": excluded,
                "first": first_entry,
                "status": preferred_note,
                "platforms": platform_ids,
            }
        )

    for record in results:
        family = record["family"]
        status_tag = "(preferred)" if record["status"] == "preferred" else "(first)"
        note = "" if status_tag == "(first)" else "preferred differs"
        print(
            f"{family}: {record['primary_platform_id']} {status_tag} | "
            f"lane entries: {record['platforms']} {note}"
        )
        if status_tag != "(first)":
            all_ok = False
    print()
    if all_ok:
        print("All families already list the preferred platform first.")
    else:
        print("Some families list a different primary than the computed preference.")
    dump_output(args.output, results)
    return 0 if all_ok else 1


def dump_output(output_path: Path, results: list[dict]) -> None:
    payload = {"preferred_platforms": []}
    for record in results:
        payload["preferred_platforms"].append(
            {
                "family": record["family"],
                "primary_platform_id": record["primary_platform_id"],
                "ordered_platform_ids": record["ordered_platform_ids"],
                "primary_arch": record["primary_arch"],
                "excluded_from_primary": record["excluded_from_primary"],
            }
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(yaml.safe_dump(payload, sort_keys=False))


if __name__ == "__main__":
    raise SystemExit(main())
