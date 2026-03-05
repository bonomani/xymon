#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: packages-from-yaml.sh --variant server|client|localclient --family FAMILY --os OS --pkgmgr PKG [--build-tool make|cmake] [--enable-ldap ON|OFF] [--enable-snmp ON|OFF]
Print the mandatory dependency list for the requested configuration.
USAGE
  exit 2
}

normalize_onoff() {
  local val="$1"
  local default_val="$2"
  if [[ -z "${val}" ]]; then
    printf '%s' "$default_val"
    return
  fi
  val="$(printf '%s' "${val}" | tr '[:lower:]' '[:upper:]')"
  case "$val" in
    ON|YES|Y|TRUE|1)
      printf 'ON'
      ;;
    OFF|NO|N|FALSE|0)
      printf 'OFF'
      ;;
    *)
      printf '%s' "$val"
      ;;
  esac
}

variant=""
family=""
os_name=""
pkgmgr=""
build_tool="${CI_DEPS_BUILD_TOOL:-}"
enable_ldap=""
enable_snmp=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      variant="$2"
      shift 2
      ;;
    --variant=*)
      variant="${1#*=}"
      shift
      ;;
    --family)
      family="$2"
      shift 2
      ;;
    --family=*)
      family="${1#*=}"
      shift
      ;;
    --os)
      os_name="$2"
      shift 2
      ;;
    --os=*)
      os_name="${1#*=}"
      shift
      ;;
    --pkgmgr)
      pkgmgr="$2"
      shift 2
      ;;
    --pkgmgr=*)
      pkgmgr="${1#*=}"
      shift
      ;;
    --build-tool)
      build_tool="$2"
      shift 2
      ;;
    --build-tool=*)
      build_tool="${1#*=}"
      shift
      ;;
    --enable-ldap)
      enable_ldap="$2"
      shift 2
      ;;
    --enable-ldap=*)
      enable_ldap="${1#*=}"
      shift
      ;;
    --enable-snmp)
      enable_snmp="$2"
      shift 2
      ;;
    --enable-snmp=*)
      enable_snmp="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "${variant}" || -z "${family}" || -z "${os_name}" || -z "${pkgmgr}" ]]; then
  usage
fi

case "${variant}" in
  server|client|localclient)
    ;;
  *)
    echo "Unknown variant: ${variant}" >&2
    exit 2
    ;;
esac

build_tool="$(printf '%s' "${build_tool}" | tr '[:upper:]' '[:lower:]')"
case "${build_tool}" in
  ""|default)
    build_tool=""
    ;;
  make|gmake)
    build_tool="make"
    ;;
  cmake)
    ;;
  *)
    echo "Unknown build tool: ${build_tool}" >&2
    exit 2
    ;;
esac

enable_ldap="$(normalize_onoff "${enable_ldap}" "OFF")"
enable_snmp="$(normalize_onoff "${enable_snmp}" "OFF")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${script_dir}/data"
deps_file="${data_dir}/deps-${variant}.yaml"
targets_file="${data_dir}/deps-targets.yaml"
dep_map_file="${data_dir}/deps-map.yaml"
base_file=""
overlay_file=""
overlay_variant=""

if [[ ! -f "${deps_file}" ]]; then
  echo "Dependency file missing: ${deps_file}" >&2
  exit 1
fi

read_top_level_key() {
  local src_file="${1:-}"
  local wanted_key="${2:-}"
  awk -v WANTED_KEY="${wanted_key}" '
    function trim(val) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      return val
    }
    function dequote(val) {
      if ((val ~ /^".*"$/) || (val ~ /^\047.*\047$/)) {
        return substr(val, 2, length(val) - 2)
      }
      return val
    }
    {
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      indent = match($0, /[^ ]/) - 1
      if (indent < 0) indent = 0
      if (indent != 0) next
      line = substr($0, indent + 1)
      sep_pos = index(line, ":")
      if (sep_pos <= 0) next
      key = trim(substr(line, 1, sep_pos - 1))
      value = trim(substr(line, sep_pos + 1))
      value = dequote(value)
      if (key == WANTED_KEY && value != "") {
        print value
        exit
      }
    }
  ' "${src_file}"
}

