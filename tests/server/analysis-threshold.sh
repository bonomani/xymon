#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/server/analysis-threshold.sh
#
# THRESHOLD rules in analysis.cfg: one condition on one named metric of the
# report's batch, judged where the metric is born. Through a harness that
# fills a batch and calls client_config_thresholds() as an analyser does:
#   - a metric is test.name, or test.instance.name with the instance a
#     pattern; a rule without an instance is every instance of the metric;
#   - every rule that addresses a sample is applied and the worst colour is
#     kept; the colour returned to the analyser is the worst that tripped;
#   - a level with a unit of time is seconds; the line keeps it as written;
#   - the line is "&colour test.instance.name is V, above L" or TEXT= with
#     the DS placeholders &N &V &L &U;
#   - a stale sample trips nothing; a rule for another host, test or name
#     does not apply; a rule with no condition is no rule;
#   - --dump-config prints the rule back;
#   - LOAD, UP and CLOCK are keyword rules: the first matching line of each
#     keyword applies to the host, or the built-in default (LOAD 5 10,
#     UP 1h yellow, no CLOCK), and a THRESHOLD never shadows them; LOAD
#     writes the one line of the worst level that trips; UP's "-1" and
#     "never" are no second condition; get_cpu_thresholds() reads the same
#     values back for the analysers that still judge by hand;
#   - MEMPHYS, MEMSWAP and MEMACT are keyword rules the same way, with the
#     built-in defaults 100 101, 50 80, 90 97; their verdict is the row's
#     colour, so they write no line; get_memory_thresholds() reads them back;
#   - DISK and INODE are keyword rules on a filesystem pattern, each level
#     on disk.fs.pct or, written with a U, on disk.fs.free; the first rule
#     naming a filesystem applies to it, IGNORE is a rule with no condition,
#     the built-in defaults are DISK 90 95 and INODE 70 90 on every
#     filesystem; the analyser writes the line, so they write none;
#     get_disk_thresholds() and get_inode_thresholds() read them back;
#   - WHEN metric<op>level scopes any rule on another measurement of the
#     report: the rule applies only while the condition holds; the metric
#     is a bare name, test.name or test.instance.name; a metric the report
#     does not carry leaves the rule in force; a keyword rule scoped out is
#     not the first match; --dump-config prints it back;
#   - a rule's colour is green, yellow, red or clear: blue and purple are
#     xymond's and are refused with a line in the log, the rule keeping
#     its default; an unknown word is refused the same way.

set -euo pipefail
# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/../lib/assert.sh"

ROOT=$(find_root)
here=$(dirname "$0")
CLIENT_CONFIG_C="$ROOT/xymond/client_config.c"
[ -f "$CLIENT_CONFIG_C" ] || skip "xymond/client_config.c not present in this checkout"

CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || skip "no C compiler available (CC=$CC)"
require_gnu_make
[ -f "$ROOT/include/config.h" ] && [ -f "$ROOT/lib/libxymoncomm.a" ] \
	|| skip "tree not built (run make first; the post-build CI suite covers this)"

work=$(mktempdir)

"$XYMON_MAKE" -C "$ROOT/lib" libxymoncomm.a >"$work/libbuild.log" 2>&1 \
	|| { cat "$work/libbuild.log" >&2; fail "cannot refresh libxymoncomm.a"; }

pcre_libs=${PCRELIBS:-}
if [ -z "$pcre_libs" ] && command -v pkg-config >/dev/null 2>&1; then
	pcre_libs=$(pkg-config --libs libpcre2-8 2>/dev/null || true)
fi
[ -n "$pcre_libs" ] || pcre_libs="-lpcre2-8"

harness_cflags=$(xymon_cflags "$ROOT")
harness_ldflags=$(xymon_ldflags "$ROOT")
"$CC" $harness_cflags -iquote "$ROOT/xymond" -o "$work/harness" \
	"$here/analysis-threshold-harness.c" "$CLIENT_CONFIG_C" \
	"$ROOT/lib/libxymoncomm.a" $harness_ldflags $pcre_libs 2>"$work/cc.log" \
	|| { cat "$work/cc.log" >&2; fail "harness does not compile"; }

