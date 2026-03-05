#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'
[[ -n "${CI:-}" ]] && set -x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
normalization_file="${script_dir}/platform-normalization.yaml"
normalization_resolver="${script_dir}/lib/resolve-platform-normalization.awk"

mode="install"
print_list="0"
report_json_path="${CI_DEPS_REPORT_JSON:-}"
build_tool="${CI_DEPS_BUILD_TOOL:-}"

family=""
os_name=""
version=""
pkgmgr=""
report_pkgmgr=""
target_script=""
target_rc=0

declare -a target_base_args=()
declare -a target_args=()
declare -a tmp_files=()

usage() {
  cat <<'USAGE'
Usage: install-default-packages.sh [--print] [--check-only] [--install]
                                   [--report-json PATH]
                                   [--build-tool make|cmake]

Detect the current OS and dispatch to the matching install-<pkgmgr>-packages.sh
script. When --report-json is provided, also write a JSON report describing:
- requested packages
- packages already present before install
- packages newly installed by the run
- indirect packages added by the package manager

Options:
  --print             Print the resolved package list and exit
  --check-only        Exit 0 if all packages are installed, 1 otherwise
  --install           Install packages (default)
  --report-json PATH  Write dependency state report to PATH
  --build-tool TOOL   Resolve build-specific deps (make|cmake)
USAGE
}

cleanup() {
  local file=""
  if [[ "${#tmp_files[@]}" -eq 0 ]]; then
    return 0
  fi
  for file in "${tmp_files[@]}"; do
    [[ -n "${file}" ]] && rm -f -- "${file}"
  done
}

make_temp() {
  local var_name="${1:-}"
  local file=""

  if [[ -z "${var_name}" ]]; then
    echo "make_temp requires a destination variable name" >&2
    exit 2
  fi

  file="$(mktemp -t install-default-packages.XXXXXX)"
  tmp_files+=("${file}")
  printf -v "${var_name}" '%s' "${file}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)
        print_list="1"
        if [[ "${mode}" == "install" ]]; then
          mode="print"
        fi
        shift
        ;;
      --check-only)
        mode="check"
        shift
        ;;
      --install)
        mode="install"
        shift
        ;;
      --report-json)
        report_json_path="${2:-}"
        shift 2
        ;;
      --report-json=*)
        report_json_path="${1#*=}"
        shift
        ;;
      --build-tool)
        build_tool="${2:-}"
        shift 2
        ;;
      --build-tool=*)
        build_tool="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done

  if [[ -z "${report_json_path}" && -n "${CI_DEPS_REPORT_JSON:-}" ]]; then
    report_json_path="${CI_DEPS_REPORT_JSON}"
  fi
  if [[ -z "${build_tool}" && -n "${CI_DEPS_BUILD_TOOL:-}" ]]; then
    build_tool="${CI_DEPS_BUILD_TOOL}"
  fi
}

detect_linux() {
  if [[ -f /etc/os-release ]]; then
    os_name="$(
      awk -F= '/^ID=/{v=$2; gsub(/"/,"",v); print tolower(v); exit}' /etc/os-release
    )"
    version="$(
      awk -F= '/^VERSION_ID=/{v=$2; gsub(/"/,"",v); print v; exit}' /etc/os-release
    )"
  fi
}

detect_runner_os() {
  case "${RUNNER_OS:-}" in
    macOS)
      os_name="macos"
      version="latest"
      ;;
    Linux|"")
      detect_linux
      ;;
    *)
      echo "Unsupported RUNNER_OS: ${RUNNER_OS}" >&2
      exit 2
      ;;
  esac
}

bsd_default_pkgmgr_for_os_local() {
  case "$1" in
    freebsd) printf 'pkg\n' ;;
    netbsd|openbsd) printf 'pkg_add\n' ;;
    *)
      return 1
      ;;
  esac
}

resolve_normalized_platform() {
  local normalized=""

  if [[ ! -f "${normalization_file}" ]]; then
    echo "Missing platform normalization file: ${normalization_file}" >&2
    exit 2
  fi
  if [[ ! -f "${normalization_resolver}" ]]; then
    echo "Missing platform normalization resolver: ${normalization_resolver}" >&2
    exit 2
  fi

  normalized="$(
    awk \
      -v RULES_FILE="${normalization_file}" \
      -v OS_ID="${os_name}" \
      -v VERSION="${version}" \
      -f "${normalization_resolver}"
  )" || {
    echo "Unsupported or unknown OS ID: ${os_name}" >&2
    exit 2
  }

  IFS='|' read -r family os_name pkgmgr version <<< "${normalized}"
  if [[ -z "${family}" || -z "${os_name}" || -z "${pkgmgr}" ]]; then
    echo "Invalid platform normalization for OS ID: ${os_name}" >&2
    exit 2
  fi
}

