#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${root_dir}/build-cmake"
non_interactive="0"
use_gnuinstall_override=""
build_install="1"
clean_build_dir="1"
prefix_override=""
XYMONTOPDIR_OVERRIDE=""
XYMONHOME_OVERRIDE=""
XYMONCLIENTHOME_OVERRIDE=""
XYMONVAR_OVERRIDE=""
XYMONLOGDIR_OVERRIDE=""
CGIDIR_OVERRIDE=""
SECURECGIDIR_OVERRIDE=""
XYMONUSER_OVERRIDE=""
XYMONHOSTNAME_OVERRIDE=""
XYMONHOSTIP_OVERRIDE=""
XYMONHOSTOS_OVERRIDE=""
XYMONHOSTURL_OVERRIDE=""
XYMONCGIURL_OVERRIDE=""
SECUREXYMONCGIURL_OVERRIDE=""
MANROOT_OVERRIDE=""
HTTPDGID_OVERRIDE=""
ENABLE_RRD_OVERRIDE=""
ENABLE_SNMP_OVERRIDE=""
ENABLE_SSL_OVERRIDE=""
ENABLE_LDAP_OVERRIDE=""
FPING_OVERRIDE=""
MAILPROGRAM_OVERRIDE=""
RRDINCDIR_OVERRIDE=""
RRDLIBDIR_OVERRIDE=""
PCREINCDIR_OVERRIDE=""
PCRELIBDIR_OVERRIDE=""
SSLINCDIR_OVERRIDE=""
SSLLIBDIR_OVERRIDE=""
LDAPINCDIR_OVERRIDE=""
LDAPLIBDIR_OVERRIDE=""
CARESINCDIR_OVERRIDE=""
CARESLIBDIR_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: ./configure.cmake.sh [options]