cat >"$work/hosts.cfg" <<'EOF2'
127.0.0.1 testhost #
127.0.0.2 otherhost #
EOF2

cat >"$work/analysis.cfg" <<'EOF2'
THRESHOLD cpu.load >5 yellow
THRESHOLD cpu.load >10 COLOR=red GROUP=ops
THRESHOLD cpu.uptime <10m yellow "TEXT=Rebooted &V s ago, limit &L (&N)"
THRESHOLD cpu.load >1 red HOST=otherhost
THRESHOLD cpu.x.load >1 red
THRESHOLD disk.pct >=90 red
THRESHOLD disk./home.pct >=50 yellow
THRESHOLD disk.%^/var.free <1000 red
THRESHOLD files.mtimeage >1 red
THRESHOLD files.size clear
THRESHOLD cpu.load >1 red WHEN uptime>1h HOST=testhost
THRESHOLD cpu.load >11 yellow WHEN uptime<1h "TEXT=Load &V inside the boot window"
THRESHOLD cpu.uptime >1 yellow WHEN nosuch>1 "TEXT=a scope on an unmeasured metric applies"
THRESHOLD cpu.load >11 yellow WHEN disk./home.pct>50 "TEXT=a scope by test and instance"
LOAD 1 1 WHEN uptime>1d HOST=testhost
LOAD 2 4 HOST=testhost
LOAD 1 1 HOST=testhost
UP 10m 2d red HOST=testhost
UP 1h -1 HOST=otherhost
CLOCK 30 red HOST=testhost
MEMSWAP 20 40 HOST=testhost
MEMSWAP 90 95 HOST=testhost
MEMCSA 10 20 HOST=testhost
DISK / IGNORE HOST=testhost
DISK /home 50 70 HOST=testhost
DISK /home 10 20 HOST=testhost
DISK %^/var 1000U 500U 1 2 yellow GROUP=storage HOST=testhost
INODE /home 10 20 HOST=testhost
THRESHOLD cpu.uptime >1 purple "TEXT=a refused colour keeps the default"
THRESHOLD cpu.uptime >1 COLOR=blue "TEXT=a refused COLOR= keeps the default"
THRESHOLD cpu.uptime >1 COLOR=mauve "TEXT=an unknown colour keeps the default"
WHEN uptime<1m
THRESHOLD cpu.load >11 yellow "TEXT=a line-level WHEN scopes the rules after it"
EOF2

out=$("$work/harness" "$work/hosts.cfg" "$work/analysis.cfg" \
	cpu - load 12 ok \
	cpu - uptime 300 ok \
	cpu - clockoffset -45 ok \
	disk / pct 95 ok \
	disk /home pct 60 ok \
	disk /var/log free 500.5 ok \
	disk /var/log pct 10 ok \
	files /x mtimeage 100000 stale \
	files /x size 10 ok \
	memory - phys 50 ok \
	memory - swap 50 ok \
	memory - act 95 ok 2>"$work/run.log") \
	|| { cat "$work/run.log" >&2; fail "harness run failed"; }

sample() { printf '%s\n' "$out" | sed -n "s|^sample $1 $2 $3 ||p"; }
test_color() { printf '%s\n' "$out" | sed -n "s|^test $1 ||p"; }

assert_equal "red" "$(test_color cpu)" "the cpu colour returned is not the worst THRESHOLD that tripped"
assert_equal "red" "$(sample cpu - load)" "the load sample is not the worst of its two rules"
assert_contains "&yellow cpu.load is 12, above 5" "$out" "the default line is not in the words of the condition"
assert_contains "&red cpu.load is 12, above 10" "$out" "the second rule on the same sample wrote no line"
assert_contains "&yellow Rebooted 300 s ago, limit 10m (cpu.uptime)" "$out" "TEXT placeholders were not expanded, or the level lost its unit"
assert_equal "red" "$(sample cpu - uptime)" "the uptime sample is not the worst of its UP (red) and THRESHOLD (yellow) rules"
assert_not_contains $'above 1\n' "$out" "a rule for another host, or with an instance the sample lacks, applied"

