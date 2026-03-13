#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker is unavailable"
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

wrapper="${tmpdir}/cmake"
log="${tmpdir}/cmake.log"

cat >"${wrapper}" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "cmake version 3.23.0"
  exit 0
fi
for arg in "$@"; do
  printf '%s\n' "$arg"
done > /work/cmake.log
EOF
chmod +x "${wrapper}"

docker run --rm \
  --platform linux/amd64 \
  -v "${repo_root}:/repo:ro" \
  -v "${tmpdir}:/work" \
  -w /repo \
  centos:7 \
  bash -lc '
    set -euo pipefail
    export PATH="/work:${PATH}"
    PROFILE=default \
    PLATFORM_OS=linux \
    ENABLE_SSL=ON \
    ENABLE_LDAP=ON \
    VARIANT=server \
    LOCALCLIENT=OFF \
    bash ci/run/cmake-configure.sh
  '

if [ ! -f "${log}" ]; then
  echo "FAIL: cmake wrapper log was not created" >&2
  exit 1
fi

grep -Fx -- "--preset" "${log}" >/dev/null 2>&1 || {
  echo "FAIL: expected --preset invocation" >&2
  sed -n '1,120p' "${log}" >&2
  exit 1
}

grep -Fx -- "default" "${log}" >/dev/null 2>&1 || {
  echo "FAIL: expected default preset" >&2
  sed -n '1,120p' "${log}" >&2
  exit 1
}