Options:
  --non-interactive     Use defaults and skip prompts
  --gnuinstall          Enable GNUInstallDirs layout
  --prefix DIR          Set install prefix (implies --gnuinstall)
  --xymontopdir DIR     Set XYMONTOPDIR
  --xymonhome DIR       Set XYMONHOME
  --xymonclienthome DIR Set XYMONCLIENTHOME
  --xymonvar DIR        Set XYMONVAR
  --xymonlogdir DIR     Set XYMONLOGDIR
  --cgidir DIR          Set CGIDIR
  --securecgidir DIR    Set SECURECGIDIR
  --xymonuser USER      Set XYMONUSER
  --xymonhostname NAME  Set XYMONHOSTNAME
  --xymonhostip IP      Set XYMONHOSTIP
  --xymonhostos OS      Set XYMONHOSTOS
  --xymonhosturl URL    Set XYMONHOSTURL
  --xymoncgiurl URL     Set XYMONCGIURL
  --securexymoncgiurl URL  Set SECUREXYMONCGIURL
  --manroot DIR         Set MANROOT
  --httpdgid GROUP      Set HTTPDGID (webserver group)
  --enable-rrd yes/no   Set ENABLE_RRD
  --enable-snmp yes/no  Set ENABLE_SNMP
  --enable-ssl yes/no   Set ENABLE_SSL
  --enable-ldap yes/no  Set ENABLE_LDAP
  --fping PATH          Set FPING
  --mailprogram CMD     Set MAILPROGRAM
  --rrdinclude DIR      Set RRD include dir
  --rrdlib DIR          Set RRD library dir
  --pcreinclude DIR     Set PCRE include dir
  --pcrelib DIR         Set PCRE library dir
  --sslinclude DIR      Set OpenSSL include dir
  --ssllib DIR          Set OpenSSL library dir
  --ldapinclude DIR     Set LDAP include dir
  --ldaplib DIR         Set LDAP library dir
  --caresinclude DIR    Set C-ARES include dir
  --careslib DIR        Set C-ARES library dir
  --build-dir DIR       Override build directory (default: build-cmake)
  --no-clean            Do not remove build directory before configuring
  --no-build-install    Configure only (skip build/install)
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) non_interactive="1"; shift ;;
    --gnuinstall) use_gnuinstall_override="ON"; shift ;;
    --prefix) prefix_override="$2"; use_gnuinstall_override="ON"; shift 2 ;;
    --xymontopdir) XYMONTOPDIR_OVERRIDE="$2"; shift 2 ;;
    --xymonhome) XYMONHOME_OVERRIDE="$2"; shift 2 ;;
    --xymonclienthome) XYMONCLIENTHOME_OVERRIDE="$2"; shift 2 ;;
    --xymonvar) XYMONVAR_OVERRIDE="$2"; shift 2 ;;
    --xymonlogdir) XYMONLOGDIR_OVERRIDE="$2"; shift 2 ;;
    --cgidir) CGIDIR_OVERRIDE="$2"; shift 2 ;;
    --securecgidir) SECURECGIDIR_OVERRIDE="$2"; shift 2 ;;
    --xymonuser) XYMONUSER_OVERRIDE="$2"; shift 2 ;;
    --xymonhostname) XYMONHOSTNAME_OVERRIDE="$2"; shift 2 ;;
    --xymonhostip) XYMONHOSTIP_OVERRIDE="$2"; shift 2 ;;
    --xymonhostos) XYMONHOSTOS_OVERRIDE="$2"; shift 2 ;;
    --xymonhosturl) XYMONHOSTURL_OVERRIDE="$2"; shift 2 ;;
    --xymoncgiurl) XYMONCGIURL_OVERRIDE="$2"; shift 2 ;;
    --securexymoncgiurl) SECUREXYMONCGIURL_OVERRIDE="$2"; shift 2 ;;
    --manroot) MANROOT_OVERRIDE="$2"; shift 2 ;;
    --httpdgid) HTTPDGID_OVERRIDE="$2"; shift 2 ;;
    --enable-rrd) ENABLE_RRD_OVERRIDE="$2"; shift 2 ;;
    --enable-snmp) ENABLE_SNMP_OVERRIDE="$2"; shift 2 ;;
    --enable-ssl) ENABLE_SSL_OVERRIDE="$2"; shift 2 ;;
    --enable-ldap) ENABLE_LDAP_OVERRIDE="$2"; shift 2 ;;
    --fping) FPING_OVERRIDE="$2"; shift 2 ;;
    --mailprogram) MAILPROGRAM_OVERRIDE="$2"; shift 2 ;;
    --rrdinclude) RRDINCDIR_OVERRIDE="$2"; shift 2 ;;
    --rrdlib) RRDLIBDIR_OVERRIDE="$2"; shift 2 ;;
    --pcreinclude) PCREINCDIR_OVERRIDE="$2"; shift 2 ;;
    --pcrelib) PCRELIBDIR_OVERRIDE="$2"; shift 2 ;;
    --sslinclude) SSLINCDIR_OVERRIDE="$2"; shift 2 ;;
    --ssllib) SSLLIBDIR_OVERRIDE="$2"; shift 2 ;;
    --ldapinclude) LDAPINCDIR_OVERRIDE="$2"; shift 2 ;;
    --ldaplib) LDAPLIBDIR_OVERRIDE="$2"; shift 2 ;;
    --caresinclude) CARESINCDIR_OVERRIDE="$2"; shift 2 ;;
    --careslib) CARESLIBDIR_OVERRIDE="$2"; shift 2 ;;
    --build-dir) build_dir="$2"; shift 2 ;;
    --no-clean) clean_build_dir="0"; shift ;;
    --no-build-install) build_install="0"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

prompt() {
  local prompt_text="$1"
  local default_value="$2"
  local value
  if [[ "${non_interactive}" == "1" ]]; then
    printf '%s' "${default_value}"
    return
  fi
  read -r -p "${prompt_text} [${default_value}]: " value
  if [[ -z "${value}" ]]; then
    value="${default_value}"
  fi
  printf '%s' "${value}"
}

choose_value() {
  local prompt_text="$1"
  local default_value="$2"
  local override_value="$3"
  if [[ -n "${override_value}" ]]; then
    printf '%s' "${override_value}"
  else
    prompt "${prompt_text}" "${default_value}"
  fi
}

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

section() {
  echo ""
  echo "== $1 =="
}

section "Layout"
use_gnuinstall_default="no"
if [[ -n "${use_gnuinstall_override}" ]]; then
  use_gnuinstall_default="${use_gnuinstall_override}"
fi
use_gnuinstall="$(normalize_onoff "$(choose_value "Use GNUInstallDirs layout (yes/no)" "${use_gnuinstall_default}" "${use_gnuinstall_override}")")"

