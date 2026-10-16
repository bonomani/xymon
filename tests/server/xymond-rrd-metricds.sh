#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/xymond-rrd-metricds.sh
#
# A METRICS block may leave out its DS: line: its datasets then come from
# the METRICDS: lines of rrddefinitions.cfg - the block's own section, else
# its column's, else the default one, whichever has them first. Feed real
# status messages to the built xymond_rrd and check the files it creates:
# the shipped default, each override, a block's own DS: line winning, no
# source at all, and the two things that must not change - a built-in
# handler's files, and the archives of a section holding only METRICDS:.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin XYMOND_RRD "xymond/xymond_rrd"
command -v rrdtool >/dev/null 2>&1 || skip "rrdtool not installed (needed to inspect the files)"

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktempdir)
mkdir -p "$work/etc"

feed() {	# feed <column> <body> -- send one status; the writer's log goes to $work/log
	local ts; ts=$(date +%s)
	rm -rf "$work/rrd"; mkdir -p "$work/rrd" "$work/tmp"
	{
		printf '@@status#1|%s|127.0.0.1|origin|testhost|%s|%s|green||green|%s|0||0||%s|0|linux|/\n' \
			"$ts" "$1" $((ts+1800)) "$ts" "$ts"
		printf '%s\n@@\n' "$2"
	} | env XYMONHOME="$work" XYMONTMP="$work/tmp" TEST2RRD="ftp=tcp" \
		"$XYMOND_RRD" --rrddir="$work/rrd" --no-cache >"$work/log" 2>&1
}
info() { rrdtool info "$work/rrd/testhost/$1"; }
dsnames() { info "$1" | sed -n 's/^ds\[\([^]]*\)\]\.type = .*/\1/p' | tr '\n' ' '; }

nods='<!--XYMON METRICS: temp
cpu 42
-->
status text'

# The shipped file, as installed.
sed "s#@XYMONHOME@#$work#g" "$here/../../xymond/etcfiles/rrddefinitions.cfg.DIST" > "$work/etc/rrddefinitions.cfg"

feed temp "$nods"
assert_equal "value " "$(dsnames temp.cpu.rrd)" \
	"with the shipped rrddefinitions.cfg, a block without DS: stores one dataset named value"
assert_contains 'ds[value].type = "GAUGE"' "$(info temp.cpu.rrd)" "the shipped default dataset is a GAUGE"
assert_contains 'ds[value].last_ds = "42"' "$(info temp.cpu.rrd)" "the value on the instance line is stored"

feed temp '<!--XYMON METRICS: temp
DS:celsius:GAUGE:600:U:U
cpu 42
-->
status text'
assert_equal "celsius " "$(dsnames temp.cpu.rrd)" "a block's own DS: line wins over METRICDS:"

# The block's own section, holding only METRICDS: - so it also checks that
# such a section still gets the default archives.
cat >"$work/etc/rrddefinitions.cfg" <<'CFG'
[temp]
	METRICDS:value:GAUGE:600:-50:150
[]
	METRICDS:value:GAUGE:600:U:U
	RRA:AVERAGE:0.5:1:576
CFG
feed temp "$nods"
assert_contains 'ds[value].min = -5.0000000000e+01' "$(info temp.cpu.rrd)" "the block's own section overrides the default"
assert_contains 'rra[0].rows = 576' "$(info temp.cpu.rrd)" "a section with only METRICDS: lines takes the default archives"

# The column's section, when the block has none.
cat >"$work/etc/rrddefinitions.cfg" <<'CFG'
[sensors]
	METRICDS:reading:GAUGE:600:U:U
[]
	METRICDS:value:GAUGE:600:U:U
	RRA:AVERAGE:0.5:1:576
CFG
feed sensors "$nods"
assert_equal "reading " "$(dsnames temp.cpu.rrd)" "a block without its own section takes its column's METRICDS:"

# No METRICDS: anywhere: nothing is stored, and the log says why.
printf '[]\n\tRRA:AVERAGE:0.5:1:576\n' > "$work/etc/rrddefinitions.cfg"
feed temp "$nods"
[ ! -e "$work/rrd/testhost/temp.cpu.rrd" ] || fail "with no METRICDS: line, a block without DS: must not create a file"
assert_contains "METRICS block 'temp' has no DS: line" "$(cat "$work/log")" "the log says why the block was not stored"

# A built-in handler never sees METRICDS: lines.
printf '[ftp]\n\tMETRICDS:extra:GAUGE:600:U:U\n\tRRA:AVERAGE:0.5:1:576\n' > "$work/etc/rrddefinitions.cfg"
feed ftp 'ftp ok
Seconds: 0.05'
assert_equal "sec " "$(dsnames tcp.ftp.rrd)" "a built-in handler's file keeps its own datasets only"

pass "a METRICS block without DS: takes its datasets from rrddefinitions.cfg"
