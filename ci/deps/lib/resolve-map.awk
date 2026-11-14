# Resolve logical dependency IDs to concrete packages for a given
# family/os/pkgmgr triple using ci/deps/data/deps-map.yaml.
#
# Input: dep IDs on stdin, one per line.
# Required vars:
#   MAP_FILE=<path to deps-map.yaml>
#   FAMILY=<deps family key>
#   OS=<deps os key>
#   PKGMGR=<package manager key>

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

function set_key(key, depth,   i) {
  keys[depth] = key
  for (i = depth + 1; i < 64; ++i) delete keys[i]
}

function normalize_inline_list(value,    data, n, i, item, out, arr) {
  data = trim(value)
  sub(/^\[/, "", data)
  sub(/\][[:space:]]*$/, "", data)
  data = trim(data)
  if (data == "") return ""

  n = split(data, arr, /,[[:space:]]*/)
  out = ""
  for (i = 1; i <= n; ++i) {
    item = trim(arr[i])
    if (item == "") continue
    out = out (out == "" ? "" : " ") item
  }
  return out
}

function parse_map_file(    line, raw, trimmed, indent, depth, sep_pos, key, value, pkgline, dep, family, os_name, pkgmgr, template, alias_key) {
  while ((getline raw < MAP_FILE) > 0) {
    line = raw
    sub(/\r$/, "", line)
    trimmed = trim(line)
    if (trimmed == "" || substr(trimmed, 1, 1) == "#") continue

    indent = match(line, /[^ ]/) - 1
    if (indent < 0) indent = 0
    depth = int(indent / 2)

    line = substr(line, indent + 1)
    sep_pos = index(line, ":")
    if (sep_pos <= 0) continue

    key = trim(substr(line, 1, sep_pos - 1))
    value = trim(substr(line, sep_pos + 1))
    value = dequote(value)
    set_key(key, depth)

    if (keys[0] == "aliases" && depth == 1 && value != "" && value !~ /^\[/) {
      alias_key = key
      if (alias_key != "") aliases[alias_key] = value
      continue
    }

    if (value ~ /^\[/) {
      pkgline = normalize_inline_list(value)
      if (pkgline == "") continue

      if (keys[0] == "package_templates") {
        template = keys[1]
        pkgmgr = key
        if (template != "" && pkgmgr != "") {
          map_templates[template SUBSEP pkgmgr] = pkgline
        }
        continue
      }

      if (keys[0] != "map") continue
      dep = keys[1]
      if (dep == "") continue

      if (keys[2] == "defaults") {
        pkgmgr = key
        if (pkgmgr != "") map_defaults[dep SUBSEP pkgmgr] = pkgline
        continue
      }

      if (keys[2] == "overrides" && keys[3] == "by_os") {
        os_name = keys[4]
        pkgmgr = key
        if (os_name != "" && pkgmgr != "") {
          map_overrides_os[dep SUBSEP os_name SUBSEP pkgmgr] = pkgline
        }
        continue
      }

      if (keys[2] == "overrides" && keys[3] == "by_family") {
        family = keys[4]
        os_name = keys[5]
        pkgmgr = key
        if (family != "" && os_name != "" && pkgmgr != "") {
          map_overrides_family_os[dep SUBSEP family SUBSEP os_name SUBSEP pkgmgr] = pkgline
        }
        continue
      }

      # Legacy map.<dep>.<family>.<os>.<pkgmgr>: [..]
      family = keys[2]
      os_name = keys[3]
      pkgmgr = key
      if (family != "" && os_name != "" && pkgmgr != "") {
        map_legacy[dep SUBSEP family SUBSEP os_name SUBSEP pkgmgr] = pkgline
      }
      continue
    }

    if (keys[0] == "map" && keys[2] == "defaults" && key == "template") {
      dep = keys[1]
      if (dep != "" && value != "") dep_template[dep] = value
    }
  }
  close(MAP_FILE)
}

function emit_pkgline(pkgline,   i, n, arr, pkg) {
  if (pkgline == "") return
  n = split(pkgline, arr, /[[:space:]]+/)
  for (i = 1; i <= n; ++i) {
    pkg = trim(arr[i])
    if (pkg != "") print pkg
  }
}

BEGIN {
  if (MAP_FILE == "" || FAMILY == "" || OS == "" || PKGMGR == "") {
    print "resolve-map.awk requires MAP_FILE/FAMILY/OS/PKGMGR variables" > "/dev/stderr"
    exit 2
  }
  parse_map_file()
}

{
  dep = trim($0)
  if (dep == "") next

  dep_key = dep
  if ((dep_key) in aliases) dep_key = aliases[dep_key]

  pkgline = ""
  if ((dep_key SUBSEP FAMILY SUBSEP OS SUBSEP PKGMGR) in map_legacy) {
    pkgline = map_legacy[dep_key SUBSEP FAMILY SUBSEP OS SUBSEP PKGMGR]
  } else if ((dep_key SUBSEP FAMILY SUBSEP OS SUBSEP PKGMGR) in map_overrides_family_os) {
    pkgline = map_overrides_family_os[dep_key SUBSEP FAMILY SUBSEP OS SUBSEP PKGMGR]
  } else if ((dep_key SUBSEP OS SUBSEP PKGMGR) in map_overrides_os) {
    pkgline = map_overrides_os[dep_key SUBSEP OS SUBSEP PKGMGR]
  } else if ((dep_key SUBSEP PKGMGR) in map_defaults) {
    pkgline = map_defaults[dep_key SUBSEP PKGMGR]
  } else if ((dep_key) in dep_template) {
    template = dep_template[dep_key]
    if ((template SUBSEP PKGMGR) in map_templates) {
      pkgline = map_templates[template SUBSEP PKGMGR]
    }
  }

  if (pkgline != "") {
    emit_pkgline(pkgline)
  } else {
    print dep_key
  }
}