cmake_prefix_default="/usr/local"
cmake_prefix="/"
if [[ "${use_gnuinstall}" == "ON" ]]; then
  cmake_prefix="$(choose_value "Install prefix" "${cmake_prefix_default}" "${prefix_override}")"
else
  echo "Note: install folder prefix is ignored when USE_GNUINSTALLDIRS=OFF (legacy layout uses fixed paths)"
fi

section "Paths"
xymontopdir_default="/var/lib/xymon"
if [[ "${use_gnuinstall}" == "ON" ]]; then
  xymontopdir_default="${cmake_prefix}/xymon"
fi
xymontopdir="$(choose_value "Xymon top directory" "${xymontopdir_default}" "${XYMONTOPDIR_OVERRIDE}")"

xymonhome_default="${xymontopdir}/server"
xymonclienthome_default="${xymontopdir}/client"
xymonhome="$(choose_value "Xymon server home" "${xymonhome_default}" "${XYMONHOME_OVERRIDE}")"
xymonclienthome="$(choose_value "Xymon client home" "${xymonclienthome_default}" "${XYMONCLIENTHOME_OVERRIDE}")"

xymonvar_default="${xymontopdir}/data"
xymonlogdir_default="/var/log/xymon"
if [[ "${use_gnuinstall}" == "ON" ]]; then
  xymonvar_default="${cmake_prefix}/var/lib/xymon/data"
  xymonlogdir_default="${cmake_prefix}/var/log/xymon"
fi
xymonvar="$(choose_value "Xymon var directory" "${xymonvar_default}" "${XYMONVAR_OVERRIDE}")"
xymonlogdir="$(choose_value "Xymon log directory" "${xymonlogdir_default}" "${XYMONLOGDIR_OVERRIDE}")"

cgidir_default="/var/lib/xymon/cgi-bin"
securecgidir_default="/var/lib/xymon/cgi-secure"
if [[ "${use_gnuinstall}" == "ON" ]]; then
  cgidir_default="${cmake_prefix}/share/xymon/cgi-bin"
  securecgidir_default="${cmake_prefix}/share/xymon/cgi-secure"
fi
cgidir="$(choose_value "CGI dir" "${cgidir_default}" "${CGIDIR_OVERRIDE}")"
securecgidir="$(choose_value "Secure CGI dir" "${securecgidir_default}" "${SECURECGIDIR_OVERRIDE}")"

section "Identity"
default_hostname="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")"
default_hostos="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "linux")"
default_hostip="127.0.0.1"
if command -v hostname >/dev/null 2>&1; then
  if hostname -I >/dev/null 2>&1; then
    default_hostip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
fi
default_hosturl="http://${default_hostname}"
xymoncgiurl_default="/xymon-cgi"
securexymoncgiurl_default="/xymon-seccgi"
httpdgid_default="nobody"

xymonuser="$(choose_value "Xymon user" "xymon" "${XYMONUSER_OVERRIDE}")"
xymonhostname="${default_hostname}"
xymonhostip="${default_hostip}"
xymonhostos="${default_hostos}"
xymonhosturl="${default_hosturl}"
xymoncgiurl="${xymoncgiurl_default}"
securexymoncgiurl="${securexymoncgiurl_default}"
httpdgid="${httpdgid_default}"

manroot_default="/usr/local/man"
if [[ "${use_gnuinstall}" == "ON" ]]; then
  manroot_default="${cmake_prefix}/share/man"
fi
manroot="${manroot_default}"

enable_rrd=""
enable_snmp=""
enable_ssl=""
enable_ldap=""

section "Programs"
fping_path="$(choose_value "Path to fping" "/usr/bin/fping" "${FPING_OVERRIDE}")"
mail_program="$(choose_value "Mail program" "/usr/sbin/sendmail -t" "${MAILPROGRAM_OVERRIDE}")"

advanced_mode="no"
if [[ "${non_interactive}" != "1" ]]; then
  advanced_mode="$(normalize_onoff "$(prompt "Advanced mode (override auto-detected values) (yes/no)" "no")")"
