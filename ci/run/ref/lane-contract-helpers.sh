#!/usr/bin/env bash
# Shared helpers for reading the lane environment contract file.
# Requires: ${contract_file} to be set by the caller before sourcing.

read_contract_section() {
  local section="$1"
  awk -v section="${section}" '
    BEGIN { in_section = 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^\[[^]]+\][[:space:]]*$/ {
      name = $0
      sub(/^\[/, "", name)
      sub(/\][[:space:]]*$/, "", name)
      in_section = (name == section)
      next
    }
    in_section { print $0 }
  ' "${contract_file}"
}
