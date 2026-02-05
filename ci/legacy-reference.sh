#!/usr/bin/env bash
set -euo pipefail

OS_NAME=""
OS_VERSION=""
REF_NAME=""
KEYFILES_NAME=""
VARIANT=""
CONFTYPE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --os)
      OS_NAME="${2:-}"
      shift 2
      ;;
    --version)
      OS_VERSION="${2:-}"
      shift 2
      ;;
    --ref-name)
      REF_NAME="${2:-}"
      shift 2
      ;;
    --keyfiles-name)
      KEYFILES_NAME="${2:-}"
      shift 2
      ;;
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --conftype)
      CONFTYPE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$OS_NAME" ]; then
  echo "Missing --os" >&2
  exit 1
fi

LEGACY_STAGING="/tmp/legacy-ref"
DEFAULT_TOP="/var/lib/xymon"
MAKE_BIN="make"
CARES_PREFIX=""

as_root() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}

setup_os() {
  case "$OS_NAME" in
    linux)
      CARES_PREFIX="/usr"
      HTTPDGID="www-data"
      as_root apt-get update
      DEBIAN_FRONTEND=noninteractive as_root apt-get install -y \
        build-essential \
        make \
        gcc \
        git \
        findutils \
        libc-ares-dev \
        libpcre3-dev \
        libldap2-dev \
        librrd-dev \
        libssl-dev \
        libtirpc-dev \
        zlib1g-dev
      as_root groupadd -f www-data 2>/dev/null || true
      as_root useradd -m -s /bin/sh xymon 2>/dev/null || true
      ;;
    freebsd)
      CARES_PREFIX="/usr/local"
      MAKE_BIN="gmake"
      HTTPDGID="www"
      export VARIANT="${VARIANT:-server}"
      if [ "${VARIANT}" = "server" ]; then
        export ENABLE_LDAP=ON
        export ENABLE_SNMP=ON
      else
        export ENABLE_LDAP=OFF
        export ENABLE_SNMP=OFF
      fi
      bash ci/deps/install-bsd-packages.sh --os "${OS_NAME}" --version "${OS_VERSION}"
      as_root pw groupadd www 2>/dev/null || true
      as_root pw useradd -n xymon -m -s /bin/sh 2>/dev/null || true
      ;;
    openbsd)
      CARES_PREFIX="/usr/local"
      MAKE_BIN="gmake"
      HTTPDGID="www"
      export VARIANT="${VARIANT:-server}"
      if [ "${VARIANT}" = "server" ]; then
        export ENABLE_LDAP=ON
        export ENABLE_SNMP=ON
      else
        export ENABLE_LDAP=OFF
        export ENABLE_SNMP=OFF
      fi
      bash ci/deps/install-bsd-packages.sh --os "${OS_NAME}" --version "${OS_VERSION}"
      as_root groupadd www 2>/dev/null || true
      as_root useradd -m -s /bin/sh xymon 2>/dev/null || true
      ;;
    netbsd)
      CARES_PREFIX="/usr/pkg"
      MAKE_BIN="gmake"
      HTTPDGID="www"
      export VARIANT="${VARIANT:-server}"
      if [ "${VARIANT}" = "server" ]; then
        export ENABLE_LDAP=ON
        export ENABLE_SNMP=ON
      else
        export ENABLE_LDAP=OFF
        export ENABLE_SNMP=OFF
      fi
      bash ci/deps/install-bsd-packages.sh --os "${OS_NAME}" --version "${OS_VERSION}"
      as_root groupadd www 2>/dev/null || true
      as_root useradd -m -s /bin/sh xymon 2>/dev/null || true
      if [ -x /usr/pkg/bin/gmake ]; then
        export PATH="/usr/pkg/bin:${PATH}"
      fi
      ;;
    *)
      echo "Unsupported OS: $OS_NAME" >&2
      exit 1
      ;;
  esac
}

