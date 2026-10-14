/*
 * tests/web/aggregate-tokens-harness.c
 *
 * Golden-output tests for the graphs.cfg aggregate tokens
 * (@AVG:/@SUM:/@MIN:/@MAX:/@COUNT:/@MEDIAN:/@STDEV:/@PERCENT:/@Pxx:),
 * across files and over the datasets of one file. Run by
 * tests/web/aggregate-tokens.sh.
 *
 * The helpers are static and depend on file-scope globals (rrddbcount,
 * firstidx, lastidx) and on libxymon's strbuffer API. This test #includes
 * web/aggregate-tokens.inc.c, the same source showgraph.c compiles, so
 * parser and test cannot drift. A minimal strbuffer shim stands in for
 * libxymon.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ---- minimal strbuffer shim (in-test only) ---- */
typedef struct { char *s; int len; int cap; } strbuffer_t;
static strbuffer_t *newstrbuffer(int cap) {
	strbuffer_t *b = calloc(1, sizeof(*b));
	b->cap = cap < 64 ? 64 : cap;
	b->s = calloc(1, b->cap);
	return b;
}
static void buf_grow(strbuffer_t *b, int extra) {
	while (b->len + extra + 1 > b->cap) { b->cap *= 2; b->s = realloc(b->s, b->cap); }
}
static void addtobuffer(strbuffer_t *b, char *t) {
	int n = strlen(t); buf_grow(b, n); memcpy(b->s + b->len, t, n); b->len += n; b->s[b->len] = 0;
}
static void addtobufferraw(strbuffer_t *b, char *t, int n) {
	buf_grow(b, n); memcpy(b->s + b->len, t, n); b->len += n; b->s[b->len] = 0;
}
#define STRBUF(x) ((x)->s)

/* ---- file-scope context the helpers read ---- */
static int rrddbcount = 0;
static int firstidx = -1;
static int lastidx = 0;

/* Helpers under test come from the same source web/showgraph.c uses.
 * Including the .inc.c (rather than maintaining a copy) keeps the test
 * locked to the production parser; any future fix in
 * aggregate-tokens.inc.c is automatically reflected here. */
#include "aggregate-tokens.inc.c"

/* Drive expansion of a single token; returns malloc'd RPN string. */
static char *expand_one(char *tpl) {
	char *op, *name; int oplen, toklen;
	strbuffer_t *r = newstrbuffer(128);
	if (!is_aggregate_token(tpl, &op, &name, &oplen, &toklen)) {
		free(r->s); free(r); return strdup("(not-aggregate)");
	}
	add_aggregate_rpn(r, op, name, toklen - oplen - 1);
	char *out = strdup(STRBUF(r));
	free(r->s); free(r);
	return out;
}

/* ---- test driver ---- */
/* What a percentile over t0..t2 expands to: sort, count the known
 * values, fetch the nearest rank among them, drop the sorted set. */
static char *pct_rpn3(const char *pct) {
	static char buf[512];
	snprintf(buf, sizeof(buf), "t0,t1,t2,3,SORT,t0,UN,0,1,IF,t1,UN,0,1,IF,+,t2,UN,0,1,IF,+,"
		"DUP,%s,*,100,/,0.5,+,FLOOR,1,MAX,-,1,+,1,MAX,INDEX,EXC,POP,EXC,POP,EXC,POP", pct);
	return buf;
}
static int failures = 0;
static void check(const char *label, char *tpl, int n, int first, int last, const char *want) {
	rrddbcount = n; firstidx = first; lastidx = last;
	aggregate_dscount = 0;
	char *got = expand_one(tpl);
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL %s: tpl=%s n=%d -> %s (want %s)\n", label, tpl, n, got, want);
		failures++;
	} else {
		printf("ok   %s: %s -> %s\n", label, tpl, got);
	}
	free(got);
}

/* Within-file driver: fams lists the names @DSIDX@ lines make, as
 * dsidx_families() builds it; dscount is the file's dataset count and
 * nfiles the matched files, which a name outside fams walks instead. */
static void check_ds(const char *label, char *tpl, char *fams, int dscount, int nfiles, const char *want) {
	rrddbcount = nfiles; firstidx = -1; lastidx = 0;
	aggregate_dscount = dscount; aggregate_dsfams = fams;
	char *got = expand_one(tpl);
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL %s: tpl=%s dscount=%d -> %s (want %s)\n", label, tpl, dscount, got, want);
		failures++;
	} else {
		printf("ok   %s: %s -> %s\n", label, tpl, got);
	}
	free(got);
	aggregate_dscount = 0; aggregate_dsfams = NULL;
}

