#!/usr/bin/env python3

from pathlib import Path
from typing import Dict, FrozenSet, List, Tuple


_CONTRACT_PATH = Path(__file__).with_name("lane-env-contract.txt")


def _load_contract_sections(path: Path) -> Dict[str, List[str]]:
    if not path.exists():
        raise RuntimeError(f"Lane env contract file missing: {path}")

    sections: Dict[str, List[str]] = {}
    current_section = ""

    for lineno, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1].strip()
            if not current_section:
                raise RuntimeError(f"Invalid empty section name at {path}:{lineno}")
            sections.setdefault(current_section, [])
            continue

        if not current_section:
            raise RuntimeError(
                f"Contract entry outside section at {path}:{lineno}: {line}"
            )
        sections[current_section].append(line)

    return sections


def _normalize_section(
    sections: Dict[str, List[str]], section_name: str, *, dedupe: bool = False
) -> Tuple[str, ...]:
    values = sections.get(section_name)
    if values is None:
        raise RuntimeError(f"Missing section [{section_name}] in {_CONTRACT_PATH}")

    normalized: List[str] = []
    seen = set()
    for value in values:
        key = value.strip()
        if not key:
            continue
        if dedupe:
            if key in seen:
                continue
            seen.add(key)
        normalized.append(key)
    return tuple(normalized)


_SECTIONS = _load_contract_sections(_CONTRACT_PATH)

LANE_ENV_KEYS: FrozenSet[str] = frozenset(
    _normalize_section(_SECTIONS, "all", dedupe=True)
)
LANE_POST_REQUIRED_KEYS: Tuple[str, ...] = _normalize_section(
    _SECTIONS, "lane_post_required", dedupe=True
)


def as_text(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def validate_known_lane_env_keys(payload: Dict[str, object]) -> List[str]:
    return sorted(set(payload.keys()) - set(LANE_ENV_KEYS))
