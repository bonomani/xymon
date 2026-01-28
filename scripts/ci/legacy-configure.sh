#!/usr/bin/env bash
set -euo pipefail
IFS=$' \t\n'

VARIANT="${1:-}"
PROFILE="${2:-default}"

if [[ -z "${VARIANT}" ]]; then
  echo "variant must be set"
  exit 1
fi

if [[ "${PROFILE}" == "debian" ]]; then
  USEXYMONPING=y \
  ENABLESSL=y \
  ENABLELDAP=y \
  ENABLELDAPSSL=y \
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
