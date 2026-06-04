#!/usr/bin/env bash
#
# Regression test for lib/rrd_api_compat.h
#
# RRDtool changed the argv parameter of its public API from "char **" to
# "const char **". lib/rrd_api_compat.h hides that behind xymon_rrd_argv_item_t
# and the xymon_rrd_* wrappers, selected by RRD_CONST_ARGS (probed by
# build/rrd.sh).
#
# This test compiles a small probe that includes the header and calls every
# wrapper, against a mocked <rrd.h> in BOTH the legacy ("char **") and the
# modern ("const char **") forms -- with the matching RRD_CONST_ARGS value.
# It needs no real librrd, so it runs anywhere with a C compiler.
#
set -euo pipefail

CC="${CC:-cc}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

write_mock_rrd_h() {            # $1 = legacy | const
	local argv="char **"
	[ "$1" = "const" ] && argv="const char **"
	cat >"$TMPDIR/rrd.h" <<EOF
#ifndef RRD_H
#define RRD_H
#include <time.h>
typedef double rrd_value_t;
int rrd_update(int, $argv);
int rrd_create(int, $argv);
int rrd_fetch(int, $argv, time_t *, time_t *, unsigned long *,
              unsigned long *, char ***, rrd_value_t **);
int rrd_graph(int, $argv, char ***, int *, int *, void *, double *, double *);
#endif
EOF
}

cat >"$TMPDIR/probe.c" <<'EOF'
#include "rrd_api_compat.h"

int main(void)
{
	xymon_rrd_argv_item_t argv[2] = { "x", 0 };
	char **calcpr = 0, **dsnames = 0;
	rrd_value_t *data = 0;
	int xsize = 0, ysize = 0;
	double ymin = 0, ymax = 0;
	time_t start = 0, end = 0;
	unsigned long step = 0, dscount = 0;

	(void)xymon_rrd_update(1, argv);
	(void)xymon_rrd_create(1, argv);
	(void)xymon_rrd_fetch(1, argv, &start, &end, &step, &dscount,
			      &dsnames, &data);
	(void)xymon_rrd_graph(1, argv, &calcpr, &xsize, &ysize, 0,
			      &ymin, &ymax);
	return 0;
}
EOF

check() {                      # $1 = legacy|const   $2 = RRD_CONST_ARGS value
	write_mock_rrd_h "$1"
	printf '  %-7s API (RRD_CONST_ARGS=%s) ... ' "$1" "$2"
	"$CC" -std=c99 -Wall -Wextra -Werror "-DRRD_CONST_ARGS=$2" \
		-I"$TMPDIR" -I"$ROOT_DIR/lib" \
		-c "$TMPDIR/probe.c" -o "$TMPDIR/probe.o"
	echo "ok"
}

echo "Checking lib/rrd_api_compat.h against both RRDtool argv APIs:"
check legacy 0
check const  1
echo "PASS: rrd_api_compat.h compiles cleanly for both argv API forms."
