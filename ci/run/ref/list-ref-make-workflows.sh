#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="${script_dir}/ref-make-families.yml"

python3 - "${manifest}" <<'PY'
import sys
from pathlib import Path

import yaml

manifest_path = Path(sys.argv[1])
data = yaml.safe_load(manifest_path.read_text()) or {}
families = data.get("families", [])
if not isinstance(families, list):
    raise SystemExit(f"Invalid families list in manifest: {manifest_path}")

for entry in families:
    if not isinstance(entry, dict) or not isinstance(entry.get("family"), str):
        raise SystemExit(f"Invalid family entry in manifest: {manifest_path}")
    print(f"ref-make-{entry['family']}.yml")
PY
