#!/usr/bin/env bash
set -euo pipefail

root_dir="${ROOT_DIR:?ROOT_DIR is required}"
build_dir="${BUILD_DIR:?BUILD_DIR is required}"
use_gnuinstall="${USE_GNUINSTALL:?USE_GNUINSTALL is required}"
cmake_prefix="${CMAKE_PREFIX:?CMAKE_PREFIX is required}"
xymontopdir="${XYMONTOPDIR:?XYMONTOPDIR is required}"
xymonhome="${XYMONHOME:?XYMONHOME is required}"
xymonclienthome="${XYMONCLIENTHOME:?XYMONCLIENTHOME is required}"
xymonvar="${XYMONVAR:?XYMONVAR is required}"
xymonlogdir="${XYMONLOGDIR:?XYMONLOGDIR is required}"
cgidir="${CGIDIR:?CGIDIR is required}"
securecgidir="${SECURECGIDIR:?SECURECGIDIR is required}"
xymonuser="${XYMONUSER:?XYMONUSER is required}"
xymonhostname="${XYMONHOSTNAME:?XYMONHOSTNAME is required}"
xymonhostip="${XYMONHOSTIP:?XYMONHOSTIP is required}"
xymonhostos="${XYMONHOSTOS:?XYMONHOSTOS is required}"
xymonhosturl="${XYMONHOSTURL:?XYMONHOSTURL is required}"
xymoncgiurl="${XYMONCGIURL:?XYMONCGIURL is required}"
securexymoncgiurl="${SECUREXYMONCGIURL:?SECUREXYMONCGIURL is required}"
manroot="${MANROOT:?MANROOT is required}"
httpdgid="${HTTPDGID:?HTTPDGID is required}"
httpdgid_chgrp="${HTTPDGID_CHGRP:?HTTPDGID_CHGRP is required}"
fping_path="${FPING_PATH:?FPING_PATH is required}"
mail_program="${MAILPROGRAM:?MAILPROGRAM is required}"
rrdinclude="${RRD_INCLUDE_DIR:-}"
rrdlib="${RRD_LIBRARY_DIR:-}"
pcreinclude="${PCRE_INCLUDE_DIR:-}"
pcrelib="${PCRE_LIBRARY_DIR:-}"
sslinclude="${SSL_INCLUDE_DIR:-}"
ssllib="${SSL_LIBRARY_DIR:-}"
ldapinclude="${LDAP_INCLUDE_DIR:-}"
ldaplib="${LDAP_LIBRARY_DIR:-}"
caresinclude="${CARES_INCLUDE_DIR:-}"
careslib="${CARES_LIBRARY_DIR:-}"
enable_rrd="${ENABLE_RRD:-}"
enable_snmp="${ENABLE_SNMP:-}"
enable_ssl="${ENABLE_SSL:-}"
enable_ldap="${ENABLE_LDAP:-}"
non_interactive="${NON_INTERACTIVE:-0}"
build_install="${BUILD_INSTALL:-1}"
use_ci_configure="${USE_CI_CONFIGURE:-0}"
preset_override="${PRESET_OVERRIDE:-}"
variant_override="${VARIANT_OVERRIDE:-}"
localclient_override="${LOCALCLIENT_OVERRIDE:-}"
parallel_override="${PARALLEL_OVERRIDE:-}"

normalize_onoff() {
  local val="$1"
  case "${val^^}" in
    ON|YES|Y|TRUE|1) printf 'ON' ;;
    OFF|NO|N|FALSE|0) printf 'OFF' ;;
    *) printf '%s' "${val}" ;;
  esac
}

show_or_auto() {
  local val="$1"
  if [[ -z "${val}" ]]; then
    printf 'auto'
  else
    printf '%s' "${val}"
  fi
}

