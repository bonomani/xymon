#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: packages-from-yaml.sh --variant server|client --family FAMILY --os OS --pkgmgr PKG [--enable-ldap ON|OFF] [--enable-snmp ON|OFF]
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
  val="${val^^}"
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
dep_map_file="${data_dir}/deps-map.yaml"

if [[ ! -f "${deps_file}" ]]; then
  echo "Dependency file missing: ${deps_file}" >&2
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

items_file="$(make_temp)"
tmp_files+=("${items_file}")

if ! awk -v FAMILY="${family}" -v OS="${os_name}" -v PKGMGR="${pkgmgr}" '
  BEGIN {
    found = 0
    list_context = ""
    list_indent = -1
  }
  function trim(val) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
  }
  function set_key(key, depth) {
    keys[depth] = key
    for (i = depth + 1; i < 64; ++i) delete keys[i]
  }
  function path_matches() {
    return keys[0] == "build" && keys[1] == FAMILY && keys[2] == OS && keys[3] == "packagers" && keys[4] == PKGMGR && keys[5] == "libs"
  }
  {
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
    indent = match($0, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)
    line = substr($0, indent + 1)
    if (line ~ /^-/) {
      if (list_context == "mandatory" && path_matches()) {
        item = trim(substr(line, 2))
        if (item != "") print item
      }
      next
    }
    if (list_context == "mandatory" && indent <= list_indent) {
      list_context = ""
    }
    sep_pos = index(line, ":")
    if (sep_pos > 0) {
      key = trim(substr(line, 1, sep_pos - 1))
      set_key(key, depth)
      if (key == "mandatory" && path_matches()) {
        found = 1
        list_context = "mandatory"
        list_indent = indent
      }
    }
  }
  END {
    if (found == 0) {
      print "Failed to locate package list for family=" FAMILY " os=" OS " pkgmgr=" PKGMGR > "/dev/stderr"
      exit 1
    }
  }
' "${deps_file}" > "${items_file}"; then
  exit 1
fi

mapfile -t items < "${items_file}"

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

declare -A map_entries
if [[ -f "${dep_map_file}" ]]; then
  map_file="$(make_temp)"
  tmp_files+=("${map_file}")
  if ! awk '
    BEGIN {
      in_map = 0
    }
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
      if (line ~ /^map:/) {
        in_map = 1
        next
      }
      if (line ~ /^aliases:/) {
        in_map = 0
        next
      }
      if (!in_map) next
      sep_pos = index(line, ":")
      if (sep_pos > 0) {
        key = trim(substr(line, 1, sep_pos - 1))
        value = trim(substr(line, sep_pos + 1))
        set_key(key, depth)
        if (value ~ /^\[/) {
          data = value
          sub(/^\[/, "", data)
          sub(/\][[:space:]]*$/, "", data)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", data)
          if (data == "") next
          map_key = keys[1]
          family_key = keys[2]
          os_key = keys[3]
          pkgmgr_key = key
          if (map_key == "" || family_key == "" || os_key == "" || pkgmgr_key == "") next
          n = split(data, items, /,[[:space:]]*/)
          pkgline = ""
          for (i = 1; i <= n; ++i) {
            item = trim(items[i])
            if (item == "") continue
            pkgline = pkgline (pkgline == "" ? "" : " ") item
          }
          if (pkgline != "") print map_key "|" family_key "|" os_key "|" pkgmgr_key "|" pkgline
        }
      }
    }
  ' "${dep_map_file}" > "${map_file}"; then
    exit 1
  fi

  while IFS='|' read -r map_key map_family map_os map_pkgmgr pkg_list; do
    [[ -n "${pkg_list}" ]] || continue
    map_entries["${map_key}|${map_family}|${map_os}|${map_pkgmgr}"]="${pkg_list}"
  done < "${map_file}"
fi

resolved=()
for item in "${filtered[@]}"; do
  key="${item}|${family}|${os_name}|${pkgmgr}"
  mapped_pkg_line="${map_entries["${key}"]:-}"
  if [[ -n "${mapped_pkg_line}" ]]; then
    read -ra replacements <<< "${mapped_pkg_line}"
    for rep in "${replacements[@]}"; do
      resolved+=("${rep}")
    done
  else
    resolved+=("${item}")
  fi
done

for pkg in "${resolved[@]}"; do
  printf '%s\n' "${pkg}"
done