fi
if [[ -n "${XYMONHOSTNAME_OVERRIDE}${XYMONHOSTIP_OVERRIDE}${XYMONHOSTOS_OVERRIDE}${XYMONHOSTURL_OVERRIDE}${XYMONCGIURL_OVERRIDE}${SECUREXYMONCGIURL_OVERRIDE}${MANROOT_OVERRIDE}${HTTPDGID_OVERRIDE}${RRDINCDIR_OVERRIDE}${RRDLIBDIR_OVERRIDE}${PCREINCDIR_OVERRIDE}${PCRELIBDIR_OVERRIDE}${SSLINCDIR_OVERRIDE}${SSLLIBDIR_OVERRIDE}${LDAPINCDIR_OVERRIDE}${LDAPLIBDIR_OVERRIDE}${CARESINCDIR_OVERRIDE}${CARESLIBDIR_OVERRIDE}${ENABLE_RRD_OVERRIDE}${ENABLE_SNMP_OVERRIDE}${ENABLE_SSL_OVERRIDE}${ENABLE_LDAP_OVERRIDE}" ]]; then
  advanced_mode="ON"
fi

rrdinclude=""
rrdlib=""
pcreinclude=""
pcrelib=""
sslinclude=""
ssllib=""
ldapinclude=""
ldaplib=""
caresinclude=""
careslib=""

if [[ "${advanced_mode}" == "ON" ]]; then
  section "Features (advanced)"
  enable_rrd="$(normalize_onoff "$(choose_value "Enable RRD (yes/no)" "yes" "${ENABLE_RRD_OVERRIDE}")")"
  enable_snmp="$(normalize_onoff "$(choose_value "Enable SNMP collector (yes/no)" "yes" "${ENABLE_SNMP_OVERRIDE}")")"
  enable_ssl="$(normalize_onoff "$(choose_value "Enable SSL checks (yes/no)" "yes" "${ENABLE_SSL_OVERRIDE}")")"
  enable_ldap="$(normalize_onoff "$(choose_value "Enable LDAP checks (yes/no)" "yes" "${ENABLE_LDAP_OVERRIDE}")")"

  section "Identity (advanced)"
  xymonhostname="$(choose_value "Xymon host name" "${default_hostname}" "${XYMONHOSTNAME_OVERRIDE}")"
  xymonhostip="$(choose_value "Xymon host IP" "${default_hostip}" "${XYMONHOSTIP_OVERRIDE}")"
  xymonhostos="$(choose_value "Xymon host OS" "${default_hostos}" "${XYMONHOSTOS_OVERRIDE}")"
  xymonhosturl="$(choose_value "Xymon host URL" "${default_hosturl}" "${XYMONHOSTURL_OVERRIDE}")"
  xymoncgiurl="$(choose_value "Xymon CGI URL" "${xymoncgiurl_default}" "${XYMONCGIURL_OVERRIDE}")"
  securexymoncgiurl="$(choose_value "Xymon secure CGI URL" "${securexymoncgiurl_default}" "${SECUREXYMONCGIURL_OVERRIDE}")"

  section "Manual pages (advanced)"
  manroot="$(choose_value "Man page root" "${manroot_default}" "${MANROOT_OVERRIDE}")"

  section "Webserver group (advanced)"
  httpdgid="$(choose_value "Webserver group for reports/snap (HTTPDGID)" "${httpdgid_default}" "${HTTPDGID_OVERRIDE}")"

  section "Libraries (advanced, leave empty for auto-detect)"
  rrdinclude="$(choose_value "RRD include dir" "" "${RRDINCDIR_OVERRIDE}")"
  rrdlib="$(choose_value "RRD library dir" "" "${RRDLIBDIR_OVERRIDE}")"
  pcreinclude="$(choose_value "PCRE include dir" "" "${PCREINCDIR_OVERRIDE}")"
  pcrelib="$(choose_value "PCRE library dir" "" "${PCRELIBDIR_OVERRIDE}")"
  sslinclude="$(choose_value "OpenSSL include dir" "" "${SSLINCDIR_OVERRIDE}")"
  ssllib="$(choose_value "OpenSSL library dir" "" "${SSLLIBDIR_OVERRIDE}")"
  ldapinclude="$(choose_value "LDAP include dir" "" "${LDAPINCDIR_OVERRIDE}")"
  ldaplib="$(choose_value "LDAP library dir" "" "${LDAPLIBDIR_OVERRIDE}")"
  caresinclude="$(choose_value "C-ARES include dir" "" "${CARESINCDIR_OVERRIDE}")"
  careslib="$(choose_value "C-ARES library dir" "" "${CARESLIBDIR_OVERRIDE}")"