if [[ "${use_ci_configure}" == "1" ]]; then
  if [[ -z "${preset_override}" ]]; then
    echo "PRESET is required when using --use-ci-configure"
    exit 1
  fi
  if [[ -z "${variant_override}" ]]; then
    echo "VARIANT is required when using --use-ci-configure"
    exit 1
  fi
  if [[ "${variant_override}" == "client" && -z "${localclient_override}" ]]; then
    echo "LOCALCLIENT is required for VARIANT=client when using --use-ci-configure"
    exit 1
  fi
  export PRESET="${preset_override}"
  export VARIANT="${variant_override}"
  if [[ -n "${localclient_override}" ]]; then
    export LOCALCLIENT="${localclient_override}"
  fi
  export ENABLE_SSL="${enable_ssl:-ON}"
  export ENABLE_LDAP="${enable_ldap:-ON}"
  if [[ -n "${parallel_override}" ]]; then
    export CMAKE_BUILD_PARALLEL_LEVEL="${parallel_override}"
  fi
  bash "${root_dir}/ci/run/cmake-configure.sh"
  if [[ "${build_install}" == "1" ]]; then
    bash "${root_dir}/ci/run/cmake-build.sh"
  fi
  exit 0
fi

if [[ -n "${variant_override}" ]]; then
  if [[ "${variant_override}" == "client" && -z "${localclient_override}" ]]; then
    echo "LOCALCLIENT is required for VARIANT=client"
    exit 1
  fi
  if [[ -z "${enable_ssl}" ]]; then
    enable_ssl="ON"
  fi
  if [[ -z "${enable_ldap}" ]]; then
    enable_ldap="ON"
  fi
fi

cmake_args=(
  -S "${root_dir}"
  -B "${build_dir}"
  -DUSE_GNUINSTALLDIRS="${use_gnuinstall}"
  -DCMAKE_INSTALL_PREFIX="${cmake_prefix}"
  -DXYMONTOPDIR="${xymontopdir}"
  -DXYMONHOME="${xymonhome}"
  -DXYMONCLIENTHOME="${xymonclienthome}"
  -DXYMONVAR="${xymonvar}"
  -DXYMONLOGDIR="${xymonlogdir}"
  -DCGIDIR="${cgidir}"
  -DSECURECGIDIR="${securecgidir}"
  -DXYMONUSER="${xymonuser}"
  -DXYMONHOSTNAME="${xymonhostname}"
  -DXYMONHOSTIP="${xymonhostip}"
  -DXYMONHOSTOS="${xymonhostos}"
  -DXYMONHOSTURL="${xymonhosturl}"
  -DXYMONCGIURL="${xymoncgiurl}"
  -DSECUREXYMONCGIURL="${securexymoncgiurl}"
  -DMANROOT="${manroot}"
  -DHTTPDGID="${httpdgid}"
  -DHTTPDGID_CHGRP="${httpdgid_chgrp}"
  -DFPING="${fping_path}"
  -DMAILPROGRAM="${mail_program}"
  -DRRD_INCLUDE_DIR="${rrdinclude}"
  -DRRD_LIBRARY_DIR="${rrdlib}"
  -DPCRE_INCLUDE_DIR="${pcreinclude}"
  -DPCRE_LIBRARY_DIR="${pcrelib}"
  -DSSL_INCLUDE_DIR="${sslinclude}"
  -DSSL_LIBRARY_DIR="${ssllib}"
  -DLDAP_INCLUDE_DIR="${ldapinclude}"
  -DLDAP_LIBRARY_DIR="${ldaplib}"
  -DCARES_INCLUDE_DIR="${caresinclude}"
  -DCARES_LIBRARY_DIR="${careslib}"
)

if [[ -n "${variant_override}" ]]; then
  cmake_args+=(-DXYMON_VARIANT="${variant_override}")
fi
if [[ -n "${localclient_override}" ]]; then
  cmake_args+=(-DLOCALCLIENT="${localclient_override}")
