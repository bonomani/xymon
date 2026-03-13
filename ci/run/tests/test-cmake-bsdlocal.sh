#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains_line() {
  local file="$1"
  local expected="$2"
  if ! grep -Fx -- "$expected" "$file" >/dev/null 2>&1; then
    echo "Missing expected line in ${file}: ${expected}" >&2
    sed -n '1,200p' "$file" >&2 || true
    exit 1
  fi
}

assert_file_contains_text() {
  local file="$1"
  local expected="$2"
  if ! grep -F -- "$expected" "$file" >/dev/null 2>&1; then
    echo "Missing expected text in ${file}: ${expected}" >&2
    sed -n '1,200p' "$file" >&2 || true
    exit 1
  fi
}

test_cmake_configure_fallback_bsdlocal() {
  local tmpdir
  local log
  local wrapper

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  log="${tmpdir}/cmake.log"
  wrapper="${tmpdir}/cmake"

  cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "cmake version 3.22.9"
  exit 0
fi
for arg in "\$@"; do
  printf '%s\n' "\$arg"
done >"${log}"
exit 0
EOF
  chmod +x "${wrapper}"

  (
    cd "${repo_root}"
    PATH="${tmpdir}:${PATH}" \
      PROFILE=bsdlocal \
      PLATFORM_OS=linux \
      XYMON_BSD_LOCALBASE=/opt/local \
      XYMON_BSD_LOCALSTATEDIR=/var/db \
      ENABLE_SSL=ON \
      ENABLE_LDAP=ON \
      VARIANT=server \
      LOCALCLIENT=OFF \
      bash ci/run/cmake-configure.sh
  )

  assert_file_contains_line "${log}" "-S"
  assert_file_contains_line "${log}" "."
  assert_file_contains_line "${log}" "-B"
  assert_file_contains_line "${log}" "build-cmake-bsdlocal"
  assert_file_contains_line "${log}" "-DUSE_GNUINSTALLDIRS=OFF"
  assert_file_contains_line "${log}" "-DXYMON_LAYOUT=bsd_local"
  assert_file_contains_line "${log}" "-DCMAKE_INSTALL_PREFIX=/usr/local"
  assert_file_contains_line "${log}" "-DXYMON_BSD_LOCALBASE=/opt/local"
  assert_file_contains_line "${log}" "-DXYMON_BSD_LOCALSTATEDIR=/var/db"

  if grep -Fx -- "--preset" "${log}" >/dev/null 2>&1; then
    fail "fallback path unexpectedly used --preset"
  fi

  trap - RETURN
  rm -rf "${tmpdir}"
}

test_cmake_configure_preset_bsdlocal_overrides() {
  local tmpdir
  local log
  local wrapper

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  log="${tmpdir}/cmake.log"
  wrapper="${tmpdir}/cmake"

  cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  echo "cmake version 3.23.0"
  exit 0
fi
for arg in "\$@"; do
  printf '%s\n' "\$arg"
done >"${log}"
exit 0
EOF
  chmod +x "${wrapper}"

  (
    cd "${repo_root}"
    PATH="${tmpdir}:${PATH}" \
      PROFILE=bsdlocal \
      PLATFORM_OS=linux \
      XYMON_BSD_LOCALBASE=/opt/local \
      XYMON_BSD_LOCALSTATEDIR=/var/db \
      ENABLE_SSL=ON \
      ENABLE_LDAP=ON \
      VARIANT=server \
      LOCALCLIENT=OFF \
      bash ci/run/cmake-configure.sh
  )

  assert_file_contains_line "${log}" "--preset"
  assert_file_contains_line "${log}" "bsdlocal"
  assert_file_contains_line "${log}" "-DXYMON_BSD_LOCALBASE=/opt/local"
  assert_file_contains_line "${log}" "-DXYMON_BSD_LOCALSTATEDIR=/var/db"

  trap - RETURN
  rm -rf "${tmpdir}"
}

test_bsdlocal_configurable_roots() {
  local build_dir

  build_dir="$(mktemp -d)"
  trap 'rm -rf "${build_dir}"' RETURN

  (
    cd "${repo_root}"
    cmake -S . -B "${build_dir}" \
      -G "Unix Makefiles" \
      -DXYMON_LAYOUT=bsd_local \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DXYMON_BSD_LOCALBASE=/opt/local \
      -DXYMON_BSD_LOCALSTATEDIR=/var/db \
      -DXYMON_VARIANT=server \
      -DLOCALCLIENT=OFF \
      -DENABLE_SSL=ON \
      -DENABLE_LDAP=ON >/dev/null
  )

  assert_file_contains_text "${build_dir}/CMakeCache.txt" "CMAKE_INSTALL_PREFIX:PATH=/usr/local"
  assert_file_contains_text "${build_dir}/xymond/etcfiles/xymonserver.cfg" "/opt/local/etc/xymon"
  assert_file_contains_text "${build_dir}/xymond/etcfiles/xymonserver.cfg" "/opt/local/libexec/xymon/server"
  assert_file_contains_text "${build_dir}/xymond/etcfiles/xymonserver.cfg" "/var/db/xymon"
  assert_file_contains_text "${build_dir}/xymond/xymon.sh" "/opt/local/libexec/xymon/server"
  assert_file_contains_text "${build_dir}/xymond/xymon.sh" "/var/db/log/xymon"

  trap - RETURN
  rm -rf "${build_dir}"
}

test_cmake_configure_fallback_bsdlocal
test_cmake_configure_preset_bsdlocal_overrides
test_bsdlocal_configurable_roots