fi

if [[ "${cgidir}" == "${securecgidir}" ]]; then
  securexymoncgiurl="${xymoncgiurl}"
fi

echo ""
echo "Summary:"
echo "  USE_GNUINSTALLDIRS = ${use_gnuinstall}"
echo "  CMAKE_INSTALL_PREFIX = ${cmake_prefix}"
echo "  XYMONTOPDIR = ${xymontopdir}"
echo "  XYMONHOME = ${xymonhome}"
echo "  XYMONCLIENTHOME = ${xymonclienthome}"
echo "  XYMONVAR = ${xymonvar}"
echo "  XYMONLOGDIR = ${xymonlogdir}"
echo "  CGIDIR = ${cgidir}"
echo "  SECURECGIDIR = ${securecgidir}"
echo "  XYMONUSER = ${xymonuser}"
echo "  XYMONHOSTNAME = ${xymonhostname}"
echo "  XYMONHOSTIP = ${xymonhostip}"
echo "  XYMONHOSTOS = ${xymonhostos}"
echo "  XYMONHOSTURL = ${xymonhosturl}"
echo "  XYMONCGIURL = ${xymoncgiurl}"
echo "  SECUREXYMONCGIURL = ${securexymoncgiurl}"
echo "  CGI URL defaults = ${xymoncgiurl_default} (secure ${securexymoncgiurl_default})"
echo "  MANROOT = ${manroot}"
echo "  HTTPDGID = ${httpdgid}"
echo "  ENABLE_RRD = ${enable_rrd}"
echo "  ENABLE_SNMP = ${enable_snmp}"
echo "  ENABLE_SSL = ${enable_ssl}"
echo "  ENABLE_LDAP = ${enable_ldap}"
echo "  FPING = ${fping_path}"
echo "  MAILPROGRAM = ${mail_program}"
echo "  RRD include/lib = $(show_or_auto "${rrdinclude}") / $(show_or_auto "${rrdlib}")"
echo "  PCRE include/lib = $(show_or_auto "${pcreinclude}") / $(show_or_auto "${pcrelib}")"
echo "  SSL include/lib = $(show_or_auto "${sslinclude}") / $(show_or_auto "${ssllib}")"
echo "  LDAP include/lib = $(show_or_auto "${ldapinclude}") / $(show_or_auto "${ldaplib}")"
echo "  C-ARES include/lib = $(show_or_auto "${caresinclude}") / $(show_or_auto "${careslib}")"

if [[ "${cgidir}" == "${securecgidir}" ]]; then
  echo "  NOTE: SECUREXYMONCGIURL forced to match XYMONCGIURL because SECURECGIDIR == CGIDIR"
fi

