#!/usr/bin/env python3

import argparse
import json

from execution_model import resolve_execution_model


def parse_args():
    parser = argparse.ArgumentParser(
        description="Resolve goal/ref/publish/build into normalized execution model"
    )
    parser.add_argument("--requested-build-tool", required=True)
    parser.add_argument("--goal", default="verify")
    parser.add_argument("--ref-mode", default="generate")
    parser.add_argument("--publish", default="none")
    parser.add_argument("--allow-failure-mode", default="allow")
    parser.add_argument("--github-output", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        outputs = resolve_execution_model(
            requested_build_tool=args.requested_build_tool,
            goal=args.goal,
            ref_mode=args.ref_mode,
            publish=args.publish,
            allow_failure_mode_raw=args.allow_failure_mode,
        )
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc

    output_payload = dict(outputs)
    output_payload["execution_model_json"] = json.dumps(
        outputs,
        separators=(",", ":"),
        sort_keys=True,
    )

    lines = [f"{key}={value}" for key, value in output_payload.items()]
    for line in lines:
        print(line)

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(f"{line}\n")


if __name__ == "__main__":
    main()
