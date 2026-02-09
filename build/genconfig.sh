#!/bin/sh

# Simpler than autoconf, but it does what we need it to do right now.

umask 022

# Ensure relative paths resolve from the source top dir.
script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)" || exit 1
top_dir="$(CDPATH= cd -- "$script_dir/.." && pwd)" || exit 1
cd "$top_dir" || exit 1

makefile_vals() {
  local key="$1"
  local file="$top_dir/Makefile"
  if [ ! -f "$file" ]; then
    return
  fi
  awk -F '=' -v key="$key" '$1 ~ "^"key"[[:space:]]*$" { val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); print val; exit }' "$file"
}

write_xydefs() {
  local topdir="${1:-/var/lib/xymon}"
  local logdir="${2:-/var/log/xymon}"
  local home="${3:-$topdir/server}"
  local client_home="${4:-$topdir/client}"
  local host="${5:-$(uname -n)}"
  local ip="${6:-127.0.0.1}"
  local os="${7:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
  printf '%s\n' "#define XYMONTOPDIR \"$topdir\"" "#define XYMONHOME \"$home\"" "#define XYMONCLIENTHOME \"$client_home\"" "#define XYMONLOGDIR \"$logdir\"" "#define XYMONHOSTNAME \"$host\"" "#define XYMONHOSTIP \"$ip\"" "#define XYMONHOSTOS \"$os\"" >>"$tmpcfg"
}

tmpcfg="$(mktemp include/config.h.XXXXXX)" || exit 1
trap 'rm -f "$tmpcfg"' EXIT

echo "/* This file is auto-generated */" >"$tmpcfg"
echo "#ifndef __CONFIG_H__" >>"$tmpcfg"
echo "#define __CONFIG_H__ 1" >>"$tmpcfg"

echo "Checking for socklen_t"
$CC -c -o build/testfile.o $CFLAGS build/test-socklent.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_SOCKLEN_T 1" >>"$tmpcfg"
else
	echo "#undef HAVE_SOCKLEN_T" >>"$tmpcfg"
fi

echo "Checking for snprintf"
$CC -c -o build/testfile.o $CFLAGS build/test-snprintf.c 1>/dev/null 2>&1
if test $? -eq 0; then
	$CC -o build/testfile $CFLAGS build/testfile.o 1>/dev/null 2>&1
	if test $? -eq 0; then
		echo "#define HAVE_SNPRINTF 1" >>"$tmpcfg"
	else
		echo "#undef HAVE_SNPRINTF" >>"$tmpcfg"
	fi
else
	echo "#undef HAVE_SNPRINTF" >>"$tmpcfg"
fi

echo "Checking for vsnprintf"
$CC -c -o build/testfile.o $CFLAGS build/test-vsnprintf.c 1>/dev/null 2>&1
if test $? -eq 0; then
	$CC -o build/testfile $CFLAGS build/testfile.o 1>/dev/null 2>&1
	if test $? -eq 0; then
		echo "#define HAVE_VSNPRINTF 1" >>"$tmpcfg"
	else
		echo "#undef HAVE_VSNPRINTF" >>"$tmpcfg"
	fi
else
	echo "#undef HAVE_VSNPRINTF" >>"$tmpcfg"
fi

echo "Checking for rpc/rpcent.h"
$CC -c -o build/testfile.o $CFLAGS build/test-rpcenth.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_RPCENT_H 1" >>"$tmpcfg"
else
	echo "#undef HAVE_RPCENT_H" >>"$tmpcfg"
fi

echo "Checking for sys/select.h"
$CC -c -o build/testfile.o $CFLAGS build/test-sysselecth.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_SYS_SELECT_H 1" >>"$tmpcfg"
else
	echo "#undef HAVE_SYS_SELECT_H" >>"$tmpcfg"
fi

echo "Checking for u_int32_t typedef"
$CC -c -o build/testfile.o $CFLAGS build/test-uint.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_UINT32_TYPEDEF 1" >>"$tmpcfg"
else
	echo "#undef HAVE_UINT32_TYPEDEF" >>"$tmpcfg"
fi

echo "Checking for PATH_MAX definition"
$CC -o build/testfile $CFLAGS build/test-pathmax.c 1>/dev/null 2>&1
if test -x build/testfile; then ./build/testfile >>"$tmpcfg"; fi

echo "Checking for SHUT_RD/WR/RDWR definitions"
$CC -o build/testfile $CFLAGS build/test-shutdown.c 1>/dev/null 2>&1
if test -x build/testfile; then ./build/testfile >>"$tmpcfg"; fi

echo "Checking for strtoll()"
$CC -c -o build/testfile.o $CFLAGS build/test-strtoll.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_STRTOLL_H 1" >>"$tmpcfg"
else
	echo "#undef HAVE_STRTOLL_H" >>"$tmpcfg"
fi

echo "Checking for uname"
$CC -c -o build/testfile.o $CFLAGS build/test-uname.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_UNAME 1" >>"$tmpcfg"
else
	echo "#undef HAVE_UNAME" >>"$tmpcfg"
fi

echo "Checking for setenv"
$CC -c -o build/testfile.o $CFLAGS build/test-setenv.c 1>/dev/null 2>&1
if test $? -eq 0; then
		echo "#define HAVE_SETENV 1" >>"$tmpcfg"
else
	echo "#undef HAVE_SETENV" >>"$tmpcfg"
fi


# This is experimental for 4.3.x
#echo "Checking for POSIX binary tree functions"
#$CC -c -o build/testfile.o $CFLAGS build/test-bintree.c 1>/dev/null 2>&1
#if test $? -eq 0; then
#	echo "#define HAVE_BINARY_TREE 1" >>include/config.h
#else
	echo "#undef HAVE_BINARY_TREE" >>"$tmpcfg"
#fi

if [ -f "$top_dir/Makefile" ]; then
  xy_topdir="$(makefile_vals XYMONTOPDIR)"
  xy_logdir="$(makefile_vals XYMONLOGDIR)"
  xy_home="$(makefile_vals XYMONHOME)"
  xy_client_home="$(makefile_vals XYMONCLIENTHOME)"
  xy_host="$(makefile_vals XYMONHOSTNAME)"
  xy_ip="$(makefile_vals XYMONHOSTIP)"
  xy_os="$(makefile_vals XYMONHOSTOS)"
  write_xydefs "$xy_topdir" "$xy_logdir" "$xy_home" "$xy_client_home" "$xy_host" "$xy_ip" "$xy_os"
fi


echo "#endif" >>"$tmpcfg"

mv -f "$tmpcfg" include/config.h
trap - EXIT

echo "config.h created"
rm -f testfile.o testfile

exit 0
