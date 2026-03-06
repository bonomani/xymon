#!/usr/bin/env python3

import argparse
import json
import os
import sys

from lane_env_contract import (
    LANE_POST_REQUIRED_KEYS,
    as_text,
    validate_known_lane_env_keys,
)


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Decode lane_env_json into normalized GITHUB_OUTPUT fields"
    )
    parser.add_argument("--lane-env-json", required=True)
    parser.add_argument(
        "--profile",
        required=True,
        choices=["lane_post"],
        help="Output profile to produce",
    )
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT", ""),
        help="Path to GITHUB_OUTPUT file. If empty, print to stdout.",
    )
    return parser.parse_args()


def require_key(payload: dict[str, object], key: str) -> str:
    value = as_text(payload.get(key, ""))
    if not value:
        fail(f"lane_env_json missing required key: {key}")
    return value


def build_lane_post_outputs(payload: dict[str, object]) -> dict[str, str]:
    return {key.lower(): require_key(payload, key) for key in LANE_POST_REQUIRED_KEYS}


def main() -> None:
    args = parse_args()

    try:
        payload = json.loads(args.lane_env_json)
    except Exception as exc:
        fail(f"lane_env_json is invalid JSON: {exc}")
    if not isinstance(payload, dict):
        fail("lane_env_json must decode to an object")
    unknown_keys = validate_known_lane_env_keys(payload)
    if unknown_keys:
        fail(f"lane_env_json contains unknown keys: {', '.join(unknown_keys)}")

    outputs = build_lane_post_outputs(payload)

    lines = [f"{key}={value}" for key, value in outputs.items()]
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(f"{line}\n")
    else:
        for line in lines:
            print(line)


if __name__ == "__main__":
    main()
