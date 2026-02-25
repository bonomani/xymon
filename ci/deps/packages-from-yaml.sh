#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: packages-from-yaml.sh --variant server|client|localclient --family FAMILY --os OS --pkgmgr PKG [--enable-ldap ON|OFF] [--enable-snmp ON|OFF]
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

enable_ldap="$(normalize_onoff "${enable_ldap}" "OFF")"
enable_snmp="$(normalize_onoff "${enable_snmp}" "OFF")"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_dir="${script_dir}/data"
deps_file="${data_dir}/deps-${variant}.yaml"
topology_file="${data_dir}/deps-topology.yaml"
bindings_file="${deps_file}"
dep_map_file="${data_dir}/deps-map.yaml"

if [[ ! -f "${deps_file}" ]]; then
  echo "Dependency file missing: ${deps_file}" >&2
  exit 1
fi

topology_ref="$(
  awk '
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
      if (key == "topology" && value != "") {
        print value
        exit
      }
    }
  ' "${deps_file}"
)"
if [[ -n "${topology_ref}" ]]; then
  topology_file="${data_dir}/${topology_ref}"
fi

bindings_ref="$(
  awk '
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
      if (key == "bindings_file" && value != "") {
        print value
        exit
      }
    }
  ' "${deps_file}"
)"
if [[ -n "${bindings_ref}" ]]; then
  bindings_file="${data_dir}/${bindings_ref}"
fi

if [[ ! -f "${topology_file}" ]]; then
  echo "Dependency topology missing: ${topology_file}" >&2
  exit 1
fi
if [[ ! -f "${bindings_file}" ]]; then
  echo "Dependency bindings missing: ${bindings_file}" >&2
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

    if (keys[0] == "bindings" && keys[1] == FAMILY && keys[2] == OS && key == "profile") {
      if (value != "") print "TARGET_PROFILE\t" value
    }

    if (keys[0] == "bindings" && keys[1] == FAMILY && keys[2] == OS && keys[3] == "packagers" && keys[4] == PKGMGR && keys[5] == "libs" && key == "mandatory") {
      list_context = "target"
      list_indent = indent
      next
    }
  }
' "${bindings_file}" > "${items_meta_file}"; then
  exit 1
fi

if ! awk '
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
        print "PROFILE_ITEM\t" profile_name "\t" item
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
' "${deps_file}" >> "${items_meta_file}"; then
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
    if (keys[0] == "build" && keys[1] == FAMILY && keys[2] == OS && keys[3] == "packagers" && key == PKGMGR) {
      found = 1
    }
  }
  END {
    if (found != 1) {
      print "Failed to locate topology for family=" FAMILY " os=" OS " pkgmgr=" PKGMGR > "/dev/stderr"
      exit 1
    }
  }
' "${topology_file}"; then
  exit 1
fi

declare -A profile_items
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
    PROFILE_ITEM)
      if [[ -n "${a}" && -n "${b}" ]]; then
        if [[ -z "${profile_items[${a}]:-}" ]]; then
          profile_items["${a}"]="${b}"
        else
          profile_items["${a}"]+=$'\n'"${b}"
        fi
      fi
      ;;
  esac
done < "${items_meta_file}"

if [[ "${#items[@]}" -eq 0 ]]; then
  if [[ -z "${target_profile}" ]]; then
    echo "Failed to locate package list for family=${family} os=${os_name} pkgmgr=${pkgmgr}" >&2
    exit 1
  fi

  profile_payload="${profile_items[${target_profile}]:-}"
  if [[ -z "${profile_payload}" ]]; then
    echo "Profile '${target_profile}' has no libs.mandatory list in ${deps_file}" >&2
    exit 1
  fi

  while IFS= read -r item; do
    [[ -n "${item}" ]] && items+=("${item}")
  done <<< "${profile_payload}"
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
