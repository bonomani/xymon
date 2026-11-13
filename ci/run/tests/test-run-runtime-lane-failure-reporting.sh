#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
real_bash="$(command -v bash)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

stderr_file="${tmpdir}/stderr.log"
stdout_file="${tmpdir}/stdout.log"
bash_wrapper="${tmpdir}/bash"

cat >"${bash_wrapper}" <<EOF
#!${real_bash}
if [[ "\${1:-}" == "ci/run/ref/run-ref-lane-command.sh" ]]; then
  exit 23
fi
exec "${real_bash}" "\$@"
EOF
chmod +x "${bash_wrapper}"

status=0
if (
  cd "${repo_root}"
  PATH="${tmpdir}:${PATH}" \
  RUNTIME=macos_host \
  RUNTIME_PREFERENCE=macos_host \
  RUNTIME_EXECUTION=host \
  BUILD_TOOL=cmake \
  GOAL=verify \
  VERIFY_DEPTH=configure \
  REF_MODE=off \
  PUBLISH=none \
  DEP_MODE=generate \
  CI_DEPS_REPORT_JSON="${tmpdir}/deps-report.json" \
  CI_COMPILER=clang \
  INSTALL_MODE=source \
  PROFILE=default \
  VARIANT=server \
  REF_OS=macos \
  PLATFORM_OS=macos \
  PLATFORM_ID=macos-26 \
    "${real_bash}" ci/run/ref/run-runtime-lane.sh >"${stdout_file}" 2>"${stderr_file}"
); then
  fail "run-runtime-lane.sh unexpectedly succeeded"
else
  status=$?
fi

if [[ "${status}" -ne 23 ]]; then
  fail "expected run-runtime-lane.sh to preserve exit code 23, got ${status}"
fi

if grep -F -- "No viable runtime found" "${stderr_file}" >/dev/null 2>&1; then
  fail "run-runtime-lane.sh reported an unavailable runtime instead of the real lane failure"
fi
