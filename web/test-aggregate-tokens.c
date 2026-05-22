/*
 * test-aggregate-tokens.c
 *
 * Golden-output tests for the @AVG:/@SUM:/@MIN:/@MAX:/@COUNT:/@MEDIAN:/@STDEV:/
 * @PERCENT:/@Pxx: aggregate token expansion logic added to web/showgraph.c.
 *
 * Build & run (from web/):
 *   make test-aggregate-tokens && ./test-aggregate-tokens
 *
 * NOTE: The aggregate helpers in showgraph.c are static and depend on
 * file-scope globals (rrddbcount, firstidx, lastidx) and on libxymon's
 * strbuffer API. This test deliberately duplicates the helpers (with a
 * minimal in-test strbuffer shim) to avoid pulling in libxymon and to
 * keep the test runnable in isolation. If the helpers are ever extracted
 * into their own translation unit, fold this test into that header.
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

/* ---- helpers copied verbatim from web/showgraph.c (keep in sync) ---- */
static int selected_rrdidx(int idx) {
	return ((firstidx == -1) || ((idx >= firstidx) && (idx <= lastidx)));
}

static int is_aggregate_token(char *inp, char **op, char **name, int *oplen, int *toklen) {
	char *p;
	if      (strncmp(inp,"@AVG:",5)==0)    { *op="AVG";    *oplen=5; }
	else if (strncmp(inp,"@SUM:",5)==0)    { *op="SUM";    *oplen=5; }
	else if (strncmp(inp,"@MIN:",5)==0)    { *op="MIN";    *oplen=5; }
	else if (strncmp(inp,"@MAX:",5)==0)    { *op="MAX";    *oplen=5; }
	else if (strncmp(inp,"@AVGNAN:",8)==0) { *op="AVGNAN"; *oplen=8; }
	else if (strncmp(inp,"@SUMNAN:",8)==0) { *op="SUMNAN"; *oplen=8; }
	else if (strncmp(inp,"@MINNAN:",8)==0) { *op="MINNAN"; *oplen=8; }
	else if (strncmp(inp,"@MAXNAN:",8)==0) { *op="MAXNAN"; *oplen=8; }
	else if (strncmp(inp,"@COUNT:",7)==0)  { *op="COUNT";  *oplen=7; }
	else if (strncmp(inp,"@MEDIAN:",8)==0) { *op="MEDIAN"; *oplen=8; }
	else if (strncmp(inp,"@STDEV:",7)==0)  { *op="STDEV";  *oplen=7; }
	else if (strncmp(inp,"@PERCENT:",9)==0){ *op="PERCENT";*oplen=9; }
	else if ((inp[0]=='@')&&(inp[1]=='P')&&isdigit((int)inp[2])) {
		p = inp + 3;
		while (isdigit((int)*p) || (*p=='.')) p++;
		if (*p != ':') return 0;
		*op = inp + 2;
		*oplen = (p - inp) + 1;
	}
	else return 0;
	*name = inp + *oplen;
	p = strchr(*name, '@');
	if (!p) return 0;
	*toklen = (p - inp) + 1;
	return 1;
}

