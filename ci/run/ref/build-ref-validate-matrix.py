#!/usr/bin/env python3

import runpy
import sys
from pathlib import Path


def main() -> None:
    target_script = Path(__file__).with_name("build-ref-make-matrix.py")

    has_purpose_override = any(
        arg == "--purpose" or arg.startswith("--purpose=") for arg in sys.argv[1:]
    )

    forwarded_args = [str(target_script)]
    if not has_purpose_override:
        forwarded_args.extend(["--purpose", "validation"])
    forwarded_args.extend(sys.argv[1:])

    sys.argv = forwarded_args
    runpy.run_path(str(target_script), run_name="__main__")


if __name__ == "__main__":
    main()
