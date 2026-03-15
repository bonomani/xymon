#!/usr/bin/env python3
"""Generate preferred platform candidates from the catalog for each lane family."""
from __future__ import annotations

import argparse
import dataclasses
import re
from pathlib import Path

import yaml

ROOT_DIR = Path(__file__).resolve().parents[3]
CATALOG_PATH = ROOT_DIR / "ci" / "deps" / "platform-catalog.yaml"
AVAILABILITY_PATH = ROOT_DIR / ".github" / "data" / "platform-availability.yml"
LANES_DIR = ROOT_DIR / "ci" / "run" / "ref" / "lanes"
PREFERRED_OUTPUT = ROOT_DIR / "ci" / "run" / "ref" / "preferred-platforms.yml"
STYLE_KEYWORDS = {"slim", "minimal", "lite", "micro", "core"}
LATEST_KEYWORDS = {"latest", "rolling", "tumbleweed", "edge", "current"}
ARCH_PRIORITY = ["amd64", "x86-64", "x86_64", "arm64", "aarch64", "arm32v7", "armhf", "arm/v7", "arm", "ppc64le", "ppc64", "riscv64", "s390x"]


def load_availability(path: Path) -> dict[str, dict]:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    platforms = data.get("platforms")
    if not isinstance(platforms, dict):
        raise SystemExit(f"platform availability missing 'platforms' mapping: {path}")
    return platforms


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


def candidate_sort_key(candidate: PlatformCandidate) -> tuple[int, int, tuple[int, ...], int, str]:
    return (
        0 if candidate.is_slim_variant() else 1,
        0 if candidate.is_latest_variant() else 1,
        candidate.version_sort_key(),
        candidate.arch_priority(),
        candidate.platform_id,
    )


def best_candidate(candidates: list[PlatformCandidate]) -> PlatformCandidate | None:
    if not candidates:
        return None
    return min(candidates, key=candidate_sort_key)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute preferred platform per lane family.")
    parser.add_argument("--lanes-dir", default=LANES_DIR, type=Path)
    parser.add_argument("--availability", default=AVAILABILITY_PATH, type=Path)
    parser.add_argument("--output", default=PREFERRED_OUTPUT, type=Path)
    args = parser.parse_args()

    availability = load_availability(args.availability)
    lanes_dir = args.lanes_dir
    if not lanes_dir.is_dir():
        raise SystemExit(f"Missing lanes directory: {lanes_dir}")

    all_ok = True
    results = []
    for lane_file in sorted(lanes_dir.glob("*.yml")):
        family = lane_file.stem
        platform_ids = load_lane_platform_ids(lane_file)
        candidates = build_candidates(availability, platform_ids)
        best = best_candidate(candidates)
        if best is None:
            print(f"{family}: no matching catalog entries for {platform_ids}")
            all_ok = False
            continue
        first_entry = platform_ids[0] if platform_ids else "<none>"
        preferred_note = "preferred" if best.platform_id != first_entry else "default"
        results.append(
            {
                "family": family,
                "preferred": best.platform_id,
                "first": first_entry,
                "status": preferred_note,
                "platforms": platform_ids,
                "reason": best_reason(best),
            }
        )

    for record in results:
        family = record["family"]
        status_tag = "(preferred)" if record["status"] == "preferred" else "(first)"
        note = "" if status_tag == "(first)" else "preferred differs"
        print(f"{family}: {record['preferred']} {status_tag} | lane entries: {record['platforms']} {note}")
        if status_tag != "(first)":
            all_ok = False
    print()
    if all_ok:
        print("All families already list the preferred platform first.")
    else:
        print("Some families list a different primary than the computed preference.")
    dump_output(args.output, results)
    return 0 if all_ok else 1


def best_reason(candidate: PlatformCandidate) -> str:
    if candidate.is_slim_variant():
        return "slim-preferred"
    if candidate.is_latest_variant():
        return "latest-keyword"
    return "version/arch"


def dump_output(output_path: Path, results: list[dict]) -> None:
    payload = {"preferred_platforms": []}
    for record in results:
        payload["preferred_platforms"].append(
            {
                "family": record["family"],
                "platform_id": record["preferred"],
                "available": record["platforms"],
                "reason": record["reason"],
            }
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(yaml.safe_dump(payload, sort_keys=False))


if __name__ == "__main__":
    raise SystemExit(main())