fi
if [[ -n "${enable_rrd}" ]]; then
  cmake_args+=(-DENABLE_RRD="${enable_rrd}")
fi
if [[ -n "${enable_snmp}" ]]; then
  cmake_args+=(-DENABLE_SNMP="${enable_snmp}")
fi
if [[ -n "${enable_ssl}" ]]; then
  cmake_args+=(-DENABLE_SSL="${enable_ssl}")
fi
if [[ -n "${enable_ldap}" ]]; then
  cmake_args+=(-DENABLE_LDAP="${enable_ldap}")
fi

cmake "${cmake_args[@]}"

echo ""
if [[ -n "${parallel_override}" ]]; then
  echo "Configure complete. Build with: cmake --build ${build_dir} --parallel ${parallel_override}"
else
  echo "Configure complete. Build with: cmake --build ${build_dir}"
fi

if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
  cache_val() {
    local key="$1"
    awk -F= -v k="${key}" '$0 ~ "^"k":" {print $2; exit}' "${build_dir}/CMakeCache.txt"
  }

  echo ""
  echo "Detected by CMake:"
  rrd_inc="$(cache_val RRD_INCLUDE_DIR)"
  rrd_libdir="$(cache_val RRD_LIBRARY_DIR)"
  rrd_libfile="$(cache_val RRD_LIBRARY)"
  if [[ -z "${rrd_inc}" ]]; then rrd_inc="$(cache_val RRD_INCLUDE_DIR)"; fi
  if [[ -z "${rrd_libdir}" && -n "${rrd_libfile}" ]]; then rrd_libdir="$(dirname "${rrd_libfile}")"; fi

  pcre_inc="$(cache_val PCRE_INCLUDE_DIR)"
  pcre_libdir="$(cache_val PCRE_LIBRARY_DIR)"
  pcre_libfile="$(cache_val PCRE_LIBRARY)"
  if [[ -z "${pcre_libdir}" && -n "${pcre_libfile}" ]]; then pcre_libdir="$(dirname "${pcre_libfile}")"; fi

  ssl_inc="$(cache_val SSL_INCLUDE_DIR)"
  ssl_libdir="$(cache_val SSL_LIBRARY_DIR)"
  ssl_libfile="$(cache_val SSL_LIBRARY)"
  if [[ -z "${ssl_libdir}" && -n "${ssl_libfile}" ]]; then ssl_libdir="$(dirname "${ssl_libfile}")"; fi

  ldap_inc="$(cache_val LDAP_INCLUDE_DIR)"
  ldap_libdir="$(cache_val LDAP_LIBRARY_DIR)"
  ldap_libfile="$(cache_val LDAP_LIBRARY)"
  if [[ -z "${ldap_libdir}" && -n "${ldap_libfile}" ]]; then ldap_libdir="$(dirname "${ldap_libfile}")"; fi

  cares_inc="$(cache_val CARES_INCLUDE_DIR)"
  cares_libdir="$(cache_val CARES_LIBRARY_DIR)"
  cares_libfile="$(cache_val CARES_LIBRARY)"
  if [[ -z "${cares_libdir}" && -n "${cares_libfile}" ]]; then cares_libdir="$(dirname "${cares_libfile}")"; fi

  echo "  RRD include/lib = $(show_or_auto "${rrd_inc}") / $(show_or_auto "${rrd_libdir}")"
  echo "    RRD lib file   = $(show_or_auto "${rrd_libfile}")"
  echo "  PCRE include/lib = $(show_or_auto "${pcre_inc}") / $(show_or_auto "${pcre_libdir}")"
  echo "    PCRE lib file  = $(show_or_auto "${pcre_libfile}")"
  echo "  SSL include/lib  = $(show_or_auto "${ssl_inc}") / $(show_or_auto "${ssl_libdir}")"
  echo "    SSL lib file   = $(show_or_auto "${ssl_libfile}")"
  echo "  LDAP include/lib = $(show_or_auto "${ldap_inc}") / $(show_or_auto "${ldap_libdir}")"
  echo "    LDAP lib file  = $(show_or_auto "${ldap_libfile}")"
  echo "  C-ARES include/lib = $(show_or_auto "${cares_inc}") / $(show_or_auto "${cares_libdir}")"
  echo "    C-ARES lib file  = $(show_or_auto "${cares_libfile}")"

  echo ""
  echo "Missing headers (if you enabled the feature):"
  missing_any="0"
  if [[ -z "${rrd_inc}" ]]; then echo "  - RRD headers (rrd.h)"; missing_any="1"; fi
  if [[ -z "${pcre_inc}" ]]; then echo "  - PCRE headers (pcre.h)"; missing_any="1"; fi
  if [[ -z "${ssl_inc}" ]]; then echo "  - OpenSSL headers (openssl/ssl.h)"; missing_any="1"; fi
  if [[ -z "${ldap_inc}" ]]; then echo "  - LDAP headers (ldap.h)"; missing_any="1"; fi
  if [[ -z "${cares_inc}" ]]; then echo "  - C-ARES headers (ares.h)"; missing_any="1"; fi
  if [[ "${missing_any}" == "0" ]]; then
    echo "  (none)"
  fi

  echo ""
  echo "Missing libraries (if you enabled the feature):"
  missing_any="0"
  if [[ -z "${rrd_libfile}" && -z "${rrd_libdir}" ]]; then echo "  - RRD library (librrd)"; missing_any="1"; fi
  if [[ -z "${pcre_libfile}" && -z "${pcre_libdir}" ]]; then echo "  - PCRE library (libpcre)"; missing_any="1"; fi
  if [[ -z "${ssl_libfile}" && -z "${ssl_libdir}" ]]; then echo "  - OpenSSL library (libssl)"; missing_any="1"; fi
  if [[ -z "${ldap_libfile}" && -z "${ldap_libdir}" ]]; then echo "  - LDAP library (libldap)"; missing_any="1"; fi
  if [[ -z "${cares_libfile}" && -z "${cares_libdir}" ]]; then echo "  - C-ARES library (libcares)"; missing_any="1"; fi
  if [[ "${missing_any}" == "0" ]]; then
    echo "  (none)"
  fi

  echo ""
  echo "Feature status:"
  echo "  ENABLE_RRD = $(cache_val ENABLE_RRD)"
  echo "  ENABLE_SNMP = $(cache_val ENABLE_SNMP)"
  echo "  ENABLE_SSL = $(cache_val ENABLE_SSL)"
  echo "  ENABLE_LDAP = $(cache_val ENABLE_LDAP)"
  echo "  ENABLE_CARES = $(cache_val ENABLE_CARES)"
  netsnmp_cfg="$(cache_val NETSNMP_CONFIG)"
  if [[ -z "${netsnmp_cfg}" || "${netsnmp_cfg}" == "NETSNMP_CONFIG-NOTFOUND" ]]; then
    echo "  SNMP collector: net-snmp-config not found"
  else
    echo "  SNMP collector: net-snmp-config = ${netsnmp_cfg}"
  fi
fi

if [[ "${build_install}" == "1" ]]; then
  if [[ "${non_interactive}" != "1" ]]; then
    read -r -p "Build now? [y/N]: " build_confirm
    build_confirm="$(normalize_onoff "${build_confirm}")"
    if [[ "${build_confirm}" == "ON" ]]; then
      if [[ -n "${parallel_override}" ]]; then
        cmake --build "${build_dir}" --parallel "${parallel_override}"
      else
        cmake --build "${build_dir}"
      fi
    else
      echo "Build skipped."
    fi
  else
    if [[ -n "${parallel_override}" ]]; then
      cmake --build "${build_dir}" --parallel "${parallel_override}"
    else
      cmake --build "${build_dir}"
    fi
  fi
fi