configure_legacy() {
  export ENABLESSL=y
  export ENABLELDAP=y
  export XYMONUSER=xymon
  export HTTPDGID="${HTTPDGID:-www}"
  export XYMONTOPDIR="${DEFAULT_TOP}"
  export CC=cc
  if [ -n "${CONFTYPE}" ]; then
    export CONFTYPE="${CONFTYPE}"
  fi

  if [ "$OS_NAME" = "linux" ]; then
    local linux_variant="${VARIANT:-server}"
    echo "configure: ./configure --${linux_variant} (CONFTYPE=${CONFTYPE:-unset})"
    printf '\n%.0s' {1..40} | ./configure --"${linux_variant}"
  else
    local bsd_variant="${VARIANT:-server}"
    if [ "$bsd_variant" = "client" ]; then
      echo "configure: MAKE=${MAKE_BIN} ./configure.client"
      printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.client
    else
      echo "configure: MAKE=${MAKE_BIN} ./configure.server"
      printf '\n%.0s' {1..40} | MAKE="${MAKE_BIN}" ./configure.server
    fi
  fi
}

build_legacy() {
  local caresinc=""
  local careslib=""
  if [ -n "$CARES_PREFIX" ]; then
    caresinc="-I${CARES_PREFIX}/include"
    careslib="-L${CARES_PREFIX}/lib -lcares"
  fi
  if [ "${VARIANT:-server}" = "client" ]; then
    if [ "${CONFTYPE:-}" = "server" ]; then
      local base_cflags=""
      base_cflags="$(make -s -p -n 2>/dev/null | awk -F ' = ' '/^CFLAGS = /{print $2; exit}')"
      if [ -z "${base_cflags}" ]; then
        base_cflags="$(awk -F '=' '/^CFLAGS[[:space:]]*=/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}' Makefile 2>/dev/null || true)"
      fi
      "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" \
        CFLAGS="${base_cflags} -DLOCALCLIENT=0" \
        PCRELIBS="-lpcre" \
        client
    else
      "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}" client
    fi
  else
    "${MAKE_BIN}" -j2 CARESINCDIR="${caresinc}" CARESLIBS="${careslib}"
  fi
}

install_staged() {
  if [ "${VARIANT:-server}" = "client" ]; then
    as_root "${MAKE_BIN}" install-client install-clientmsg \
      CLIENTTARGETS="lib-client common-client" \
      XYMONTOPDIR="${LEGACY_STAGING}${DEFAULT_TOP}" \
      XYMONHOME="${LEGACY_STAGING}${DEFAULT_TOP}" \
      XYMONCLIENTHOME="${LEGACY_STAGING}${DEFAULT_TOP}" \
      XYMONVAR="${LEGACY_STAGING}${DEFAULT_TOP}/data" \
      XYMONLOGDIR="${LEGACY_STAGING}/var/log/xymon" \
      CGIDIR="${LEGACY_STAGING}${DEFAULT_TOP}/cgi-bin" \
      SECURECGIDIR="${LEGACY_STAGING}${DEFAULT_TOP}/cgi-secure" \
      INSTALLWWWDIR="${LEGACY_STAGING}${DEFAULT_TOP}/www" \
      INSTALLETCDIR="${LEGACY_STAGING}${DEFAULT_TOP}/etc"
  else
    as_root "${MAKE_BIN}" install \
      XYMONTOPDIR="${LEGACY_STAGING}${DEFAULT_TOP}" \
      XYMONHOME="${LEGACY_STAGING}${DEFAULT_TOP}/server" \
      XYMONVAR="${LEGACY_STAGING}${DEFAULT_TOP}/data" \
      XYMONLOGDIR="${LEGACY_STAGING}/var/log/xymon" \
      CGIDIR="${LEGACY_STAGING}${DEFAULT_TOP}/cgi-bin" \
      SECURECGIDIR="${LEGACY_STAGING}${DEFAULT_TOP}/cgi-secure" \
      INSTALLWWWDIR="${LEGACY_STAGING}${DEFAULT_TOP}/server/www" \
      INSTALLETCDIR="${LEGACY_STAGING}${DEFAULT_TOP}/server/etc"
  fi
}