deprecated_topology_ref="$(read_top_level_key "${deps_file}" "topology")"
if [[ -n "${deprecated_topology_ref}" ]]; then
  echo "Deprecated key 'topology' found in ${deps_file}; use 'targets_file' (strict v2)." >&2
  exit 1
fi

deprecated_bindings_ref="$(read_top_level_key "${deps_file}" "bindings_file")"
if [[ -n "${deprecated_bindings_ref}" ]]; then
  echo "Deprecated key 'bindings_file' found in ${deps_file}; strict v2 uses targets only." >&2
  exit 1
fi

targets_ref="$(read_top_level_key "${deps_file}" "targets_file")"
if [[ -z "${targets_ref}" ]]; then
  echo "Strict v2 requires targets_file in ${deps_file}" >&2
  exit 1
fi
targets_file="${data_dir}/${targets_ref}"

base_ref="$(read_top_level_key "${deps_file}" "base_file")"
if [[ -n "${base_ref}" ]]; then
  base_file="${data_dir}/${base_ref}"
fi

overlay_ref="$(read_top_level_key "${deps_file}" "overlay_file")"
if [[ -n "${overlay_ref}" ]]; then
  overlay_file="${data_dir}/${overlay_ref}"
fi

overlay_variant_ref="$(read_top_level_key "${deps_file}" "overlay_variant")"
if [[ -n "${overlay_variant_ref}" ]]; then
  overlay_variant="${overlay_variant_ref}"
fi

if [[ ! -f "${targets_file}" ]]; then
  echo "Dependency targets file missing: ${targets_file}" >&2
  exit 1
fi
if [[ -z "${base_file}" || -z "${overlay_file}" || -z "${overlay_variant}" ]]; then
  echo "Strict v2 requires base_file + overlay_file + overlay_variant in ${deps_file}" >&2
  exit 1
fi
if [[ ! -f "${base_file}" ]]; then
  echo "Dependency base file missing: ${base_file}" >&2
  exit 1
fi
if [[ ! -f "${overlay_file}" ]]; then
  echo "Dependency overlay file missing: ${overlay_file}" >&2
  exit 1
fi

tmp_files=()
cleanup() {
  for file in "${tmp_files[@]:-}"; do
    [[ -n "${file}" ]] && rm -f -- "${file}"
  done
}
trap cleanup EXIT

make_temp() {
  mktemp -t packages-from-yaml.XXXXXX
}

items_meta_file="$(make_temp)"
tmp_files+=("${items_meta_file}")

if ! awk -v FAMILY="${family}" -v OS="${os_name}" -v PKGMGR="${pkgmgr}" '
  function trim(val) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
  }
  function dequote(val) {
    if ((val ~ /^".*"$/) || (val ~ /^\047.*\047$/)) {
      return substr(val, 2, length(val) - 2)
    }
    return val
  }
  function set_key(key, depth) {
    keys[depth] = key
    for (i = depth + 1; i < 64; ++i) delete keys[i]
  }
  {
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next

    indent = match($0, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)
    line = substr($0, indent + 1)

    if (list_context != "" && line !~ /^-/ && indent <= list_indent) {
      list_context = ""
    }

    if (line ~ /^-/) {
      item = trim(substr(line, 2))
      if (item != "") {
        if (list_context == "target") {
          print "TARGET_ITEM\t" item
        }
      }
      next
    }

    sep_pos = index(line, ":")
    if (sep_pos <= 0) next

    key = trim(substr(line, 1, sep_pos - 1))
    value = trim(substr(line, sep_pos + 1))
    value = dequote(value)
    set_key(key, depth)

    if (keys[0] == "targets" && keys[1] == FAMILY && keys[2] == OS && key == "profile") {
      if (value != "") print "TARGET_PROFILE\t" value
    }

    if (keys[0] == "targets" && keys[1] == FAMILY && keys[2] == OS && keys[3] == "packagers" && keys[4] == PKGMGR && keys[5] == "libs" && key == "mandatory") {
      list_context = "target"
      list_indent = indent
      next
    }
  }
' "${targets_file}" > "${items_meta_file}"; then
  exit 1
fi