resolve_target_script() {
  if [[ -z "${family}" ]]; then
    if [[ -z "${os_name}" ]]; then
      os_name="$(uname -s 2>/dev/null || true)"
      os_name="$(printf '%s' "${os_name}" | awk '{print tolower($0)}')"
      version="$(uname -r 2>/dev/null || true)"
    fi

    case "${os_name}" in
      netbsd|freebsd|openbsd)
        report_pkgmgr="$(bsd_default_pkgmgr_for_os_local "${os_name}")"
        target_script="${script_dir}/install-bsd-packages.sh"
        target_base_args=(--os "${os_name}")
        if [[ -n "${version}" ]]; then
          target_base_args+=(--version "${version}")
        fi
        return
        ;;
      *)
        resolve_normalized_platform
        ;;
    esac
  fi

  if [[ -z "${version}" ]]; then
    version="latest"
  fi

  report_pkgmgr="${pkgmgr}"
  target_base_args=(--family "${family}" --os "${os_name}" --version "${version}")

  case "${pkgmgr}" in
    apt)
      target_script="${script_dir}/install-apt-packages.sh"
      ;;
    dnf)
      target_script="${script_dir}/install-dnf-packages.sh"
      ;;
    yum)
      target_script="${script_dir}/install-yum-packages.sh"
      ;;
    zypper)
      target_script="${script_dir}/install-zypper-packages.sh"
      ;;
    apk)
      target_script="${script_dir}/install-apk-packages.sh"
      ;;
    pacman)
      target_script="${script_dir}/install-pacman-packages.sh"
      ;;
    brew)
      target_script="${script_dir}/install-brew-packages.sh"
      ;;
    *)
      echo "Unsupported package manager: ${pkgmgr}" >&2
      exit 2
      ;;
  esac
}

build_target_args() {
  target_args=()

  case "${mode}" in
    print)
      target_args+=(--print)
      ;;
    check)
      if [[ "${print_list}" == "1" ]]; then
        target_args+=(--print)
      fi
      target_args+=(--check-only)
      ;;
    install)
      if [[ "${print_list}" == "1" ]]; then
        target_args+=(--print --install)
      fi
      ;;
    *)
      echo "Unsupported mode: ${mode}" >&2
      exit 2
      ;;
  esac

  target_args+=("${target_base_args[@]}")
  if [[ -n "${report_json_path}" ]]; then
    target_args+=(--report-json "${report_json_path}")
  fi
  if [[ -n "${build_tool}" ]]; then
    target_args+=(--build-tool "${build_tool}")
  fi
}

sort_unique_file() {
  local file="${1:-}"
  sort -u "${file}" -o "${file}"
}

extract_pkg_bases_from_pkg_info() {
  local infile="${1:-}"

  awk '
    {
      token = $1
      if (token ~ /^[[:alnum:]_.+-]+-[0-9][[:alnum:]_.+~-]*$/) {
        base = token
        sub(/-[0-9][[:alnum:]_.+~-]*$/, "", base)
        print base
      }
    }
  ' "${infile}"
}

