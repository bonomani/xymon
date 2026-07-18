#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/rrdreconcile.sh
#
# The schema reconciliation tool: RRD files freeze their creation-time
# schema, rrdreconcile compares them against the CURRENT declarations -
# archive CFs from matching graphs.cfg gdefs, heartbeats from the fileset
# index's h= records - and repairs divergence with "rrdtool tune".
# Dry-run by default; --apply executes; added archives fill forward only.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

require_bin RRDRECONCILE "xymond/rrdreconcile"
command -v rrdtool >/dev/null 2>&1 || skip "rrdtool CLI not available"

work=$(mktempdir)
mkdir -p "$work/rrd/testhost" "$work/etc"
now=$(date +%s)

# A file created "before the declarations changed": AVERAGE-only archives,
# heartbeat 600 - while the index records a declared heartbeat of 1200 and
# a graphs.cfg gdef now reads MAX of it.
rrdtool create "$work/rrd/testhost/lat.api.rrd" --start $((now-600)) --step 300 \
	DS:val:GAUGE:600:0:U RRA:AVERAGE:0.5:1:100 RRA:AVERAGE:0.5:12:50
cat >"$work/rrd/testhost/.fileset-index" <<EOF
# xymon fileset index v1
lat.api.rrd $now u=val:ms h=val:1200 d=val
stock.x.rrd $now h=val:600
EOF
# A file already matching its declaration: untouched.
rrdtool create "$work/rrd/testhost/stock.x.rrd" --start $((now-600)) --step 300 \
	DS:val:GAUGE:600:0:U RRA:AVERAGE:0.5:1:100
cat >"$work/graphs.cfg" <<'EOF'
[lat]
	FNPATTERN ^lat\..*\.rrd$
	TITLE Latency
	YAXIS ms
	DEF:v@RRDIDX@=@RRDFN@:val:MAX
	LINE1:v@RRDIDX@#00CCCC:@RRDPARAM@
EOF

# Dry run: reports the divergence, plans BOTH repairs, touches nothing.
out=$("$RRDRECONCILE" --rrddir="$work/rrd" --config="$work/graphs.cfg" 2>&1)
echo "$out" | grep -q "would run:.*--heartbeat val:1200" \
	|| fail "heartbeat divergence not planned: $out"
echo "$out" | grep -q "would run:.*RRA:MAX:0.5:1:100" \
	|| fail "missing-CF archive not planned (per-AVERAGE clone): $out"
echo "$out" | grep -q "RRA:MAX:0.5:12:50" \
	|| fail "second AVERAGE geometry not cloned: $out"
echo "$out" | grep -q "2 files scanned, 1 diverged" \
	|| fail "matching file not left alone in the summary: $out"
rrdtool info "$work/rrd/testhost/lat.api.rrd" | grep -q 'minimal_heartbeat = 600' \
	|| fail "dry run modified the file"

# Apply: the file now carries the declared heartbeat and the MAX archives.
"$RRDRECONCILE" --rrddir="$work/rrd" --config="$work/graphs.cfg" --apply >/dev/null 2>&1 \
	|| fail "--apply exited nonzero"
info=$(rrdtool info "$work/rrd/testhost/lat.api.rrd")
echo "$info" | grep -q 'minimal_heartbeat = 1200' || fail "heartbeat not reconciled: $info"
[ "$(echo "$info" | grep -c 'cf = "MAX"')" = 2 ] || fail "MAX archives not added: $info"
# Reconciled state is stable: a second pass finds nothing to do.
"$RRDRECONCILE" --rrddir="$work/rrd" --config="$work/graphs.cfg" 2>&1 \
	| grep -q "2 files scanned, 0 diverged" || fail "reconciliation did not converge"
# The untouched file really is untouched.
rrdtool info "$work/rrd/testhost/stock.x.rrd" | grep -q 'minimal_heartbeat = 600' \
	|| fail "conforming file was modified"

echo "OK $(basename "$0")"
