#!/usr/bin/env python3

import argparse
from pathlib import Path

from runtime_model import DEFAULT_RUNTIME_MODEL_PATH, load_runtime_model


def parse_args():
    parser = argparse.ArgumentParser(
        description="Query runtime metadata from runtime-model.json"
    )
    parser.add_argument("--runtime", required=True, help="Runtime key to query")
    parser.add_argument(
        "--field",
        required=True,
        choices=["platform_runtime", "execution", "outcome_channel"],
        help="Field to print for the runtime",
    )
    parser.add_argument(
        "--runtime-model",
        default=str(DEFAULT_RUNTIME_MODEL_PATH),
        help="Path to runtime model JSON",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    model = load_runtime_model(Path(args.runtime_model))
    runtime = args.runtime

    field_maps = {
        "platform_runtime": model["platform_runtime_by_key"],
        "execution": model["execution_by_key"],
        "outcome_channel": model["outcome_channel_by_key"],
    }

    values = field_maps[args.field]
    if runtime not in values:
        raise SystemExit(f"Unsupported runtime: {runtime}")

    print(values[runtime])


if __name__ == "__main__":
    main()
