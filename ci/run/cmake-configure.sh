#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

sanitize() {
  printf '%s' "$1"
}

PRESET="$(sanitize "${PRESET:-packaging}")"
ENABLE_SSL="$(sanitize "${ENABLE_SSL:-}")"
ENABLE_LDAP="$(sanitize "${ENABLE_LDAP:-}")"
VARIANT="$(sanitize "${VARIANT:-}")"
LOCALCLIENT="$(sanitize "${LOCALCLIENT:-}")"

if [[ -z "$PRESET" || -z "$ENABLE_SSL" || -z "$ENABLE_LDAP" || -z "$VARIANT" ]]; then
  echo "PRESET, ENABLE_SSL, ENABLE_LDAP, and VARIANT must be set"
  exit 1
fi

if [[ -z "$LOCALCLIENT" ]]; then
  if [[ "$VARIANT" == "server" ]]; then
    LOCALCLIENT=OFF
  else
    echo "LOCALCLIENT must be set for variant $VARIANT"
    exit 1
  fi
fi

cmake -S . --preset "$PRESET" \
  -DENABLE_SSL="$ENABLE_SSL" \
  -DENABLE_LDAP="$ENABLE_LDAP" \
  -DXYMON_VARIANT="$VARIANT" \
  -DLOCALCLIENT="$LOCALCLIENT"

