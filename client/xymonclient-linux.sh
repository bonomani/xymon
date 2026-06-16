#!/bin/sh
#----------------------------------------------------------------------------#
# Linux client for Xymon                                                     #
#                                                                            #
# Copyright (C) 2005-2011 Henrik Storner <henrik@hswn.dk>                    #
#                                                                            #
# This program is released under the GNU General Public License (GPL),       #
# version 2. See the file "COPYING" for details.                             #
#                                                                            #
#----------------------------------------------------------------------------#
#
# $Id$

echo "[date]"
date
echo "[uname]"
uname -rsmn
echo "[osversion]"
if [ -x /bin/lsb_release ]; then
	/bin/lsb_release -r -i -s | xargs echo
	/bin/lsb_release -a 2>/dev/null
elif [ -x /usr/bin/lsb_release ]; then
	/usr/bin/lsb_release -r -i -s | xargs echo
	/usr/bin/lsb_release -a 2>/dev/null
elif [ -f /etc/redhat-release ]; then
	cat /etc/redhat-release
elif [ -f /etc/gentoo-release ]; then
	cat /etc/gentoo-release
elif [ -f /etc/debian_version ]; then
	echo -n "Debian "
	cat /etc/debian_version
elif [ -f /etc/S?SE-release ]; then
	cat /etc/S?SE-release
elif [ -f /etc/slackware-version ]; then
	cat /etc/slackware-version
elif [ -f /etc/mandrake-release ]; then
	cat /etc/mandrake-release
elif [ -f /etc/fedora-release ]; then
	cat /etc/fedora-release
elif [ -f /etc/arch-release ]; then
	cat /etc/arch-release
fi
echo "[uptime]"
uptime
echo "[who]"
who
echo "[df]"
# Default: exclude every nodev (pseudo) filesystem in df/inode output, except
# rootfs. The always-100%-full read-only images (iso9660, squashfs) are not
# nodev types and are excluded via XYMONCLIENT_FS_EXCLUDE_TYPES below.
if [ -r /proc/filesystems ]; then
	EXCLUDES=$(awk '$1 == "nodev" && $2 != "rootfs" { printf "%s%s", sep, $2; sep=" " }' /proc/filesystems)
else
	# Only the dynamic nodev exclusions are disabled here; the EXCLUDE_TYPES
	# defaults (iso9660/squashfs) and the local-only df -l behavior still apply.
	echo "xymonclient-linux: /proc/filesystems not readable, dynamic nodev exclusions disabled (EXCLUDE_TYPES and df -l still apply)" >&2
	EXCLUDES=""
fi
# Filesystem types are literal tokens, so pathname expansion must not turn a
# configured type such as "fuse.*" into filenames from the working directory.
case $- in
	*f*) FSRESTOREGLOB=no ;;
	*) FSRESTOREGLOB=yes; set -f ;;
esac
# XYMONCLIENT_FS_INCLUDE_TYPES: whitespace-separated FS types to surface even
# though they are flagged nodev and would otherwise be dropped. Defaults to the
# real local filesystems that merely happen to be nodev: zfs (pools have no
# single block device), virtiofs (VM-shared storage) and tmpfs (RAM-backed --
# the noisy /run* tmpfs mounts are filtered server-side in analysis.cfg). Set
# to "" to restore the historical "exclude every nodev type" behaviour, or add
# remote types e.g. "nfs nfs4 ceph" (which also needs
# XYMONCLIENT_FS_DF_LOCAL_ONLY=no, since df -l hides remote mounts).
: "${XYMONCLIENT_FS_INCLUDE_TYPES=zfs virtiofs tmpfs}"
if [ -n "$XYMONCLIENT_FS_INCLUDE_TYPES" ]; then
	# Exact token comparison -- a type is matched literally, never as a
	# regex/glob, so e.g. "fuse.sshfs" cannot collide with another token.
	keep=""
	for e in $EXCLUDES; do
		drop=no
		for t in $XYMONCLIENT_FS_INCLUDE_TYPES; do
			[ "$e" = "$t" ] && { drop=yes; break; }
		done
		[ "$drop" = no ] && keep="$keep $e"
	done
	EXCLUDES="$keep"
fi
# XYMONCLIENT_FS_EXCLUDE_TYPES: whitespace-separated FS types to ALSO exclude,
# on top of the nodev default. Defaults to "iso9660 squashfs fuse.snapfuse" --
# read-only images reported 100% full by design (snaps mount as squashfs, or as
# fuse.snapfuse where snapd falls back to FUSE), none a nodev type, so they must
# be named here. Matching is on the exact df type token; nodev types (overlay,
# bare fuse, ...) are already excluded, so other effective entries name a
# non-nodev type, e.g. adding "fuse.sshfs vfat" to drop a specific FUSE subtype
# and a device-backed mount. Set to "" to monitor these too.
: "${XYMONCLIENT_FS_EXCLUDE_TYPES=iso9660 squashfs fuse.snapfuse}"
if [ -n "$XYMONCLIENT_FS_EXCLUDE_TYPES" ]; then
	for t in $XYMONCLIENT_FS_EXCLUDE_TYPES; do
		case " $EXCLUDES " in
			*" $t "*) ;;  # already in list
			*) EXCLUDES="$EXCLUDES $t" ;;
		esac
	done
