#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/buildsystem/cmake-install-client-dirs.sh
#
# The CMake build takes the client's etc, bin, tmp and logs directories as the
# make build does (install-client-dirs.sh): -DINSTALLCLIENT{ETC,BIN,TMP,LOG}DIR.
# Each relocated directory is linked back from its old place under
# XYMONCLIENTHOME, the drop-in directories the shipped configs include are made
# in the relocated etc, a reinstall succeeds, and a real directory left where a
# link has to go stops the install before anything is installed.
#
# A client build of this tree, configured with every client directory moved,
# installed into a scratch DESTDIR. Run only through tests/testsuite-cmake: it
# configures and builds a CMake tree of its own.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

[ -n "${XYMON_CMAKE_BUILDDIR:-}" ] || skip "not a CMake build (run through tests/testsuite-cmake)"
command -v cmake >/dev/null 2>&1 || skip "cmake not found"

ROOT=$(find_root)
work=$(mktempdir)
# bsd_local builds every path from XYMON_BSD_LOCALBASE, so the client's home is
# known on any platform: a client-only build's home is its XYMONTOPDIR.
home=/xc/libexec/xymon

cmake -S "$ROOT" -B "$work/b" -DXYMON_VARIANT=client -DXYMON_LAYOUT=bsd_local -DXYMON_BSD_LOCALBASE=/xc \
	-DINSTALLCLIENTETCDIR=/etc/xymon-client -DINSTALLCLIENTBINDIR=/usr/libexec/xymon-client \
	-DINSTALLCLIENTTMPDIR=/var/tmp/xymon-client -DINSTALLCLIENTLOGDIR=/var/log/xymon-client/ \
	>"$work/configure.log" 2>&1 || fail "configuring a client build failed: $(tail -5 "$work/configure.log")"
cmake --build "$work/b" -j 4 >"$work/build.log" 2>&1 \
	|| fail "building the client failed: $(tail -5 "$work/build.log")"

install_to() {  # install_to <stage> -- returns cmake's status
	DESTDIR=$1 cmake --install "$work/b" >"$1.log" 2>&1
}

st=$work/moved
install_to "$st" || fail "cmake --install failed with the directories relocated: $(tail -5 "$st.log")"
[ -f "$st/etc/xymon-client/xymonclient.cfg" ] \
	|| fail "INSTALLCLIENTETCDIR was not used: no xymonclient.cfg in /etc/xymon-client"
[ -f "$st/usr/libexec/xymon-client/xymonclient.sh" ] \
	|| fail "INSTALLCLIENTBINDIR was not used: no xymonclient.sh in /usr/libexec/xymon-client"
for dd in clientlaunch.d xymonclient.d; do
	[ -d "$st/etc/xymon-client/$dd" ] || fail "the relocated install made no /etc/xymon-client/$dd, which the shipped config includes"
done
# The trailing slash given for INSTALLCLIENTLOGDIR is not part of the link.
for pair in etc:/etc/xymon-client bin:/usr/libexec/xymon-client tmp:/var/tmp/xymon-client logs:/var/log/xymon-client; do
	d=${pair%%:*} to=${pair#*:}
	[ -d "$st$to" ] || fail "the relocated $d directory $to was not created"
	[ -L "$st$home/$d" ] || fail "$home/$d was not linked to its new place $to"
	got=$(readlink "$st$home/$d")
	[ "$got" = "$to" ] || fail "$home/$d links to '$got', expected '$to'"
done

install_to "$st" || fail "a second cmake --install of the same layout failed: $(tail -5 "$st.log")"
[ -L "$st$home/etc" ] || fail "a reinstall replaced the link $home/etc"

# A real directory where the link goes: an earlier install of the default
# layout. The install stops, says what to do, and installs nothing.
old=$work/old
mkdir -p "$old$home/etc"
if install_to "$old"; then
	fail "cmake --install went ahead with a real $home/etc where the link to /etc/xymon-client goes"
fi
# CMake wraps the message across lines: join them before matching.
said=$(tr -s ' \n' '  ' <"$old.log")
case $said in
*"$home/etc is a real directory"*"Move its contents to /etc/xymon-client"*) ;;
*) fail "the install stopped without saying why: $(tail -5 "$old.log")" ;;
esac
[ ! -e "$old/etc/xymon-client/xymonclient.cfg" ] \
	|| fail "the install stopped on the real $home/etc only after installing files"

pass "a CMake client install puts etc, bin, tmp and logs where INSTALLCLIENT*DIR say, links them back under XYMONCLIENTHOME, and stops on a real directory in the way"
