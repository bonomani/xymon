/*
 * test-dsidx.c
 *
 * Golden-output tests for expand_dsidx_in_block() and its helpers from
 * web/showgraph.c. The helpers are static in showgraph.c so this test
 * carries a faithful copy; if they're ever extracted into a header,
 * fold the test into it.
 *
 * Build & run (from web/):
 *   make test-dsidx && ./test-dsidx
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

/* ---- minimal shim mirroring gdef_t (only fields the helpers touch) ---- */
typedef struct { int dscount; char **defs; } gdef_t;

/* ---- helpers copied verbatim from showgraph.c (keep in sync) ---- */
static char *str_replace_all(const char *src, const char *needle, const char *repl)
{
	int nlen = strlen(needle), rlen = strlen(repl);
	const char *p;
	char *out, *q;
	int count = 0;

	for (p = src; (p = strstr(p, needle)) != NULL; p += nlen) count++;
	out = (char *)malloc(strlen(src) + count * (rlen - nlen) + 1);

	q = out;
	while ((p = strstr(src, needle)) != NULL) {
		int prefix = p - src;
		memcpy(q, src, prefix); q += prefix;
		memcpy(q, repl, rlen); q += rlen;
		src = p + nlen;
	}
	strcpy(q, src);
	return out;
}

static int classify_dsidx_line(char *line, char **body, int *start)
{
	*body = line;
	*start = 1;

	if (strncmp(line, "@DSSTART:", 9) == 0) {
		char *p = line + 9;
		int s = atoi(p);
		while (isdigit((int)*p)) p++;
		if ((*p == '@') && (s > 0)) {
			*start = s;
			*body = p + 1;
		}
	}

	if (strstr(*body, "@DSIDX@") || strstr(*body, "@PREVDSIDX@")) {
		if (strstr(*body, "@PREVDSIDX@") && (*start < 2)) *start = 2;
		return 1;
	}
	return 0;
}

static void expand_dsidx_in_block(gdef_t *gd)
{
	int i, newcount = 0, outi = 0;
	char **newdefs;
	char idxstr[16], previdxstr[16];

	if (gd->defs == NULL) return;
	if (gd->dscount <= 0) {
		/* Production code calls xgetenv; the test uses plain getenv since
		 * we don't link libxymon here. Same behavioural intent. */
		char *envn = getenv("SMOKEPINGSAMPLES");
		gd->dscount = (envn ? atoi(envn) : 0);
		if (gd->dscount <= 0) return;
	}

	for (i = 0; gd->defs[i]; i++) {
		char *body; int start;
		if (classify_dsidx_line(gd->defs[i], &body, &start)) {
			int n = gd->dscount - start + 1;
			newcount += (n > 0 ? n : 0);
		} else newcount++;
	}

	newdefs = (char **)calloc(newcount + 1, sizeof(char *));
	for (i = 0; gd->defs[i]; i++) {
		char *body; int start;
		if (classify_dsidx_line(gd->defs[i], &body, &start)) {
			int idx;
			for (idx = start; idx <= gd->dscount; idx++) {
				char *tmp;
				snprintf(idxstr, sizeof(idxstr), "%d", idx);
				snprintf(previdxstr, sizeof(previdxstr), "%d", idx - 1);
				tmp = str_replace_all(body, "@PREVDSIDX@", previdxstr);
				newdefs[outi++] = str_replace_all(tmp, "@DSIDX@", idxstr);
				free(tmp);
			}
		} else newdefs[outi++] = strdup(gd->defs[i]);
		free(gd->defs[i]);
	}
	newdefs[outi] = NULL;
	free(gd->defs);
	gd->defs = newdefs;
}

/* ---- test driver ---- */
static int failures = 0;
static void check_line(const char *label, char *got, const char *want)
{
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL %s: got %s (want %s)\n", label, got, want);
		failures++;
	} else {
		printf("ok   %s: %s\n", label, got);
	}
}