assert_equal "red" "$(test_color disk)" "the disk colour returned is not the worst THRESHOLD that tripped"
assert_equal "red" "$(sample disk / pct)" "a rule without an instance did not apply to every mount"
assert_equal "yellow" "$(sample disk /home pct)" "a rule with an instance did not apply to it, or the every-mount rule tripped below its level"
assert_equal "red" "$(sample disk /var/log free)" "a pattern instance did not match"
assert_equal "green" "$(sample disk /var/log pct)" "a rule applied to a sample of another name"
assert_contains "&red disk./var/log.free is 500.50, below 1000" "$out" "a non-integer value is not printed to two decimals"

assert_equal "green" "$(test_color files)" "a stale sample tripped, or a rule with no condition did"
assert_equal "green" "$(sample files /x mtimeage)" "a stale age was judged"
assert_equal "green" "$(sample files /x size)" "a THRESHOLD without a condition judged a sample"
assert_equal "green" "$(test_color memory)" "a test with no THRESHOLD rule got a colour"
assert_contains "&red a refused colour keeps the default" "$out" "purple on a rule was not refused in favour of the default"
assert_contains "&red a refused COLOR= keeps the default" "$out" "COLOR=blue on a rule was not refused in favour of the default"
assert_contains "&red an unknown colour keeps the default" "$out" "an unknown colour word was not refused in favour of the default"
assert_contains "a rule cannot be purple" "$(cat "$work/run.log")" "the refused purple was not reported"
assert_contains "a rule cannot be blue" "$(cat "$work/run.log")" "the refused blue was not reported"
assert_contains "'mauve' is not a colour" "$(cat "$work/run.log")" "the unknown colour word was not reported"
assert_contains "a rule in clear adds its line and no alarm" "$(cat "$work/run.log")" "clear on a rule was not noted"
assert_contains "has no condition" "$(cat "$work/run.log")" "a THRESHOLD with no condition was not reported"

