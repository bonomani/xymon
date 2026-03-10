#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKE_PROFILE_EXPORTER="${SCRIPT_DIR}/export-make-profile-env.sh"

VARIANT="${1:-}"
PROFILE="${2:-default}"

if [[ -z "${VARIANT}" ]]; then
  echo "variant must be set"
  exit 1
fi

CONFTYPE_VALUE="${CONFTYPE:-}"
if [[ -z "${CONFTYPE_VALUE}" && -n "${LOCALCLIENT:-}" ]]; then
  case "${LOCALCLIENT}" in
    ON|on|On|1|true|TRUE|True) CONFTYPE_VALUE=client ;;
    OFF|off|Off|0|false|FALSE|False) CONFTYPE_VALUE=server ;;
    *)
      echo "LOCALCLIENT must be ON or OFF (got: ${LOCALCLIENT})"
      exit 1
      ;;
  esac
fi

if [[ -z "${CONFTYPE_VALUE}" ]]; then
  CONFTYPE_VALUE="server"
fi

export CONFTYPE="${CONFTYPE_VALUE}"

ENABLESSL_VALUE="${ENABLESSL:-${ENABLE_SSL:-}}"
if [[ -z "${ENABLESSL_VALUE}" ]]; then
  if [[ "${VARIANT}" == "client" ]]; then
    ENABLESSL_VALUE=n
  else
    ENABLESSL_VALUE=y
  fi
fi

export ENABLESSL="${ENABLESSL_VALUE}"
export ENABLELDAPSSL="${ENABLESSL_VALUE}"
export ENABLELDAP="${ENABLELDAP:-y}"
export USEXYMONPING="${USEXYMONPING:-y}"

if [[ "${PROFILE}" == "debian" || "${PROFILE}" == "packaging" ]]; then
  httpdgid_value="${HTTPDGID:-nobody}"
  if [[ "${PROFILE}" == "debian" && -z "${HTTPDGID:-}" ]]; then
    httpdgid_value="www-data"
  fi
  if [[ ! -f "${MAKE_PROFILE_EXPORTER}" ]]; then
    echo "Missing make profile exporter: ${MAKE_PROFILE_EXPORTER}"
    exit 1
  fi
  legacy_layout_profile="${PROFILE}"
  if [[ "${legacy_layout_profile}" == "packaging" ]]; then
    legacy_layout_profile="debian"
  fi
  eval "$(bash "${MAKE_PROFILE_EXPORTER}" --profile "${legacy_layout_profile}")"
  echo "Make profile '${PROFILE}' environment before configure:"
  for var in XYMONTOPDIR XYMONVAR XYMONHOSTURL CGIDIR XYMONCGIURL SECURECGIDIR SECUREXYMONCGIURL XYMONLOGDIR XYMONHOSTNAME XYMONHOSTIP MANROOT INSTALLBINDIR INSTALLETCDIR INSTALLWEBDIR INSTALLEXTDIR INSTALLTMPDIR INSTALLWWWDIR XYMONUSER HTTPDGID USEXYMONPING ENABLESSL ENABLELDAP ENABLELDAPSSL; do
    printf '  %s=%s\n' "$var" "${!var:-<unset>}"
  done
  USEXYMONPING=y \
  ENABLESSL="${ENABLESSL_VALUE}" \
  ENABLELDAP="${ENABLELDAP}" \
  ENABLELDAPSSL="${ENABLELDAPSSL}" \
  XYMONUSER=xymon \
  HTTPDGID="${httpdgid_value}" \
  XYMONHOSTNAME=localhost \
  XYMONHOSTIP=127.0.0.1 \
  ./configure --${VARIANT}
else
  printf '\n%.0s' {1..50} | ./configure --${VARIANT}
fi