static gdef_t *gd_from(int dscount, ...)
{
	gdef_t *g = calloc(1, sizeof(*g));
	g->dscount = dscount;
	/* Read NULL-terminated argv-style list */
	const char *args[64]; int n = 0;
	va_list ap; va_start(ap, dscount);
	const char *s;
	while ((s = va_arg(ap, const char *)) != NULL) args[n++] = s;
	va_end(ap);
	g->defs = calloc(n + 1, sizeof(char *));
	int i;
	for (i = 0; i < n; i++) g->defs[i] = strdup(args[i]);
	g->defs[n] = NULL;
	return g;
}

static void free_gd(gdef_t *g)
{
	int i;
	for (i = 0; g->defs[i]; i++) free(g->defs[i]);
	free(g->defs);
	free(g);
}

int main(void)
{
	/* Tests assume a known $SMOKEPINGSAMPLES; unset for the cases that
	 * verify the no-env fallback, and setenv per-case for the rest. */
	unsetenv("SMOKEPINGSAMPLES");

	/* dscount=0 + no env -> no-op */
	{
		gdef_t *g = gd_from(0, "DEF:p@DSIDX@=x", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("noop-zero", g->defs[0], "DEF:p@DSIDX@=x");
		free_gd(g);
	}

	/* dscount=0 + $SMOKEPINGSAMPLES=4 -> auto-default to 4 */
	{
		gdef_t *g;
		setenv("SMOKEPINGSAMPLES", "4", 1);
		g = gd_from(0, "DEF:p@DSIDX@=x:p@DSIDX@", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("envdefault-1", g->defs[0], "DEF:p1=x:p1");
		check_line("envdefault-4", g->defs[3], "DEF:p4=x:p4");
		free_gd(g);
		unsetenv("SMOKEPINGSAMPLES");
	}

	/* Explicit DSCOUNT overrides the env default */
	{
		gdef_t *g;
		setenv("SMOKEPINGSAMPLES", "99", 1);
		g = gd_from(3, "DEF:p@DSIDX@=x", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("dscount-overrides-env-1", g->defs[0], "DEF:p1=x");
		check_line("dscount-overrides-env-3", g->defs[2], "DEF:p3=x");
		if (g->defs[3] != NULL) {
			fprintf(stderr, "FAIL dscount-overrides-env-stop: expected NULL at idx 3\n");
			failures++;
		} else printf("ok   dscount-overrides-env-stop\n");
		free_gd(g);
		unsetenv("SMOKEPINGSAMPLES");
	}

	/* basic loop 1..3 */
	{
		gdef_t *g = gd_from(3, "DEF:p@DSIDX@=x:p@DSIDX@", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("basic1", g->defs[0], "DEF:p1=x:p1");
		check_line("basic2", g->defs[1], "DEF:p2=x:p2");
		check_line("basic3", g->defs[2], "DEF:p3=x:p3");
		free_gd(g);
	}

	/* @PREVDSIDX@ -> auto-start at 2 */
	{
		gdef_t *g = gd_from(3, "CDEF:s@DSIDX@=p@DSIDX@,p@PREVDSIDX@,-", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("prev2", g->defs[0], "CDEF:s2=p2,p1,-");
		check_line("prev3", g->defs[1], "CDEF:s3=p3,p2,-");
		free_gd(g);
	}

	/* @DSSTART:N@ prefix is stripped, sets start */
	{
		gdef_t *g = gd_from(3, "@DSSTART:2@STACK:s@DSIDX@#color", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("dsstart-2", g->defs[0], "STACK:s2#color");
		check_line("dsstart-3", g->defs[1], "STACK:s3#color");
		free_gd(g);
	}

	/* line without tokens emits once */
	{
		gdef_t *g = gd_from(3, "TITLE plain", "DEF:p@DSIDX@=x", (char *)NULL);
		expand_dsidx_in_block(g);
		check_line("plain", g->defs[0], "TITLE plain");
		check_line("after-plain-1", g->defs[1], "DEF:p1=x");
		check_line("after-plain-3", g->defs[3], "DEF:p3=x");
		free_gd(g);
	}

	/* full conn-smoke fragment: ensure slice1 stays single and STACK starts at 2 */
	{
		gdef_t *g = gd_from(4,
			"CDEF:slice1=ping1",
			"CDEF:slice@DSIDX@=ping@DSIDX@,ping@PREVDSIDX@,-",
			"AREA:slice1#FFFFFF",
			"@DSSTART:2@STACK:slice@DSIDX@#color",
			(char *)NULL);
		expand_dsidx_in_block(g);
		check_line("smoke-slice1-literal", g->defs[0], "CDEF:slice1=ping1");
		check_line("smoke-slice2-cdef",   g->defs[1], "CDEF:slice2=ping2,ping1,-");
		check_line("smoke-slice4-cdef",   g->defs[3], "CDEF:slice4=ping4,ping3,-");
		check_line("smoke-area",          g->defs[4], "AREA:slice1#FFFFFF");
		check_line("smoke-stack2",        g->defs[5], "STACK:slice2#color");
		check_line("smoke-stack4",        g->defs[7], "STACK:slice4#color");
		free_gd(g);
	}

	/* Second use-case modelled on SmokePing's DNS probe: same template
	 * shape as conn-smoke but for a different RRD/DS family
	 * (dns.<resolver>-smoke.rrd with DSes q1..qN sorted by response
	 * time). Verifies @DSIDX@ infrastructure isn't conn-specific. */
	{
		gdef_t *g = gd_from(5,
			"DEF:q@DSIDX@=dns.r1-smoke.rrd:q@DSIDX@:AVERAGE",
			"CDEF:s@DSIDX@=q@DSIDX@,q@PREVDSIDX@,-",
			"AREA:q1#00000000",
			"@DSSTART:2@AREA:s@DSIDX@#20A050A0:STACK",
			(char *)NULL);
		expand_dsidx_in_block(g);
		/* DEF expands 1..5 -> 5 lines */
		check_line("dns-def-1",     g->defs[0], "DEF:q1=dns.r1-smoke.rrd:q1:AVERAGE");
		check_line("dns-def-5",     g->defs[4], "DEF:q5=dns.r1-smoke.rrd:q5:AVERAGE");
		/* slice CDEF uses @PREVDSIDX@ -> auto-starts at 2, 4 lines */
		check_line("dns-slice-2",   g->defs[5], "CDEF:s2=q2,q1,-");
		check_line("dns-slice-5",   g->defs[8], "CDEF:s5=q5,q4,-");
		/* invisible base */
		check_line("dns-base",      g->defs[9], "AREA:q1#00000000");
		/* STACK uses @DSSTART:2@ -> 4 lines, starts at idx 2 */
		check_line("dns-stack-2",   g->defs[10], "AREA:s2#20A050A0:STACK");
		check_line("dns-stack-5",   g->defs[13], "AREA:s5#20A050A0:STACK");
		free_gd(g);
	}

	/* dscount=1 + @PREVDSIDX@ -> line drops out cleanly */
	{
		gdef_t *g = gd_from(1,
			"DEF:p@DSIDX@=x:p@DSIDX@",
			"CDEF:s@DSIDX@=p@DSIDX@,p@PREVDSIDX@,-",
			(char *)NULL);
		expand_dsidx_in_block(g);
		check_line("n1-def", g->defs[0], "DEF:p1=x:p1");
		if (g->defs[1] != NULL) {
			fprintf(stderr, "FAIL n1-cdef-dropped: expected NULL\n");
			failures++;
		} else {
			printf("ok   n1-cdef-dropped\n");
		}
		free_gd(g);
	}

	if (failures) { fprintf(stderr, "\n%d failure(s)\n", failures); return 1; }
	printf("\nAll tests passed.\n");
	return 0;
}
