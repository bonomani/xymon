#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

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

if [[ "${PROFILE}" == "debian" ]]; then
  USEXYMONPING=y \
  ENABLESSL="${ENABLESSL_VALUE}" \
  ENABLELDAP="${ENABLELDAP}" \
  ENABLELDAPSSL="${ENABLELDAPSSL}" \
  XYMONUSER=xymon \
  XYMONTOPDIR=/usr/lib/xymon \
  XYMONVAR=/var/lib/xymon \
  XYMONHOSTURL=/xymon \
  CGIDIR=/usr/lib/xymon/cgi-bin \
  XYMONCGIURL=/xymon-cgi \
  SECURECGIDIR=/usr/lib/xymon/cgi-secure \
  SECUREXYMONCGIURL=/xymon-seccgi \
  HTTPDGID=www-data \
  XYMONLOGDIR=/var/log/xymon \
  XYMONHOSTNAME=localhost \
  XYMONHOSTIP=127.0.0.1 \
  MANROOT=/usr/share/man \
  INSTALLBINDIR=/usr/lib/xymon/server/bin \
  INSTALLETCDIR=/etc/xymon \
  INSTALLWEBDIR=/etc/xymon/web \
  INSTALLEXTDIR=/usr/lib/xymon/server/ext \
  INSTALLTMPDIR=/var/lib/xymon/tmp \
  INSTALLWWWDIR=/usr/lib/xymon/www \
  ./configure --${VARIANT}
else
  printf '\n%.0s' {1..50} | ./configure --${VARIANT}
fi