fi
[ "$FSRESTOREGLOB" = yes ] && set +f
# XYMONCLIENT_FS_DF_LOCAL_ONLY: defaults to "yes" (current upstream behavior,
# passes -l to df). Set to "no" to drop -l so that remote filesystems
# (nfs, ceph, ...) appear in the output.
DFLOCALONLY="${XYMONCLIENT_FS_DF_LOCAL_ONLY:-yes}"
case "$DFLOCALONLY" in
	yes|no) ;;
	*)
		echo "xymonclient-linux: invalid XYMONCLIENT_FS_DF_LOCAL_ONLY '$DFLOCALONLY', using yes" >&2
		DFLOCALONLY=yes
		;;
esac
# XYMONCLIENT_FS_REMOTE_DF_TIMEOUT: seconds to wait for the remote df probe before
# giving up for this cycle (default 30). A poll BUDGET, not a kill timeout: the
# bg df is left running and reaped later, never killed (D-state ignores SIGKILL).
# Non-numeric/empty/zero -> 30; capped at 3600.
DFTIMEOUT="${XYMONCLIENT_FS_REMOTE_DF_TIMEOUT:-30}"
case "$DFTIMEOUT" in
	*[!0-9]*|'') DFTIMEOUT=30 ;;
	*[1-9]*) ;;
	*) DFTIMEOUT=30 ;;
esac
[ "$DFTIMEOUT" -le 3600 ] 2>/dev/null || DFTIMEOUT=3600

# XYMONCLIENT_FS_REMOTE_HARDBLOCK_TYPES: remote df types whose df HARD-BLOCKS in
# uninterruptible D-state (SIGKILL ignored) when the server is down (NFS, CIFS,
# Ceph, ...). Run behind the sentinel so a dead server can't hang the client.
# Only consulted with DF_LOCAL_ONLY=no; df -l keeps them out otherwise.
: "${XYMONCLIENT_FS_REMOTE_HARDBLOCK_TYPES=nfs nfs4 cifs smb3 ceph glusterfs fuse.glusterfs lustre afs}"
DFPROBEDIR="${XYMONTMP:-/tmp}"

# df_sentinel TAG ARGS... : df for the remote set, at most ONE outstanding per
# TAG. A D-state df can't be killed, so leave it running and detect it next cycle
# instead of launching another -- orphans never accumulate and it self-recovers
# when the server returns. Prints rows (no header); returns 0 with data, 124 when
# unavailable (still wedged, or past the poll budget).
df_sentinel()
{
	_tag="$1"; shift
	_probe="$DFPROBEDIR/df-probe-$_tag"; _pidf="$_probe.pid"
	if [ -f "$_pidf" ]; then
		_old=`cat "$_pidf" 2>/dev/null`
		# Still our wedged df? (verify comm to survive PID reuse across reboots)
		if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null && \
		   [ "`cat /proc/$_old/comm 2>/dev/null`" = df ]; then
			return 124
		fi
		rm -f "$_pidf"
		if [ -s "$_probe" ]; then
			sed -e '1d' "$_probe"; rm -f "$_probe"; return 0  # recovered (1 cycle late)
		fi
		rm -f "$_probe"
	fi
	# No writable probe dir: report unavailable, never run a SYNCHRONOUS remote df
	# here -- a foreground df would reintroduce the very hang the sentinel prevents.
	: 2>/dev/null > "$_probe" || return 124
	df "$@" > "$_probe" 2>/dev/null &
	_pid=$!; echo "$_pid" > "$_pidf"
	_n=0
	while kill -0 "$_pid" 2>/dev/null; do
		[ "$_n" -ge "$DFTIMEOUT" ] && break
		sleep 1; _n=$((_n + 1))
	done
	if kill -0 "$_pid" 2>/dev/null; then
		return 124                            # leave running as the sentinel
	fi
	rm -f "$_pidf"; sed -e '1d' "$_probe"; rm -f "$_probe"; return 0
}

