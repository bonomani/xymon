#!/usr/bin/env bash
set -euo pipefail

build_dir="${BUILD_DIR:?BUILD_DIR is required}"
non_interactive="${NON_INTERACTIVE:-0}"
build_install="${BUILD_INSTALL:-1}"
destdir_override="${DESTDIR_OVERRIDE:-}"
use_ci_configure="${USE_CI_CONFIGURE:-0}"
preset_override="${PRESET_OVERRIDE:-}"
root_dir="${ROOT_DIR:-$(pwd)}"

normalize_onoff() {
  local val="$1"
  case "${val^^}" in
    ON|YES|Y|TRUE|1) printf 'ON' ;;
    OFF|NO|N|FALSE|0) printf 'OFF' ;;
    *) printf '%s' "${val}" ;;
  esac
}

if [[ "${use_ci_configure}" == "1" && -n "${preset_override}" ]]; then
  preset_build_dir="$(
    python - "${preset_override}" "${root_dir}" <<'PY'
import json
import sys
from pathlib import Path
preset_name = sys.argv[1]
preset_root = sys.argv[2]
preset = Path("CMakePresets.json")
if not preset.exists():
    print("")
    raise SystemExit(0)
data = json.loads(preset.read_text())
for entry in data.get("configurePresets", []):
    if entry.get("name") == preset_name:
        val = entry.get("binaryDir", "")
        if "${sourceDir}" in val:
            val = val.replace("${sourceDir}", preset_root)
        print(val)
        raise SystemExit(0)
print("")
PY
  )"
  if [[ -n "${preset_build_dir}" ]]; then
    build_dir="${preset_build_dir}"
  fi
fi

if [[ "${build_install}" == "1" ]]; then
  install_cmd=(cmake --install "${build_dir}")
  if [[ -n "${destdir_override}" ]]; then
    export DESTDIR="${destdir_override}"
  fi
  if [[ "${non_interactive}" != "1" ]]; then
    read -r -p "Install now? [y/N]: " install_confirm
    install_confirm="$(normalize_onoff "${install_confirm}")"
    if [[ "${install_confirm}" == "ON" ]]; then
      "${install_cmd[@]}"
    else
      echo "Install skipped."
    fi
  else
    "${install_cmd[@]}"
  fi
fi
