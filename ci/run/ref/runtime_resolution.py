#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from runtime_model import DEFAULT_RUNTIME_MODEL_PATH, load_runtime_model


def die(message: str) -> None:
    raise SystemExit(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve runtime execution metadata and lane outcomes from the runtime model"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser(
        "metadata", help="Resolve execution and outcome-channel for a runtime key"
    )
    metadata.add_argument("--runtime", required=True)
    metadata.add_argument("--current-runtime", default="")
    metadata.add_argument("--runtime-execution", default="")
    metadata.add_argument("--runtime-outcome-channel", default="")
    metadata.add_argument(
        "--runtime-model",
        default=str(DEFAULT_RUNTIME_MODEL_PATH),
        help="Path to runtime model JSON",
    )
    metadata.add_argument("--github-output", default="")

    outcome = subparsers.add_parser(
        "outcome", help="Resolve the effective outcome for a lane runtime"
    )
    outcome.add_argument("--runtime", required=True)
    outcome.add_argument("--outcome-host-container", default="")
    outcome.add_argument("--outcome-bsd-vm", default="")
    outcome.add_argument(
        "--runtime-model",
        default=str(DEFAULT_RUNTIME_MODEL_PATH),
        help="Path to runtime model JSON",
    )
    outcome.add_argument("--github-output", default="")

    return parser.parse_args()


def load_model(path: str) -> dict:
    return load_runtime_model(Path(path))


def resolve_runtime_metadata(
    *,
    runtime: str,
    current_runtime: str,
    runtime_execution: str,
    runtime_outcome_channel: str,
    runtime_model: dict,
) -> dict[str, str]:
    supported = set(runtime_model["ordered_keys"])
    if runtime not in supported:
        die(f"Unsupported runtime: {runtime}")

    execution = runtime_model["execution_by_key"][runtime]
    outcome_channel = runtime_model["outcome_channel_by_key"][runtime]
    if runtime == current_runtime:
        if runtime_execution:
            execution = runtime_execution
        if runtime_outcome_channel:
            outcome_channel = runtime_outcome_channel

    return {
        "execution": execution,
        "outcome_channel": outcome_channel,
    }


def resolve_lane_outcome(
    *,
    runtime: str,
    outcome_host_container: str,
    outcome_bsd_vm: str,
    runtime_model: dict,
) -> str:
    supported = set(runtime_model["ordered_keys"])
    if runtime not in supported:
        die(f"Unsupported runtime: {runtime}")

    outcome_channel = runtime_model["outcome_channel_by_key"][runtime]
    if outcome_channel == "host_container":
        outcome = outcome_host_container
    elif outcome_channel == "bsd_vm":
        outcome = outcome_bsd_vm
    else:
        die(
            f"Unsupported outcome channel '{outcome_channel}' for runtime '{runtime}'"
        )

    if not outcome:
        die(f"Missing lane outcome for runtime '{runtime}'")
    return outcome


def write_output(values: dict[str, str], github_output: str) -> None:
    lines = [f"{key}={value}" for key, value in values.items()]
    if github_output:
        with open(github_output, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(f"{line}\n")
    else:
        for line in lines:
            print(line)


def main() -> None:
    args = parse_args()
    runtime_model = load_model(args.runtime_model)

    if args.command == "metadata":
        values = resolve_runtime_metadata(
            runtime=args.runtime,
            current_runtime=args.current_runtime,
            runtime_execution=args.runtime_execution,
            runtime_outcome_channel=args.runtime_outcome_channel,
            runtime_model=runtime_model,
        )
        write_output(values, args.github_output)
        return

    if args.command == "outcome":
        outcome = resolve_lane_outcome(
            runtime=args.runtime,
            outcome_host_container=args.outcome_host_container,
            outcome_bsd_vm=args.outcome_bsd_vm,
            runtime_model=runtime_model,
        )
        write_output({"value": outcome}, args.github_output)
        return

    die(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
