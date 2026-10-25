#!/usr/bin/env bash
# Install what a Xymon build and its test suite need on Solaris 11.4, as the
# probe on vmactions/solaris-vm established:
#   - Oracle's packages (IPS) for PCRE2, c-ares, OpenLDAP, fping and GNU make;
#     gcc is already in the "-gcc" image.
#   - RRDtool from OpenCSW: Oracle made image/rrdtool obsolete in 11.4.30.
#   - OpenCSW's 64-bit library directory on the runtime linker's path:
#     build/Makefile.SunOS deliberately sets no RPATH, and without this
#     xymond_rrd cannot load librrd.so.4.
set -euo pipefail

log() { printf '=== install-solaris: %s ===\n' "$*"; }

IPS_PACKAGES=(
  library/pcre2
  library/libcares
  system/network/ldap/openldap
  diagnostic/fping
  developer/build/gnu-make
)

log "pkg install ${IPS_PACKAGES[*]}"
rc=0
pkg install --accept "${IPS_PACKAGES[@]}" || rc=$?
# pkg exits 4 when there is nothing to do.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; then
  echo "pkg install failed (rc=$rc)" >&2
  exit "$rc"
fi

PKGUTIL=$(command -v pkgutil || true)
[ -n "$PKGUTIL" ] || [ ! -x /opt/csw/bin/pkgutil ] || PKGUTIL=/opt/csw/bin/pkgutil
if [ -z "$PKGUTIL" ]; then
  echo "OpenCSW's pkgutil is needed for RRDtool and was not found" >&2
  exit 1
fi
log "pkgutil -y -i rrdtool_dev"
"$PKGUTIL" -U
"$PKGUTIL" -y -i rrdtool_dev

if ! crle -64 | grep -q '/opt/csw/lib/amd64'; then
  log "crle -64 -u -l /opt/csw/lib/amd64"
  crle -64 -u -l /opt/csw/lib/amd64
fi
crle -64 | grep 'Default Library Path'