static void add_aggregate_var(strbuffer_t *r, char *name, int nlen, int idx) {
	char n[20];
	addtobufferraw(r, name, nlen);
	snprintf(n, sizeof(n), "%d", idx);
	addtobuffer(r, n);
}
static void add_aggregate_varlist(strbuffer_t *r, char *name, int nlen, int *count) {
	int i; *count = 0;
	for (i = 0; i < rrddbcount; i++) {
		if (!selected_rrdidx(i)) continue;
		if (*count > 0) addtobuffer(r, ",");
		add_aggregate_var(r, name, nlen, i);
		(*count)++;
	}
}
static void add_aggregate_count_rpn(strbuffer_t *r, char *name, int nlen) {
	int i, n = 0;
	for (i = 0; i < rrddbcount; i++) {
		if (!selected_rrdidx(i)) continue;
		if (n > 0) addtobuffer(r, ",");
		add_aggregate_var(r, name, nlen, i);
		addtobuffer(r, ",UN,0,1,IF");
		if (n > 0) addtobuffer(r, ",+");
		n++;
	}
	if (n == 0) addtobuffer(r, "0");
}
static void add_aggregate_rpn(strbuffer_t *r, char *op, char *name, int namelen) {
	int i, n = 0;
	char *pct = NULL; int pctlen = 0;
	int ispercent = ((strcmp(op,"PERCENT")==0) || isdigit((int)op[0]));
	if (ispercent) {
		char *p;
		if (isdigit((int)op[0])) { pct = op; p = op; while (isdigit((int)*p)||(*p=='.')) p++; pctlen = p - op; }
		else if (namelen > 0) {
			p = memchr(name, ':', namelen);
			if (p) { pct = p + 1; pctlen = namelen - (p - name) - 1; namelen = p - name; }
		}
		if (!pct || !pctlen || !namelen) { addtobuffer(r, "UNKN"); return; }
	}
	if (strcmp(op,"COUNT")==0) { add_aggregate_count_rpn(r, name, namelen); return; }
	if ((strcmp(op,"AVGNAN")==0)||(strcmp(op,"MEDIAN")==0)||(strcmp(op,"STDEV")==0)||ispercent) {
		add_aggregate_varlist(r, name, namelen, &n);
		if (n == 0) { addtobuffer(r, "UNKN"); return; }
		if (ispercent) {
			char nb[20]; addtobuffer(r, ","); addtobufferraw(r, pct, pctlen);
			snprintf(nb, sizeof(nb), ",%d,PERCENT", n); addtobuffer(r, nb);
		} else {
			char nb[20]; snprintf(nb, sizeof(nb), ",%d,%s", n, (strcmp(op,"AVGNAN")==0)?"AVG":op); addtobuffer(r, nb);
		}
		return;
	}
	for (i = 0; i < rrddbcount; i++) {
		if (!selected_rrdidx(i)) continue;
		if (n == 0) add_aggregate_var(r, name, namelen, i);
		else {
			addtobuffer(r, ",");
			add_aggregate_var(r, name, namelen, i);
			if      (strcmp(op,"MIN")==0)    addtobuffer(r, ",MIN");
			else if (strcmp(op,"MAX")==0)    addtobuffer(r, ",MAX");
			else if (strcmp(op,"MINNAN")==0) addtobuffer(r, ",MINNAN");
			else if (strcmp(op,"MAXNAN")==0) addtobuffer(r, ",MAXNAN");
			else if (strcmp(op,"SUMNAN")==0) addtobuffer(r, ",ADDNAN");
			else                              addtobuffer(r, ",+");
		}
		n++;
	}
	if      (n == 0)                  addtobuffer(r, "UNKN");
	else if (strcmp(op,"AVG")==0)     { char nb[20]; snprintf(nb, sizeof(nb), ",%d,/", n); addtobuffer(r, nb); }
}

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
static int failures = 0;
static void check(const char *label, char *tpl, int n, int first, int last, const char *want) {
	rrddbcount = n; firstidx = first; lastidx = last;
	char *got = expand_one(tpl);
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL %s: tpl=%s n=%d -> %s (want %s)\n", label, tpl, n, got, want);
		failures++;
	} else {
		printf("ok   %s: %s -> %s\n", label, tpl, got);
	}
	free(got);
}

int main(void) {
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
	check("p95-n3", "@P95:t@", 3, -1, 0, "t0,t1,t2,95,3,PERCENT");
	check("percent-n3", "@PERCENT:t:90@", 3, -1, 0, "t0,t1,t2,90,3,PERCENT");
	check("p99.9-n3", "@P99.9:t@", 3, -1, 0, "t0,t1,t2,99.9,3,PERCENT");

	/* firstidx/lastidx slicing: only idx 1..2 selected of 4 */
	check("avg-slice", "@AVG:t@", 4, 1, 2, "t1,t2,+,2,/");
	check("count-slice", "@COUNT:t@", 4, 1, 2, "t1,UN,0,1,IF,t2,UN,0,1,IF,+");

	if (failures) { fprintf(stderr, "\n%d failure(s)\n", failures); return 1; }
	printf("\nAll tests passed.\n");
	return 0;
}