detect_topdir() {
  local topdir
  topdir=$(awk -F ' = ' '/^XYMONTOPDIR =/ {print $2; exit}' Makefile 2>/dev/null || true)
  if [ -z "$topdir" ]; then
    topdir="${DEFAULT_TOP}"
  fi

  local root="${LEGACY_STAGING}${topdir}"
  if [ ! -d "$root" ]; then
    local cand
    cand=$(find "${LEGACY_STAGING}" -path "*/server/etc/xymonserver.cfg" -print -quit)
    if [ -n "$cand" ]; then
      local guessed
      guessed=$(dirname "$(dirname "$(dirname "$cand")")")
      topdir="${guessed#${LEGACY_STAGING}}"
      root="${guessed}"
    fi
  fi

  if [ ! -d "$root" ]; then
    echo "Missing ${root}" >&2
    exit 1
  fi

  echo "${topdir}"
}

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$file"
  elif command -v digest >/dev/null 2>&1; then
    digest -a sha256 "$file"
  else
    echo "No sha256 tool found" >&2
    exit 1
  fi
}

write_refs() {
  local topdir
  topdir="$(detect_topdir)"
  local root="${LEGACY_STAGING}${topdir}"

  if [ -z "$REF_NAME" ]; then
    if [ "$OS_NAME" = "linux" ]; then
      if [ "${VARIANT:-server}" = "server" ]; then
        REF_NAME="legacy.linux.server.ref"
      else
        REF_NAME="legacy.linux.${VARIANT}.ref"
      fi
    else
      REF_NAME="legacy.${OS_NAME}.ref"
    fi
  fi

  if [ -z "$KEYFILES_NAME" ]; then
    if [ "$OS_NAME" = "linux" ]; then
      if [ "${VARIANT:-server}" = "server" ]; then
        KEYFILES_NAME="legacy.linux.server.keyfiles.sha256"
      else
        KEYFILES_NAME="legacy.linux.${VARIANT}.keyfiles.sha256"
      fi
    else
      KEYFILES_NAME="legacy.${OS_NAME}.keyfiles.sha256"
    fi
  fi

  find "$root" -print \
    | sed "s|^${LEGACY_STAGING}||" \
    | sed "s|${topdir}/$|${topdir}|" \
    | sort > "/tmp/${REF_NAME}"

  if [ "${VARIANT:-server}" = "client" ]; then
    : > "/tmp/${KEYFILES_NAME}"
    echo "# Client variant: server keyfiles are not generated." >> "/tmp/${KEYFILES_NAME}"
  else
  local key_files=(
    "${topdir}/server/etc/xymonserver.cfg"
    "${topdir}/server/etc/tasks.cfg"
    "${topdir}/server/etc/cgioptions.cfg"
    "${topdir}/server/etc/graphs.cfg"
    "${topdir}/server/etc/client-local.cfg"
    "${topdir}/server/etc/columndoc.csv"
    "${topdir}/server/etc/protocols.cfg"
  )

  : > "/tmp/${KEYFILES_NAME}"
  for f in "${key_files[@]}"; do
    local p="${LEGACY_STAGING}${f}"
    if [ ! -f "$p" ]; then
      echo "MISSING $f" >> "/tmp/${KEYFILES_NAME}"
      continue
    fi
    printf '%s  %s\n' "$(sha256_of "$p")" "$f" >> "/tmp/${KEYFILES_NAME}"
  done
  fi

  if [ -d docs/cmake-legacy-migration ]; then
    cp "/tmp/${REF_NAME}" "docs/cmake-legacy-migration/${REF_NAME}" || true
    cp "/tmp/${KEYFILES_NAME}" "docs/cmake-legacy-migration/${KEYFILES_NAME}" || true
  fi
}

echo "=== Setup ($OS_NAME) ==="
setup_os
echo "=== Configure (legacy) ==="
configure_legacy
echo "=== Build (legacy) ==="
build_legacy
echo "=== Install (legacy staged) ==="
install_staged
echo "=== Generate legacy refs ==="
write_refs