capture_pkg_add_like_packages() {
  local pkg_info_bin="${1:-}"
  local outfile="${2:-}"
  local raw_file=""
  local dbdir=""
  local entry=""
  local base=""

  if [[ -z "${pkg_info_bin}" || -z "${outfile}" ]]; then
    return 2
  fi

  make_temp raw_file

  if [[ -x "${pkg_info_bin}" ]]; then
    if "${pkg_info_bin}" -a > "${raw_file}" 2>/dev/null; then
      extract_pkg_bases_from_pkg_info "${raw_file}" > "${outfile}"
      if [[ -s "${outfile}" ]]; then
        sort_unique_file "${outfile}"
        return 0
      fi
    fi

    # Some pkg_info variants with -q output comments; keep this as fallback only.
    if "${pkg_info_bin}" -q -a > "${raw_file}" 2>/dev/null; then
      extract_pkg_bases_from_pkg_info "${raw_file}" > "${outfile}"
      if [[ -s "${outfile}" ]]; then
        sort_unique_file "${outfile}"
        return 0
      fi
    fi
  fi

  : > "${outfile}"
  for dbdir in /var/db/pkg /usr/pkg/pkgdb /usr/pkgdb; do
    [[ -d "${dbdir}" ]] || continue
    for entry in "${dbdir}"/*; do
      [[ -d "${entry}" ]] || continue
      base="$(basename "${entry}" | sed -E 's/-[0-9][[:alnum:]_.+~-]*$//')"
      [[ -n "${base}" ]] && printf '%s\n' "${base}" >> "${outfile}"
    done
    if [[ -s "${outfile}" ]]; then
      sort_unique_file "${outfile}"
      return 0
    fi
  done

  return 2
}

capture_installed_packages() {
  local outfile="${1:-}"

  case "${report_pkgmgr}" in
    apt)
      dpkg-query -W -f='${Package}\n' > "${outfile}"
      ;;
    dnf|yum|zypper)
      rpm -qa --qf '%{NAME}\n' > "${outfile}"
      ;;
    apk)
      apk info > "${outfile}"
      ;;
    pacman)
      pacman -Qq > "${outfile}"
      ;;
    brew)
      brew list --formula > "${outfile}"
      ;;
    pkg)
      /usr/sbin/pkg query '%n' > "${outfile}"
      ;;
    pkg_add)
      capture_pkg_add_like_packages /usr/sbin/pkg_info "${outfile}"
      ;;
    pkgin)
      capture_pkg_add_like_packages /usr/pkg/bin/pkg_info "${outfile}"
      ;;
    *)
      echo "Package inventory is not supported for package manager: ${report_pkgmgr}" >&2
      return 2
      ;;
  esac

  sort_unique_file "${outfile}"
}

capture_requested_packages() {
  local outfile="${1:-}"

  "${target_script}" --print "${target_base_args[@]}" > "${outfile}"
  sort_unique_file "${outfile}"
}

capture_missing_packages() {
  local outfile="${1:-}"
  local rc=0

  : > "${outfile}"
  if "${target_script}" --print --check-only "${target_base_args[@]}" > "${outfile}"; then
    :
  else
    rc=$?
    if [[ "${rc}" -ne 1 ]]; then
      return "${rc}"
    fi
  fi

  sort_unique_file "${outfile}"
}

sorted_file_diff() {
  local left="${1:-}"
  local right="${2:-}"
  local outfile="${3:-}"

  comm -23 "${left}" "${right}" > "${outfile}"
}

count_file_lines() {
  local file="${1:-}"
  awk 'END { print NR + 0 }' "${file}"
}

json_escape() {
  local value="${1:-}"
  local xtrace_was_on=0

  if [[ "${-}" == *x* ]]; then
    xtrace_was_on=1
    set +x
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"

  printf '%s' "${value}"

  if [[ "${xtrace_was_on}" == "1" ]]; then
    set -x
  fi
}

write_json_string_field() {
  local outfile="${1:-}"
  local key="${2:-}"
  local value="${3:-}"
  local trailing="${4:-1}"

  printf '  "%s": "%s"' "$(json_escape "${key}")" "$(json_escape "${value}")" >> "${outfile}"
  if [[ "${trailing}" == "1" ]]; then
    printf ',\n' >> "${outfile}"
  else
    printf '\n' >> "${outfile}"
  fi
}

write_json_number_field() {
  local outfile="${1:-}"
  local key="${2:-}"
  local value="${3:-0}"
  local trailing="${4:-1}"

  printf '  "%s": %s' "$(json_escape "${key}")" "${value}" >> "${outfile}"
  if [[ "${trailing}" == "1" ]]; then
    printf ',\n' >> "${outfile}"
  else
    printf '\n' >> "${outfile}"
  fi
}

write_json_array_field() {
  local outfile="${1:-}"
  local key="${2:-}"
  local file="${3:-}"
  local trailing="${4:-1}"
  local first="1"
  local item=""

  printf '  "%s": [' "$(json_escape "${key}")" >> "${outfile}"
  while IFS= read -r item || [[ -n "${item}" ]]; do
    [[ -n "${item}" ]] || continue
    if [[ "${first}" == "0" ]]; then
      printf ', ' >> "${outfile}"
    fi
    printf '"%s"' "$(json_escape "${item}")" >> "${outfile}"
    first="0"
  done < "${file}"
  printf ']' >> "${outfile}"
  if [[ "${trailing}" == "1" ]]; then
    printf ',\n' >> "${outfile}"
  else
    printf '\n' >> "${outfile}"
  fi
}

write_json_report() {
  local outfile="${1:-}"
  local requested_file="${2:-}"
  local present_before_file="${3:-}"
  local missing_before_file="${4:-}"
  local direct_new_file="${5:-}"
  local missing_after_file="${6:-}"
  local all_new_file="${7:-}"
  local indirect_new_file="${8:-}"
  local command_status="success"

  if [[ "${target_rc}" -ne 0 ]]; then
    if [[ "${mode}" == "check" ]]; then
      command_status="missing"
    else
      command_status="failed"
    fi
  fi

  mkdir -p "$(dirname "${outfile}")"
  : > "${outfile}"

  printf '{\n' >> "${outfile}"
  write_json_string_field "${outfile}" "mode" "${mode}"
  write_json_string_field "${outfile}" "status" "${command_status}"
  write_json_number_field "${outfile}" "command_exit_code" "${target_rc}"
  write_json_string_field "${outfile}" "variant" "${VARIANT:-server}"
  write_json_string_field "${outfile}" "enable_ldap" "${ENABLE_LDAP:-ON}"
  write_json_string_field "${outfile}" "enable_snmp" "${ENABLE_SNMP:-ON}"
  write_json_string_field "${outfile}" "family" "${family:-bsd}"
  write_json_string_field "${outfile}" "os" "${os_name}"
  write_json_string_field "${outfile}" "version" "${version}"
  write_json_string_field "${outfile}" "package_manager" "${report_pkgmgr}"
  write_json_array_field "${outfile}" "requested_packages" "${requested_file}"
  write_json_array_field "${outfile}" "requested_already_present" "${present_before_file}"
  write_json_array_field "${outfile}" "requested_missing_before" "${missing_before_file}"
  write_json_array_field "${outfile}" "requested_newly_installed" "${direct_new_file}"
  write_json_array_field "${outfile}" "requested_missing_after" "${missing_after_file}"
  write_json_array_field "${outfile}" "all_newly_installed" "${all_new_file}"
  write_json_array_field "${outfile}" "indirect_newly_installed" "${indirect_new_file}"
  printf '  "counts": {\n' >> "${outfile}"
  printf '    "requested_packages": %s,\n' "$(count_file_lines "${requested_file}")" >> "${outfile}"
  printf '    "requested_already_present": %s,\n' "$(count_file_lines "${present_before_file}")" >> "${outfile}"
  printf '    "requested_missing_before": %s,\n' "$(count_file_lines "${missing_before_file}")" >> "${outfile}"
  printf '    "requested_newly_installed": %s,\n' "$(count_file_lines "${direct_new_file}")" >> "${outfile}"
  printf '    "requested_missing_after": %s,\n' "$(count_file_lines "${missing_after_file}")" >> "${outfile}"
  printf '    "all_newly_installed": %s,\n' "$(count_file_lines "${all_new_file}")" >> "${outfile}"
  printf '    "indirect_newly_installed": %s\n' "$(count_file_lines "${indirect_new_file}")" >> "${outfile}"
  printf '  },\n' >> "${outfile}"
  write_json_string_field "${outfile}" "unneeded_packages_status" "undetermined" "0"
  printf '}\n' >> "${outfile}"
}

run_with_report() {
  local installed_before_file=""
  local installed_after_file=""
  local requested_file=""
  local missing_before_file=""
  local missing_after_file=""
  local present_before_file=""
  local direct_new_file=""
  local all_new_file=""
  local indirect_new_file=""

  make_temp installed_before_file
  make_temp installed_after_file
  make_temp requested_file
  make_temp missing_before_file
  make_temp missing_after_file
  make_temp present_before_file
  make_temp direct_new_file
  make_temp all_new_file
  make_temp indirect_new_file

  capture_installed_packages "${installed_before_file}"
  capture_requested_packages "${requested_file}"
  capture_missing_packages "${missing_before_file}"
  sorted_file_diff "${requested_file}" "${missing_before_file}" "${present_before_file}"

  build_target_args
  target_rc=0
  if ! "${target_script}" "${target_args[@]}"; then
    target_rc=$?
  fi

  capture_installed_packages "${installed_after_file}"
  capture_missing_packages "${missing_after_file}"
  sorted_file_diff "${missing_before_file}" "${missing_after_file}" "${direct_new_file}"
  sorted_file_diff "${installed_after_file}" "${installed_before_file}" "${all_new_file}"
  sorted_file_diff "${all_new_file}" "${direct_new_file}" "${indirect_new_file}"

  write_json_report \
    "${report_json_path}" \
    "${requested_file}" \
    "${present_before_file}" \
    "${missing_before_file}" \
    "${direct_new_file}" \
    "${missing_after_file}" \
    "${all_new_file}" \
    "${indirect_new_file}"

  return "${target_rc}"
}

main() {
  parse_args "$@"
  trap cleanup EXIT

  detect_runner_os
  resolve_target_script

  build_target_args
  exec "${target_script}" "${target_args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
