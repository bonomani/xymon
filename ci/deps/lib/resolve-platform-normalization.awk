# Resolve OS ID + raw version to deps family/os/pkgmgr/version using
# ci/deps/platform-normalization.yaml.
#
# Required vars:
#   RULES_FILE=<path to platform-normalization.yaml>
#   OS_ID=<detected os-release ID>
#   VERSION=<raw VERSION_ID value>
#
# Output:
#   family|os|pkgmgr|version

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

function load_rules(    raw, line, trimmed, indent, depth, sep_pos, key, value, os_id, map_key) {
  while ((getline raw < RULES_FILE) > 0) {
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
    key = dequote(key)
    value = trim(substr(line, sep_pos + 1))
    value = dequote(value)
    set_key(key, depth)

    if (keys[0] != "normalization" || keys[1] != "os_ids") continue

    os_id = keys[2]
    if (os_id == "") continue

    if (keys[3] == "versions") {
      map_key = key
      if (map_key != "" && value != "") {
        version_map[os_id SUBSEP map_key] = value
        version_map_keys[os_id] = version_map_keys[os_id] "\n" map_key
      }
      continue
    }

    if (depth == 3 && value != "") {
      rules[os_id SUBSEP key] = value
    }
  }
  close(RULES_FILE)
}

function choose_prefix_version(os_id, version_raw,    keys_blob, n, i, candidate, best_key, best_val, arr) {
  keys_blob = version_map_keys[os_id]
  n = split(keys_blob, arr, /\n/)
  best_key = ""
  best_val = ""
  for (i = 1; i <= n; ++i) {
    candidate = trim(arr[i])
    if (candidate == "") continue
    if (index(version_raw, candidate) == 1) {
      if (length(candidate) > length(best_key)) {
        best_key = candidate
        best_val = version_map[os_id SUBSEP candidate]
      }
    }
  }
  return best_val
}

BEGIN {
  if (RULES_FILE == "" || OS_ID == "") {
    print "resolve-platform-normalization.awk requires RULES_FILE and OS_ID" > "/dev/stderr"
    exit 2
  }

  load_rules()

  family = rules[OS_ID SUBSEP "family"]
  os_name = rules[OS_ID SUBSEP "os"]
  pkgmgr = rules[OS_ID SUBSEP "pkgmgr"]
  mode = rules[OS_ID SUBSEP "version_mode"]
  version_default = rules[OS_ID SUBSEP "version_default"]
  version_fixed = rules[OS_ID SUBSEP "version_fixed"]
  version_fallback = rules[OS_ID SUBSEP "version_fallback"]

  if (family == "" || os_name == "" || pkgmgr == "") {
    print "No normalization rule for OS_ID='" OS_ID "' in " RULES_FILE > "/dev/stderr"
    exit 1
  }

  version_out = VERSION

  if (mode == "fixed") {
    if (version_fixed != "") version_out = version_fixed
    else if (version_default != "") version_out = version_default
  } else if (mode == "major") {
    if (version_out ~ /^[0-9]+([.].*)?$/) {
      sub(/[.].*$/, "", version_out)
    }
  } else if (mode == "dot_to_underscore") {
    if (version_out == "" && version_default != "") version_out = version_default
    gsub(/[.]/, "_", version_out)
  } else if (mode == "exact_map") {
    mapped = version_map[OS_ID SUBSEP version_out]
    if (mapped == "" && version_out ~ /[.]/) {
      major = version_out
      sub(/[.].*$/, "", major)
      mapped = version_map[OS_ID SUBSEP major]
    }
    if (mapped != "") {
      version_out = mapped
    } else if (version_fallback == "default" && version_default != "") {
      version_out = version_default
    } else if (version_fallback != "passthrough" && version_default != "") {
      version_out = version_default
    }
  } else if (mode == "prefix_map") {
    mapped = choose_prefix_version(OS_ID, version_out)
    if (mapped != "") version_out = mapped
    else if (version_default != "") version_out = version_default
  }

  if (version_out == "" && version_default != "") {
    version_out = version_default
  }

  print family "|" os_name "|" pkgmgr "|" version_out
}