parse_profile_items() {
  local source_file="${1:-}"
  local record_tag="${2:-PROFILE_ITEM}"
  awk -v REC="${record_tag}" '
  function trim(val) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
  }
  function set_key(key, depth) {
    keys[depth] = key
    for (i = depth + 1; i < 64; ++i) delete keys[i]
  }
  {
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next

    indent = match($0, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)
    line = substr($0, indent + 1)

    if (list_context != "" && line !~ /^-/ && indent <= list_indent) {
      list_context = ""
    }

    if (line ~ /^-/) {
      item = trim(substr(line, 2))
      if (item != "" && index(list_context, "profile:") == 1) {
        profile_name = substr(list_context, 9)
        print REC "\t" profile_name "\t" item
      }
      next
    }

    sep_pos = index(line, ":")
    if (sep_pos <= 0) next

    key = trim(substr(line, 1, sep_pos - 1))
    set_key(key, depth)

    if (keys[0] == "profiles" && keys[2] == "libs" && key == "mandatory") {
      profile_name = keys[1]
      if (profile_name != "") {
        list_context = "profile:" profile_name
        list_indent = indent
      }
      next
    }
  }
  ' "${source_file}" >> "${items_meta_file}"
}

parse_overlay_profile_items() {
  local source_file="${1:-}"
  local selected_variant="${2:-}"
  awk -v VARIANT="${selected_variant}" '
  function trim(val) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
  }
  function set_key(key, depth) {
    keys[depth] = key
    for (i = depth + 1; i < 64; ++i) delete keys[i]
  }
  {
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next

    indent = match($0, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)
    line = substr($0, indent + 1)

    if (list_context != "" && line !~ /^-/ && indent <= list_indent) {
      list_context = ""
    }

    if (line ~ /^-/) {
      item = trim(substr(line, 2))
      if (item != "" && index(list_context, "profile_add:") == 1) {
        profile_name = substr(list_context, 13)
        print "PROFILE_ITEM_OVERLAY_ADD\t" profile_name "\t" item
      }
      if (item != "" && index(list_context, "profile_remove:") == 1) {
        profile_name = substr(list_context, 16)
        print "PROFILE_ITEM_OVERLAY_REMOVE\t" profile_name "\t" item
      }
      next
    }

    sep_pos = index(line, ":")
    if (sep_pos <= 0) next

    key = trim(substr(line, 1, sep_pos - 1))
    set_key(key, depth)

    if (keys[0] == "variants" && keys[1] == VARIANT && keys[2] == "profiles" && keys[4] == "libs" && keys[5] == "mandatory" && key == "add") {
      profile_name = keys[3]
      if (profile_name != "") {
        list_context = "profile_add:" profile_name
        list_indent = indent
      }
      next
    }
    if (keys[0] == "variants" && keys[1] == VARIANT && keys[2] == "profiles" && keys[4] == "libs" && keys[5] == "mandatory" && key == "remove") {
      profile_name = keys[3]
      if (profile_name != "") {
        list_context = "profile_remove:" profile_name
        list_indent = indent
      }
      next
    }
  }
  ' "${source_file}" >> "${items_meta_file}"
}

if ! parse_profile_items "${base_file}" "PROFILE_ITEM_BASE"; then
  exit 1
fi
if ! parse_overlay_profile_items "${overlay_file}" "${overlay_variant}"; then
  exit 1
fi

if ! awk -v FAMILY="${family}" -v OS="${os_name}" -v PKGMGR="${pkgmgr}" '
  function trim(val) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
  }
  function set_key(key, depth) {
    keys[depth] = key
    for (i = depth + 1; i < 64; ++i) delete keys[i]
  }
  {
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
    indent = match($0, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)
    line = substr($0, indent + 1)
    sep_pos = index(line, ":")
    if (sep_pos <= 0) next
    key = trim(substr(line, 1, sep_pos - 1))
    set_key(key, depth)
    if (keys[0] == "targets" && keys[1] == FAMILY && keys[2] == OS && keys[3] == "packagers" && key == PKGMGR) {
      found = 1
    }
  }
  END {
    if (found != 1) {
      print "Failed to locate topology for family=" FAMILY " os=" OS " pkgmgr=" PKGMGR > "/dev/stderr"
      exit 1
    }
  }
' "${targets_file}"; then
  exit 1
fi

