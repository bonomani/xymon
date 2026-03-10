#!/usr/bin/env python3

import argparse
from pathlib import Path

import yaml


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve packaging dependencies from ci/deps/data/packaging.yaml"
    )
    parser.add_argument("--package-kind", required=True, choices=("deb", "rpm"))
    parser.add_argument("--pkgmgr", required=True, choices=("apt",))
    parser.add_argument(
        "--data-file",
        default="ci/deps/data/packaging.yaml",
        help="Path to packaging dependency database",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    data_path = repo_root / args.data_file
    data = yaml.safe_load(data_path.read_text(encoding="utf-8")) or {}
    packaging = data.get("packaging", {})
    kind_data = packaging.get(args.package_kind)
    if not isinstance(kind_data, dict):
        raise SystemExit(f"Missing packaging entry: {args.package_kind}")
    packages = kind_data.get(args.pkgmgr)
    if not isinstance(packages, list) or not packages:
        raise SystemExit(
            f"Missing packaging packages for {args.package_kind}/{args.pkgmgr}"
        )

    seen = set()
    for package in packages:
        if not isinstance(package, str) or not package:
            raise SystemExit(
                f"Invalid package entry for {args.package_kind}/{args.pkgmgr}: {package!r}"
            )
        if package in seen:
            continue
        seen.add(package)
        print(package)


if __name__ == "__main__":
    main()
