#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

execution_out="${tmpdir}/execution.out"
compare_err="${tmpdir}/compare.err"
context_out="${tmpdir}/context.out"

(
  cd "${repo_root}"
  python3 ci/run/ref/resolve-execution-model.py \
    --requested-build-tool auto \
    --requested-compiler auto \
    --requested-profile auto \
    --requested-install-mode auto \
    --requested-verify-depth build \
    --goal compare \
    --ref-mode off \
    --publish artifact \
    --allow-failure-mode off \
    > "${execution_out}"
)

grep -Fx "goal=compare" "${execution_out}" >/dev/null || fail "missing goal=compare"
grep -Fx "ref_mode=off" "${execution_out}" >/dev/null || fail "missing ref_mode=off"
grep -Fx "build_tool=cmake" "${execution_out}" >/dev/null || fail "compare should default to build_tool=cmake"
grep -Fx "verify_depth=install" "${execution_out}" >/dev/null || fail "compare should force verify_depth=install"
grep -Fx "dep_mode=compare" "${execution_out}" >/dev/null || fail "compare should resolve dep_mode=compare"

if (
  cd "${repo_root}"
  python3 ci/run/ref/resolve-execution-model.py \
    --requested-build-tool cmake \
    --requested-compiler auto \
    --requested-profile auto \
    --requested-install-mode auto \
    --requested-verify-depth install \
    --goal compare \
    --ref-mode generate \
    --publish artifact \
    --allow-failure-mode off \
    > /dev/null 2> "${compare_err}"
); then
  fail "goal=compare unexpectedly accepted ref_mode=generate"
fi

grep -F "goal=compare requires ref_mode=off" "${compare_err}" >/dev/null \
  || fail "unexpected validation error for compare mode"

lane_json='{
  "build_tool": "cmake",
  "compiler": "gcc",
  "profile": "default",
  "install_mode": "source",
  "name": "Compare lane",
  "variant": "server",
  "runtime": "linux_container",
  "ref_os": "linux",
  "artifact_family": "linux",
  "baseline_root": "make__linux",
  "platform_id": "alpine-3_23",
  "platform_os": "alpine",
  "artifact_arch": "amd64"
}'

(
  cd "${repo_root}"
  python3 ci/run/ref/resolve-lane-context.py \
    --lane-json "${lane_json}" \
    --verify-depth build \
    --goal compare \
    --ref-mode off \
    --publish artifact \
    --allow-failure-mode off \
    > "${context_out}"
)

python3 - "${context_out}" <<'PY'
import json
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
payload = {}
for line in lines:
    key, value = line.split("=", 1)
    payload[key] = value

lane_env = json.loads(payload["lane_env_json"])
lane_post = json.loads(payload["lane_post_json"])

assert lane_env["GOAL"] == "compare", lane_env
assert lane_env["REF_MODE"] == "off", lane_env
assert lane_env["DEP_MODE"] == "compare", lane_env
assert lane_env["VERIFY_DEPTH"] == "install", lane_env
assert lane_env["BASELINE_PREFIX"].endswith("/make/linux/alpine-3_23/server/amd64"), lane_env
assert lane_post["goal"] == "compare", lane_post
assert lane_post["dep_mode"] == "compare", lane_post
PY