keyword_color() { printf '%s\n' "$out" | sed -n "s|^keyword $1 ||p"; }
assert_equal "red" "$(keyword_color cpu)" "the keyword pass did not return the worst colour that tripped"
assert_contains $'&red Load is CRITICAL\n' "$out" "LOAD 2 4 did not write its CRITICAL line on a load of 12"
assert_not_contains "Load is HIGH" "$out" "LOAD wrote both levels' lines where it always wrote the worst"
assert_contains $'&red Machine recently rebooted\n' "$out" "UP 10m 2d red did not trip on an uptime of 300"
assert_contains "&red System clock is -45 seconds off (max 30)" "$out" "CLOCK 30 red did not trip on an offset of -45, or lost its text"
assert_equal "yellow" "$(keyword_color disk)" "DISK /home 50 70 on 60% and DISK %^/var 1000U 500U on 500.5 free did not give yellow, or the IGNORE rule on / did not shadow the default on 95%"
assert_not_contains $'keyword disk yellow\n&' "$out" "a DISK rule wrote a line where the analyser writes it"
assert_contains "disk testhost / 90% 95% ignored file" "$out" "DISK / IGNORE is not read back as ignored with the default levels"
assert_contains "disk testhost /home 50% 70% file" "$out" "the first DISK rule naming /home is not the one read back"
assert_contains "disk testhost /var/log 1000U 500U group=storage file" "$out" "levels in units free, or the group, are not read back"
assert_contains "disk testhost /other 90% 95% default" "$out" "a filesystem no DISK rule names did not get the built-in default"
assert_contains "disk otherhost /home 90% 95% default" "$out" "another host's DISK rule applied"
assert_contains "inode testhost /home 10% 20% file" "$out" "INODE /home is not read back"
assert_contains "inode testhost / 70% 90% default" "$out" "a DISK rule was read as an INODE rule, or the INODE default is wrong"
assert_contains "DISK: IGNORE disk./" "$out" "--dump-config does not print an IGNORE rule"
assert_not_contains "; count 0 0 " "$out" "--dump-config prints a count on a rule that has none"
assert_contains "DISK: THRESHOLD disk.%^/var.free <=500 red; THRESHOLD disk.%^/var.free <=1000 yellow; count 1 2 yellow" "$out" "--dump-config does not print a DISK line with units and a count as what it compiled to"
assert_contains "cpu testhost load 2.0 4.0 up 600 172800 red clock 30 red" "$out" "get_cpu_thresholds does not read the host's first LOAD, UP and CLOCK back (LOAD 1 1 must be shadowed)"
assert_contains "cpu otherhost load 5.0 10.0 up 3600 -1 yellow clock -1 yellow" "$out" "a host without LOAD or CLOCK did not get the built-in default, or UP 1h -1 kept a second condition"
assert_equal "red" "$(keyword_color memory)" "MEMSWAP 20 40 did not colour a swap of 50 red, or the second MEMSWAP shadowed the first"
assert_contains $'keyword memory red\ntest memory green' "$out" "a memory keyword wrote a line where its verdict is the row's colour"
assert_equal "red" "$(sample memory - swap)" "the swap sample does not carry the MEMSWAP verdict"
assert_equal "yellow" "$(sample memory - act)" "the built-in MEMACT 90 97 did not colour an actual of 95 yellow"
assert_equal "green" "$(sample memory - phys)" "the built-in MEMPHYS 100 101 coloured a physical of 50"
assert_contains "mem testhost phys 100 101 swap 20 40 act 90 97" "$out" "get_memory_thresholds does not read the host's first MEMSWAP back with the defaults for the rest, or a MEMCSA rule was read as a memory keyword"
assert_contains "mem otherhost phys 100 101 swap 50 80 act 90 97" "$out" "a host without memory keywords did not get the built-in defaults"
assert_contains "MEMSWAP: THRESHOLD memory.swap >40 red; THRESHOLD memory.swap >20 yellow" "$out" "--dump-config does not print a MEMSWAP line as what it compiled to"
assert_contains "MEMCSA 10 20" "$out" "--dump-config does not print a z/OS memory keyword under its own name"
assert_contains "LOAD: THRESHOLD cpu.load >4 red; THRESHOLD cpu.load >2 yellow" "$out" "--dump-config does not print a LOAD line as what it compiled to"
assert_contains "UP: THRESHOLD *.uptime <3600 yellow" "$out" "--dump-config does not print UP 1h -1 as one condition on the uptime of any test"

assert_contains "&yellow Load 12 inside the boot window" "$out" "WHEN uptime<1h did not apply with an uptime of 300"
assert_contains "a scope on an unmeasured metric applies" "$out" "a WHEN on a metric the report does not carry switched the rule off"
assert_contains "a scope by test and instance" "$out" "WHEN disk./home.pct>50 did not find the sample by test and instance"
assert_not_contains "&yellow a line-level WHEN scopes" "$out" "a WHEN alone on a line did not scope the rules after it"
assert_contains "THRESHOLD cpu.load >1 red WHEN uptime>1h HOST=testhost" "$out" "--dump-config does not print WHEN back"
assert_contains "THRESHOLD disk./home.pct >=50 yellow" "$out" "--dump-config does not print the rule back"
assert_contains "THRESHOLD cpu.uptime <10m yellow" "$out" "--dump-config lost the level as written"

pass "THRESHOLD rules judge a test's samples by name and instance, worst colour kept; LOAD, UP, CLOCK, the memory keywords, DISK and INODE are keyword rules with first match and built-in defaults; WHEN scopes a rule on another measurement"