if [[ "${non_interactive}" != "1" ]]; then
  echo ""
  read -r -p "Proceed with configuration? [y/N]: " confirm
  confirm="$(normalize_onoff "${confirm}")"
  if [[ "${confirm}" != "ON" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

if [[ "${clean_build_dir}" == "1" ]]; then
  if [[ "${non_interactive}" != "1" ]]; then
    read -r -p "Clean build directory '${build_dir}'? [y/N]: " clean_confirm
    clean_confirm="$(normalize_onoff "${clean_confirm}")"
    if [[ "${clean_confirm}" != "ON" ]]; then
      echo "Clean skipped."
    else
      rm -rf "${build_dir}"
    fi
  else
    rm -rf "${build_dir}"
  fi
fi
mkdir -p "${build_dir}"

cmake -S "${root_dir}" -B "${build_dir}" \
  -DUSE_GNUINSTALLDIRS="${use_gnuinstall}" \
  -DCMAKE_INSTALL_PREFIX="${cmake_prefix}" \
  -DXYMONTOPDIR="${xymontopdir}" \
  -DXYMONHOME="${xymonhome}" \
  -DXYMONCLIENTHOME="${xymonclienthome}" \
  -DXYMONVAR="${xymonvar}" \
  -DXYMONLOGDIR="${xymonlogdir}" \
  -DCGIDIR="${cgidir}" \
  -DSECURECGIDIR="${securecgidir}" \
  -DXYMONUSER="${xymonuser}" \
  -DXYMONHOSTNAME="${xymonhostname}" \
  -DXYMONHOSTIP="${xymonhostip}" \
  -DXYMONHOSTOS="${xymonhostos}" \
  -DXYMONHOSTURL="${xymonhosturl}" \
  -DXYMONCGIURL="${xymoncgiurl}" \
  -DSECUREXYMONCGIURL="${securexymoncgiurl}" \
  -DMANROOT="${manroot}" \
  -DHTTPDGID="${httpdgid}" \
  -DFPING="${fping_path}" \
  -DMAILPROGRAM="${mail_program}" \
  -DRRDINCDIR="${rrdinclude}" \
  -DRRDLIBDIR="${rrdlib}" \
  -DPCREINCDIR="${pcreinclude}" \
  -DPCRELIBDIR="${pcrelib}" \
  -DSSLINCDIR="${sslinclude}" \
  -DSSLLIBDIR="${ssllib}" \
  -DLDAPINCDIR="${ldapinclude}" \
  -DLDAPLIBDIR="${ldaplib}" \
  -DCARESINCDIR="${caresinclude}" \
  -DCARESLIBDIR="${careslib}"

if [[ -n "${enable_rrd}" ]]; then
  cmake -S "${root_dir}" -B "${build_dir}" -DENABLE_RRD="${enable_rrd}"
fi
if [[ -n "${enable_snmp}" ]]; then
  cmake -S "${root_dir}" -B "${build_dir}" -DENABLE_SNMP="${enable_snmp}"
fi
if [[ -n "${enable_ssl}" ]]; then
  cmake -S "${root_dir}" -B "${build_dir}" -DENABLE_SSL="${enable_ssl}"
fi
if [[ -n "${enable_ldap}" ]]; then
  cmake -S "${root_dir}" -B "${build_dir}" -DENABLE_LDAP="${enable_ldap}"
fi

echo ""
echo "Configure complete. Build with: cmake --build ${build_dir}"

if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
  cache_val() {
    local key="$1"
    awk -F= -v k="${key}" '$0 ~ "^"k":" {print $2; exit}' "${build_dir}/CMakeCache.txt"
  }

  echo ""
  echo "Detected by CMake:"
  rrd_inc="$(cache_val RRDINCDIR)"
  rrd_libdir="$(cache_val RRDLIBDIR)"
  rrd_libfile="$(cache_val RRD_LIBRARY)"
  if [[ -z "${rrd_inc}" ]]; then rrd_inc="$(cache_val RRD_INCLUDE_DIR)"; fi
  if [[ -z "${rrd_libdir}" && -n "${rrd_libfile}" ]]; then rrd_libdir="$(dirname "${rrd_libfile}")"; fi

  pcre_inc="$(cache_val PCREINCDIR)"
  pcre_libdir="$(cache_val PCRELIBDIR)"
  pcre_libfile="$(cache_val _PCRE_LIB)"
  if [[ -z "${pcre_libdir}" && -n "${pcre_libfile}" ]]; then pcre_libdir="$(dirname "${pcre_libfile}")"; fi

  ssl_inc="$(cache_val SSLINCDIR)"
  ssl_libdir="$(cache_val SSLLIBDIR)"
  ssl_libfile="$(cache_val _SSL_LIB)"
  if [[ -z "${ssl_libdir}" && -n "${ssl_libfile}" ]]; then ssl_libdir="$(dirname "${ssl_libfile}")"; fi

  ldap_inc="$(cache_val LDAPINCDIR)"
  ldap_libdir="$(cache_val LDAPLIBDIR)"
  ldap_libfile="$(cache_val _LDAP_LIB)"
  if [[ -z "${ldap_libdir}" && -n "${ldap_libfile}" ]]; then ldap_libdir="$(dirname "${ldap_libfile}")"; fi

  cares_inc="$(cache_val CARESINCDIR)"
  cares_libdir="$(cache_val CARESLIBDIR)"
  cares_libfile="$(cache_val _CARES_LIB)"
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
      cmake --build "${build_dir}"
    else
      echo "Build skipped."
    fi
    read -r -p "Install now? [y/N]: " install_confirm
    install_confirm="$(normalize_onoff "${install_confirm}")"
    if [[ "${install_confirm}" == "ON" ]]; then
      cmake --install "${build_dir}"
    else
      echo "Install skipped."
    fi
  else
    cmake --build "${build_dir}"
    cmake --install "${build_dir}"
  fi
fi