int main(int argc, char **argv) {
	/* "harness TOKEN N" prints TOKEN's expansion over N files, or over
	 * N datasets for the "dk" family (dk1..dkN), for
	 * tests/web/aggregate-tokens-values.sh. */
	if (argc == 3) {
		char *out;

		aggregate_dsfams = ",dk:1,";
		rrddbcount = aggregate_dscount = atoi(argv[2]);
		firstidx = -1;
		out = expand_one(argv[1]);
		printf("%s\n", out);
		free(out);
		return 0;
	}

	/* n = 0 -> UNKN, COUNT -> 0 */
	check("avg-n0", "@AVG:t@", 0, -1, 0, "UNKN");
	check("sum-n0", "@SUM:t@", 0, -1, 0, "UNKN");
	check("count-n0", "@COUNT:t@", 0, -1, 0, "0");
	check("p95-n0", "@P95:t@", 0, -1, 0, "UNKN");

	/* n = 1 */
	check("avg-n1", "@AVG:t@", 1, -1, 0, "t0,1,/");
	check("sum-n1", "@SUM:t@", 1, -1, 0, "t0");
	check("min-n1", "@MIN:t@", 1, -1, 0, "t0");
	check("median-n1", "@MEDIAN:t@", 1, -1, 0, "t0,1,MEDIAN");

	/* n = 3 */
	check("sum-n3", "@SUM:t@", 3, -1, 0, "t0,t1,+,t2,+");
	check("avg-n3", "@AVG:t@", 3, -1, 0, "t0,t1,+,t2,+,3,/");
	check("min-n3", "@MIN:t@", 3, -1, 0, "t0,t1,MIN,t2,MIN");
	check("max-n3", "@MAX:t@", 3, -1, 0, "t0,t1,MAX,t2,MAX");
	check("sumnan-n3", "@SUMNAN:t@", 3, -1, 0, "t0,t1,ADDNAN,t2,ADDNAN");
	check("minnan-n3", "@MINNAN:t@", 3, -1, 0, "t0,t1,MINNAN,t2,MINNAN");
	check("avgnan-n3", "@AVGNAN:t@", 3, -1, 0, "t0,t1,t2,3,AVG");
	check("median-n3", "@MEDIAN:t@", 3, -1, 0, "t0,t1,t2,3,MEDIAN");
	check("stdev-n3", "@STDEV:t@", 3, -1, 0, "t0,t1,t2,3,STDEV");
	check("count-n3", "@COUNT:t@", 3, -1, 0, "t0,UN,0,1,IF,t1,UN,0,1,IF,+,t2,UN,0,1,IF,+");
	check("p95-n3", "@P95:t@", 3, -1, 0, pct_rpn3("95"));
	check("percent-n3", "@PERCENT:t:90@", 3, -1, 0, pct_rpn3("90"));
	check("p99.9-n3", "@P99.9:t@", 3, -1, 0, pct_rpn3("99.9"));

	/* firstidx/lastidx slicing: only idx 1..2 selected of 4 */
	check("avg-slice", "@AVG:t@", 4, 1, 2, "t1,t2,+,2,/");
	check("count-slice", "@COUNT:t@", 4, 1, 2, "t1,UN,0,1,IF,t2,UN,0,1,IF,+");

	/* Slicing edge cases */
	check("avg-slice-equal", "@AVG:t@", 4, 2, 2, "t2,1,/");                  /* single element */
	check("count-slice-oor", "@COUNT:t@", 4, 10, 20, "0");                   /* fully out of range */
	check("avg-slice-rev",  "@AVG:t@", 4, 3, 1, "UNKN");                     /* lastidx < firstidx -> no selection */

	/* n = 5 and n = 1 STDEV (output well-defined even though stddev of 1 sample is meaningless) */
	check("stdev-n0", "@STDEV:t@", 0, -1, 0, "UNKN");
	check("stdev-n1", "@STDEV:t@", 1, -1, 0, "t0,1,STDEV");
	check("sum-n5",   "@SUM:t@",   5, -1, 4, "t0,t1,+,t2,+,t3,+,t4,+");

	/* @PERCENT:name:pct@ pct validation -- prior version emitted garbage RPN */
	check("percent-bad-pct",     "@PERCENT:t:abc@", 3, -1, 2, "t0,UNKN,+");
	check("percent-extra-colon", "@PERCENT:t:95:x@", 3, -1, 2, "t0,UNKN,+");
	check("percent-empty-pct",   "@PERCENT:t:@", 3, -1, 2, "t0,UNKN,+");
	check("percent-float-pct",   "@PERCENT:t:95.5@", 3, -1, 2, pct_rpn3("95.5"));

	/* Malformed/rejected aggregate tokens -- parser should return false
	 * so the caller treats them as literal text. expand_one signals this
	 * via the "(not-aggregate)" sentinel. */
	check("avg-empty-operand", "@AVG:@",        3, -1, 2, "(not-aggregate)");
	check("avg-no-terminator", "@AVG:tnoterm",  3, -1, 2, "(not-aggregate)");
	check("p-dot-dot",         "@P95.5.5:t@",   3, -1, 2, "(not-aggregate)");
	check("p-leading-dot",     "@P.5:t@",       3, -1, 2, "(not-aggregate)");
	check("p-no-digit",        "@P:t@",         3, -1, 2, "(not-aggregate)");
	check("p-trailing-dot",    "@P90.:t@",      3, -1, 2, pct_rpn3("90.")); /* trailing dot accepted today; flag if rejecting later */

	/* pct outside 0..100 fails the whole rrdtool graph, so it is an unknown
	 * that still names a variable (a bare UNKN fails the graph too);
	 * below 50/n the rank rounds to 0, and the emitted RPN raises it to
	 * 1, the smallest value, so the pct itself is passed through. */
	check("p-over-100",        "@P150:t@",          3, -1, 2, "t0,UNKN,+");
	check("percent-over-100",  "@PERCENT:t:100.5@", 3, -1, 2, "t0,UNKN,+");
	check("p100-n3",           "@P100:t@",          3, -1, 2, pct_rpn3("100"));
	check("p10-n3-smallest",   "@P10:t@",           3, -1, 2, pct_rpn3("10"));
	check("p0-n3-smallest",    "@P0:t@",            3, -1, 2, pct_rpn3("0"));
	check("p17-n3-kept",       "@P17:t@",           3, -1, 2, pct_rpn3("17"));

	/* Name delimiter check: whitespace / commas inside the operand
	 * would otherwise let the parser swallow downstream @TOKEN@ markers. */
	check("avg-space-in-name", "@AVG:foo bar@",   3, -1, 2, "(not-aggregate)");
	check("avg-tab-in-name",   "@AVG:foo\tbar@", 3, -1, 2, "(not-aggregate)");
	check("avg-comma-in-name", "@AVG:foo,bar@",   3, -1, 2, "(not-aggregate)");
	check("avg-dot-in-name",   "@AVG:foo.bar@",   3, -1, 2, "foo.bar0,foo.bar1,+,foo.bar2,+,3,/"); /* dots allowed (legal in some uses) */

	/* A name a @DSIDX@ line makes walks that file's datasets, from the
	 * index its line starts at, with every operator. */
	check_ds("median-ds-n3",   "@MEDIAN:ping@", ",ping:1,", 3, 0, "ping1,ping2,ping3,3,MEDIAN");
	check_ds("median-ds-n1",   "@MEDIAN:ping@", ",ping:1,", 1, 0, "ping1,1,MEDIAN");
	check_ds("median-ds-n20",  "@MEDIAN:p@",    ",p:1,",    20, 0,
	         "p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,20,MEDIAN");
	check_ds("median-ds-n0",   "@MEDIAN:ping@", ",ping:1,", 0, 0, "UNKN");
	check_ds("maxnan-ds",      "@MAXNAN:ping@", ",ping:1,", 3, 0, "ping1,ping2,MAXNAN,ping3,MAXNAN");
	check_ds("count-ds",       "@COUNT:ping@",  ",ping:1,", 2, 0, "ping1,UN,0,1,IF,ping2,UN,0,1,IF,+");
	check_ds("count-ds-n0",    "@COUNT:ping@",  ",ping:1,", 0, 0, "0");
	check_ds("sum-ds-start2",  "@SUM:s@",       ",ping:1,s:2,", 4, 0, "s2,s3,+,s4,+");
	/* Any other name still walks the matched files, a prefix or an
	 * extension of a family name included. */
	check_ds("files-not-fam",  "@SUM:t@",       ",ping:1,", 3, 2, "t0,t1,+");
	check_ds("files-prefix",   "@SUM:pin@",     ",ping:1,", 3, 2, "pin0,pin1,+");
	check_ds("files-extended", "@SUM:pingx@",   ",ping:1,", 3, 2, "pingx0,pingx1,+");
	/* A family named per file ("p@RRDIDX@x") matches any file index:
	 * "p2x" is the datasets of file 2. Without the digits it is not. */
	check_ds("fam-per-file",   "@MEDIAN:p2x@",  ",p@RRDIDX@x:1,", 2, 3, "p2x1,p2x2,2,MEDIAN");
	check_ds("fam-per-file-10","@MAX:p10x@",    ",p@RRDIDX@x:1,", 2, 3, "p10x1,p10x2,MAX");
	check_ds("fam-no-index",   "@SUM:px@",      ",p@RRDIDX@x:1,", 2, 2, "px0,px1,+");
	/* The separate within-file token is gone: @MEDIAN: covers it. */
	check_ds("no-dsmedian",    "@DSMEDIAN:ping@", ",ping:1,", 3, 0, "(not-aggregate)");

	if (failures) { fprintf(stderr, "\n%d failure(s)\n", failures); return 1; }
	printf("\nAll tests passed.\n");
	return 0;
}