items=()
target_profile=""
while IFS=$'\t' read -r rec a b; do
  case "${rec}" in
    TARGET_ITEM)
      [[ -n "${a}" ]] && items+=("${a}")
      ;;
    TARGET_PROFILE)
      target_profile="${a}"
      ;;
  esac
done < "${items_meta_file}"

if [[ "${#items[@]}" -eq 0 ]]; then
  if [[ -z "${target_profile}" ]]; then
    echo "Failed to locate package list for family=${family} os=${os_name} pkgmgr=${pkgmgr}" >&2
    exit 1
  fi

  profile_items_base=()
  profile_items_overlay_add=()
  profile_items_overlay_remove=()
  while IFS=$'\t' read -r rec profile_name profile_item; do
    case "${rec}" in
      PROFILE_ITEM_BASE)
        if [[ "${profile_name}" == "${target_profile}" && -n "${profile_item}" ]]; then
          profile_items_base+=("${profile_item}")
        fi
        ;;
      PROFILE_ITEM_OVERLAY_ADD)
        if [[ "${profile_name}" == "${target_profile}" && -n "${profile_item}" ]]; then
          profile_items_overlay_add+=("${profile_item}")
        fi
        ;;
      PROFILE_ITEM_OVERLAY_REMOVE)
        if [[ "${profile_name}" == "${target_profile}" && -n "${profile_item}" ]]; then
          profile_items_overlay_remove+=("${profile_item}")
        fi
        ;;
    esac
  done < "${items_meta_file}"

  items=("${profile_items_base[@]}")
  for remove_item in "${profile_items_overlay_remove[@]}"; do
    next_items=()
    for keep_item in "${items[@]}"; do
      if [[ "${keep_item}" != "${remove_item}" ]]; then
        next_items+=("${keep_item}")
      fi
    done
    items=("${next_items[@]}")
  done

  for add_item in "${profile_items_overlay_add[@]}"; do
    exists=0
    for existing_item in "${items[@]}"; do
      if [[ "${existing_item}" == "${add_item}" ]]; then
        exists=1
        break
      fi
    done
    if [[ "${exists}" -eq 0 ]]; then
      items+=("${add_item}")
    fi
  done

  if [[ "${#items[@]}" -eq 0 ]]; then
    echo "Profile '${target_profile}' has no libs.mandatory list after applying delta from ${overlay_file}" >&2
    exit 1
  fi
fi

filtered=()
for item in "${items[@]}"; do
  if [[ "${variant}" == "server" && "${enable_ldap}" == "OFF" && "${item}" == "LDAP" ]]; then
    continue
  fi
  if [[ "${variant}" == "server" && "${enable_snmp}" == "OFF" && "${item}" == "NETSNMP" ]]; then
    continue
  fi
  if [[ "${family}" == "bsd" && "${item}" == "LDAP" ]]; then
    continue
  fi

  if [[ "${item}" == "BUILD_TOOLS" ]]; then
    case "${build_tool}" in
      make)
        item="BUILD_TOOLS_MAKE"
        ;;
      cmake)
        item="BUILD_TOOLS_CMAKE"
        ;;
      *)
        item="BUILD_TOOLS"
        ;;
    esac
  fi

  filtered+=("${item}")
done

resolved=()
if [[ -f "${dep_map_file}" && "${#filtered[@]}" -gt 0 ]]; then
  map_resolver="${script_dir}/lib/resolve-map.awk"
  if [[ ! -f "${map_resolver}" ]]; then
    echo "Map resolver missing: ${map_resolver}" >&2
    exit 1
  fi

  filtered_file="$(make_temp)"
  resolved_file="$(make_temp)"
  tmp_files+=("${filtered_file}" "${resolved_file}")

  printf '%s\n' "${filtered[@]}" > "${filtered_file}"
  if ! awk \
    -v MAP_FILE="${dep_map_file}" \
    -v FAMILY="${family}" \
    -v OS="${os_name}" \
    -v PKGMGR="${pkgmgr}" \
    -f "${map_resolver}" \
    "${filtered_file}" > "${resolved_file}"; then
    exit 1
  fi

  while IFS= read -r pkg; do
    [[ -n "${pkg}" ]] && resolved+=("${pkg}")
  done < "${resolved_file}"
else
  resolved=("${filtered[@]}")
fi

for pkg in "${resolved[@]}"; do
  printf '%s\n' "${pkg}"
done