# run_df INODEFLAG : emit df -P output (header + rows). With DF_LOCAL_ONLY=no the
# local and remote sets are collected separately, so a wedged remote server can
# neither block nor stale the local data (df -l can't stat a remote server).
run_df()
{
	DFINODES="$1"
	set -- -P
	[ "$DFINODES" = yes ] && set -- "$@" -i

	case $- in
		*f*) DFRESTOREGLOB=no ;;
		*) DFRESTOREGLOB=yes; set -f ;;
	esac
	for t in $EXCLUDES; do
		set -- "$@" -x "$t"
	done
	[ "$DFRESTOREGLOB" = yes ] && set +f

	if [ "$DFLOCALONLY" = yes ]; then
		df "$@" -l
		return
	fi

	# Local set first -- always fresh, never blocks (df -l skips remote servers).
	df "$@" -l

	# Remote set: find hard-blocking mounts in /proc/mounts (reading it never
	# blocks), then probe them behind the sentinel. Match fs type ($3) by exact
	# set membership, not regex, so "fuse.glusterfs" compares literally.
	[ -r /proc/mounts ] || return 0
	case $- in *f*) _rg=no ;; *) _rg=yes; set -f ;; esac
	_rm=$(awk -v types="$XYMONCLIENT_FS_REMOTE_HARDBLOCK_TYPES" '
		BEGIN { n = split(types, a, /[ \t]+/); for (i = 1; i <= n; i++) t[a[i]] = 1 }
		($3 in t) { print $2 }' /proc/mounts)
	if [ -n "$_rm" ]; then
		_tag=disk; [ "$DFINODES" = yes ] && _tag=inode
		_rout=`df_sentinel "$_tag" "$@" $_rm`
		if [ $? -eq 124 ]; then
			# Probe unavailable -> surface each remote mount as a failed (100%)
			# row so it is not silently dropped (== green) until it recovers.
			for _m in $_rm; do
				echo "unavailable:$_m 1 1 0 100% $_m"
			done
		else
			printf '%s\n' "$_rout"
		fi
	fi
	[ "$_rg" = yes ] && set +f
	return 0
}
# emit_df INODEFLAG LABEL
# Run df (optionally in inode mode) and reproduce the historical sed join.
# The server reads an empty section as green, so a failed df must not pass
# silently: on any nonzero exit with no output, emit a failure marker (no
# recognisable df header) to drive the server yellow. A nonzero exit that still
# prints mounts (e.g. one unreadable mount) and a clean empty exit 0 (Solaris
# all-ZFS inodes) keep their output unchanged.
emit_df()
{
	DFOUT=`run_df "$1"`
	DFRC=$?
	if [ -z "$DFOUT" ]; then
		[ "$DFRC" -eq 0 ] && return
		echo "xymonclient-linux: df $2 collection failed (status $DFRC) with no output; reporting data as unavailable" >&2
		echo "$2 collection failed: df exited $DFRC with no output"
		return
	fi
	# Inode report ("$1" = yes) only: drop filesystems with no inode limit. df
	# prints "-" in the IUse% column (field 5) for them (btrfs, zfs, 9p, many
	# fuse); they can never run out of inodes, so the row is noise and may carry
	# bogus counts (e.g. a negative IUsed on 9p). The header (NR==1) is kept; for
	# the disk report the awk is a pass-through. (awk is already required above,
	# so this adds no new dependency.)
	printf '%s\n' "$DFOUT" | sed -e '/^[^ 	][^ 	]*$/{
N
s/[ 	]*\n[ 	]*/ /
}' -e "s&^rootfs&${ROOTFS}&" \
	| awk -v ino="$1" 'NR == 1 || ino != "yes" || $5 != "-"'
}
ROOTFS=`readlink -m /dev/root`
emit_df no Disk
echo "[inode]"
emit_df yes Inode
echo "[mount]"
mount
echo "[free]"
free
echo "[ifconfig]"
/sbin/ifconfig 2>/dev/null
echo "[route]"
netstat -rn
echo "[netstat]"
netstat -s
echo "[ports]"
# For some reason, the option for Wide/unTrimmed display of IPs
# changed in netstat versions and no one provided backwards compat,
# so exactly ONE of these should work successfully:
netstat -antuW 2>/dev/null
netstat -antuT 2>/dev/null
echo "[ifstat]"
/sbin/ifconfig 2>/dev/null
# Report mdstat data if it exists
if test -r /proc/mdstat; then echo "[mdstat]"; cat /proc/mdstat; fi
echo "[ps]"
ps -Aww f -o pid,ppid,user,start,state,pri,pcpu,time:12,pmem,rsz:10,vsz:10,cmd
if command -v dpkg >/dev/null 2>&1; then
	echo "[dpkg]"
	COLUMNS=200 dpkg -l | awk '/^..  / { print $1 " " $2 " " $3 }'
fi

# $TOP must be set, the install utility should do that for us if it exists.
if test "$TOP" != ""
then
    if test -x "$TOP"
    then
	echo "[nproc]"
	nproc --all 2>/dev/null
        echo "[top]"
	export CPULOOP ; CPULOOP=1 ;
	$TOP -b -n 1 
	# Some top versions do not finish off the last line of output
	echo ""
    fi
fi

# vmstat
nohup sh -c "vmstat 300 2 1>$XYMONTMP/xymon_vmstat.$MACHINEDOTS.$$ 2>&1; mv $XYMONTMP/xymon_vmstat.$MACHINEDOTS.$$ $XYMONTMP/xymon_vmstat.$MACHINEDOTS" </dev/null >/dev/null 2>&1 &
sleep 5
if test -f $XYMONTMP/xymon_vmstat.$MACHINEDOTS; then echo "[vmstat]"; cat $XYMONTMP/xymon_vmstat.$MACHINEDOTS; rm -f $XYMONTMP/xymon_vmstat.$MACHINEDOTS; fi

exit
