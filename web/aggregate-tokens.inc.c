/*
 * web/aggregate-tokens.inc.c
 *
 * Shared parser + RPN-emitter for graphs.cfg aggregate template tokens:
 *     @AVG: @SUM: @MIN: @MAX: @AVGNAN: @SUMNAN: @MINNAN: @MAXNAN:
 *     @COUNT: @MEDIAN: @STDEV: @PERCENT: @P<pct>:
 *
 * A token combines the variables its name prefixes, in the direction the
 * DEF lines that made them took (aggregate_next):
 *   - across files: name0..nameN-1, one per RRD matched by FNPATTERN,
 *     made by a line templated with @RRDIDX@;
 *   - within one file: nameK..nameN, the samples a file stores as N
 *     datasets (ping1..pingN), made by a line templated with @DSIDX@.
 *     The caller lists those names in `aggregate_dsfams` and sets N in
 *     `aggregate_dscount`; with N = 0 the set is empty.
 *
 * This file is **#include**'d by both web/showgraph.c (production) and
 * tests/web/aggregate-tokens-harness.c (golden-output test). Including it from
 * two TUs keeps the parser and the test in lockstep: any future bug fix
 * here is visible to both without manual mirroring.
 *
 * The including TU must provide:
 *   - file-scope: int rrddbcount, int firstidx, int lastidx
 *   - strbuffer_t and the addtobuffer / addtobufferraw functions
 *
 * All symbols below are `static` so multiple includes (or different
 * including TUs in the same program, which isn't a current use case)
 * stay isolated.
 */

/* The within-file context of the graph being emitted. aggregate_dscount
 * is the current file's dataset count N; aggregate_dsfams lists the
 * variable names that @DSIDX@-templated DEF and CDEF lines make, each
 * with the index its line starts at, as ",ping:1,s:2," (see
 * dsidx_families in dsidx.inc.c). Callers set both before
 * expand_aggregate_tokens and clear them afterwards. They live at file
 * scope, not as parameters, so the expand_aggregate_tokens /
 * add_aggregate_rpn signatures stay untouched and the test can drive
 * them the same way. */
static int aggregate_dscount = 0;
static char *aggregate_dsfams = NULL;

static int selected_rrdidx(int idx)
{
	return ((firstidx == -1) || ((idx >= firstidx) && (idx <= lastidx)));
}

/* Does "name" match the family entry at fam (up to its ':')? An
 * "@RRDIDX@" in the entry matches a file index, so the family a line
 * "DEF:p@RRDIDX@x@DSIDX@=..." makes holds p0x, p1x...: "p2x" names the
 * datasets of file 2. Returns the length of the entry, or 0. */
static int aggregate_fam_match(char *fam, char *name, int namelen)
{
	char *f = fam, *n = name, *end = name + namelen;

	while (*f && (*f != ':')) {
		if (strncmp(f, "@RRDIDX@", 8) == 0) {
			if ((n == end) || !isdigit((int)*n)) return 0;
			while ((n < end) && isdigit((int)*n)) n++;
			f += 8;
		}
		else if ((n < end) && (*f == *n)) { f++; n++; }
		else return 0;
	}
	return (((*f == ':') && (n == end)) ? (int)(f - fam) : 0);
}

/* The index an aggregate over "name" walks after `prev` (-1 to start),
 * or -1 when the set is done: the family's start..aggregate_dscount when
 * a @DSIDX@-templated line makes the name, else each selected file. */
static int aggregate_next(char *name, int namelen, int prev)
{
	char *p;
	int famlen;

	for (p = aggregate_dsfams; (p && (p = strchr(p, ',')) != NULL); p++) {
		if ((famlen = aggregate_fam_match(p + 1, name, namelen)) > 0) {
			int start = atoi(p + famlen + 2);
			int next = ((prev < start) ? start : prev + 1);

			return ((next <= aggregate_dscount) ? next : -1);
		}
	}

	for (prev++; (prev < rrddbcount); prev++) {
		if (selected_rrdidx(prev)) return prev;
	}
	return -1;
}

static int is_aggregate_token(char *inp, char **op, char **name, int *oplen, int *toklen)
{
	char *p;

	if (strncmp(inp, "@AVG:", 5) == 0) {
		*op = "AVG";
		*oplen = 5;
	}
	else if (strncmp(inp, "@SUM:", 5) == 0) {
		*op = "SUM";
		*oplen = 5;
	}
	else if (strncmp(inp, "@MIN:", 5) == 0) {
		*op = "MIN";
		*oplen = 5;
	}
	else if (strncmp(inp, "@MAX:", 5) == 0) {
		*op = "MAX";
		*oplen = 5;
	}
	else if (strncmp(inp, "@AVGNAN:", 8) == 0) {
		*op = "AVGNAN";
		*oplen = 8;
	}
	else if (strncmp(inp, "@SUMNAN:", 8) == 0) {
		*op = "SUMNAN";
		*oplen = 8;
	}
	else if (strncmp(inp, "@MINNAN:", 8) == 0) {
		*op = "MINNAN";
		*oplen = 8;
	}
	else if (strncmp(inp, "@MAXNAN:", 8) == 0) {
		*op = "MAXNAN";
		*oplen = 8;
	}
	else if (strncmp(inp, "@COUNT:", 7) == 0) {
		*op = "COUNT";
		*oplen = 7;
	}
	else if (strncmp(inp, "@MEDIAN:", 8) == 0) {
		*op = "MEDIAN";
		*oplen = 8;
	}
	else if (strncmp(inp, "@STDEV:", 7) == 0) {
		*op = "STDEV";
		*oplen = 7;
	}
	else if (strncmp(inp, "@PERCENT:", 9) == 0) {
		*op = "PERCENT";
		*oplen = 9;
	}
	else if ((inp[0] == '@') && (inp[1] == 'P') && isdigit((int)inp[2])) {
		/* @P<pct>: shorthand for @PERCENT:name:pct@. Accept a decimal
		 * number with at most one dot (95, 99.9, 0.5, and a trailing
		 * "90." that rrdtool reads as 90); reject 95.5.5 and a leading
		 * dot -- the earlier any-number-of-dots parse produced RPN
		 * that rrdtool refused. The `D...' prefix space is reserved
		 * for the @DSIDX@ family (dsidx.inc.c); don't add ops
		 * starting with D here. */
		int dots = 0;
		p = inp + 3;
		while (1) {
			if (isdigit((int)*p)) { p++; continue; }
			if (*p == '.' && dots == 0) { dots = 1; p++; continue; }
			break;
		}
		if (*p != ':') return 0;

		/* For @P<pct>:name@, *op points into the input at the digits
		 * (e.g. "95:name@..."), NOT to a NUL-terminated operator
		 * literal. Callers detect this form via isdigit(op[0]) and
		 * read pct via the leading digit run; never strcmp it against
		 * an operator name. */
		*op = inp + 2;
		*oplen = (p - inp) + 1;
	}
	else {
		return 0;
	}

	*name = inp + *oplen;
	p = strchr(*name, '@');
	if (p == NULL) return 0;
	/* Reject empty operand: @AVG:@ used to "succeed" with namelen=0,
	 * producing RPN that references undefined DEF vars (0,1,2,3,AVG)
	 * which rrdtool rejects with a confusing message. */
	if (p == *name) return 0;
	/* Reject names that contain whitespace, comma, or semicolon. Without
	 * this, "@AVG:foo bar @WHATEVER@" would swallow the @WHATEVER@
	 * token's leading @ as part of the unbounded strchr search,
	 * silently corrupting the surrounding template. Stay permissive on
	 * the rest -- "name" may carry "." (for @PERCENT:n:99.9@), ":" (the
	 * inner separator), and identifier characters used in DEF names. */
	{
		char *q;
		for (q = *name; q < p; q++) {
			if (isspace((int)*q) || *q == ',' || *q == ';') return 0;
		}
	}
	*toklen = (p - inp) + 1;

	return 1;
}

static int def_uses_aggregate(char *def)
{
	char *p;

	for (p = strchr(def, '@'); p; p = strchr(p + 1, '@')) {
		char *op, *name;
		int oplen, toklen;

		if (is_aggregate_token(p, &op, &name, &oplen, &toklen)) return 1;
	}

	return 0;
}

static void add_aggregate_var(strbuffer_t *result, char *name, int namelen, int idx)
{
	char numstr[20];

	addtobufferraw(result, name, namelen);
	snprintf(numstr, sizeof(numstr), "%d", idx);
	addtobuffer(result, numstr);
}

static void add_aggregate_varlist(strbuffer_t *result, char *name, int namelen, int *count)
{
	int i;

	*count = 0;
	for (i = aggregate_next(name, namelen, -1); (i >= 0); i = aggregate_next(name, namelen, i)) {
		if (*count > 0) addtobuffer(result, ",");
		add_aggregate_var(result, name, namelen, i);
		(*count)++;
	}
}

/* An unknown result that RRDtool still accepts: a CDEF naming no
 * variable ("UNKN" alone) fails the whole graph, so add UNKN to the
 * first selected file's variable. With nothing selected, showgraph
 * draws no graph and the bare UNKN is never evaluated. */
static void add_aggregate_unknown(strbuffer_t *result, char *name, int namelen)
{
	int i;

	for (i = aggregate_next(name, namelen, -1); (i >= 0); i = aggregate_next(name, namelen, i)) {
		add_aggregate_var(result, name, namelen, i);
		addtobuffer(result, ",UNKN,+");
		return;
	}
	addtobuffer(result, "UNKN");
}

static void add_aggregate_count_rpn(strbuffer_t *result, char *name, int namelen)
{
	int i, n = 0;

	for (i = aggregate_next(name, namelen, -1); (i >= 0); i = aggregate_next(name, namelen, i)) {
		if (n > 0) addtobuffer(result, ",");
		add_aggregate_var(result, name, namelen, i);
		addtobuffer(result, ",UN,0,1,IF");
		if (n > 0) addtobuffer(result, ",+");
		n++;
	}

	/* Empty selection: emit "0" rather than UNKN so callers can divide
	 * (UNKN/0 = UNKN in rrdtool; division by literal 0 yields UNKN as
	 * well, so dividing by @COUNT: stays safe in either case). Other
	 * ops emit "UNKN" for the empty case; the inconsistency is
	 * intentional: count-of-nothing is 0, sum/avg-of-nothing is
	 * undefined. */
	if (n == 0) addtobuffer(result, "0");
}

static void add_aggregate_rpn(strbuffer_t *result, char *op, char *name, int namelen)
{
	int i, n = 0;
	char *pct = NULL;
	int pctlen = 0;
	int ispercent = ((strcmp(op, "PERCENT") == 0) || isdigit((int)op[0]));

	if (ispercent) {
		char *p;

		if (isdigit((int)op[0])) {
			/* @P<pct>:name@ -- pct already validated in is_aggregate_token. */
			pct = op;
			p = op;
			while (isdigit((int)*p) || (*p == '.')) p++;
			pctlen = (p - op);
		}
		else if (namelen > 0) {
			/* @PERCENT:name:pct@ -- pct lives after an inner colon.
			 * Validate the same digits+one-dot shape that is_aggregate_token
			 * enforces for @P<pct>:; otherwise @PERCENT:t:abc@ and
			 * @PERCENT:t:95:garbage@ would emit garbage into the RPN. */
			p = memchr(name, ':', namelen);
			if (p) {
				int i, dots = 0, ok = 1;
				pct = p + 1;
				pctlen = namelen - (p - name) - 1;
				namelen = (p - name);
				for (i = 0; ok && i < pctlen; i++) {
					if (isdigit((int)pct[i])) continue;
					if (pct[i] == '.' && dots == 0) { dots = 1; continue; }
					ok = 0;
				}
				if (!ok) pctlen = 0;
			}
		}

		if (namelen == 0) {
			addtobuffer(result, "UNKN");
			return;
		}
		/* RRDtool fails the whole graph on a pct outside 0..100; an
		 * unknown curve is the smaller failure, as for a malformed pct. */
		if ((pct == NULL) || (pctlen == 0) || (strtod(pct, NULL) > 100)) {
			add_aggregate_unknown(result, name, namelen);
			return;
		}
	}

	if (strcmp(op, "COUNT") == 0) {
		add_aggregate_count_rpn(result, name, namelen);
		return;
	}

	if ((strcmp(op, "AVGNAN") == 0) || (strcmp(op, "MEDIAN") == 0) ||
	    (strcmp(op, "STDEV") == 0) || ispercent) {
		add_aggregate_varlist(result, name, namelen, &n);

		if (n == 0) {
			addtobuffer(result, "UNKN");
			return;
		}

		if (ispercent) {
			char numstr[40];

			/* Nearest rank over the files that hold a value. RRDtool's
			 * PERCENT would rank each UNKN below every number, so a
			 * silent file would pull the result down. SORT puts the
			 * UNKNs at the bottom and the c known values on top, so the
			 * k-th smallest known value lies c-k+1 deep, where INDEX
			 * fetches it. k is round(pct*c/100), as PERCENT computes it,
			 * but at least 1: the smallest value for any pct that low.
			 * The depth is at least 1 too, so with c = 0 INDEX fetches
			 * an UNKN. EXC,POP then drops the n sorted values under the
			 * result. pct ends at the ':' or '@' after its digits. */
			snprintf(numstr, sizeof(numstr), ",%d,SORT,", n);
			addtobuffer(result, numstr);
			add_aggregate_count_rpn(result, name, namelen);
			addtobuffer(result, ",DUP,");
			addtobufferraw(result, pct, pctlen);
			addtobuffer(result, ",*,100,/,0.5,+,FLOOR,1,MAX,-,1,+,1,MAX,INDEX");
			for (i = 0; (i < n); i++) addtobuffer(result, ",EXC,POP");
		}
		else {
			char numstr[20];

			snprintf(numstr, sizeof(numstr), ",%d,%s", n, ((strcmp(op, "AVGNAN") == 0) ? "AVG" : op));
			addtobuffer(result, numstr);
		}
		return;
	}

	for (i = aggregate_next(name, namelen, -1); (i >= 0); i = aggregate_next(name, namelen, i)) {
		if (n == 0) {
			add_aggregate_var(result, name, namelen, i);
		}
		else {
			addtobuffer(result, ",");
			add_aggregate_var(result, name, namelen, i);
			if (strcmp(op, "MIN") == 0) addtobuffer(result, ",MIN");
			else if (strcmp(op, "MAX") == 0) addtobuffer(result, ",MAX");
			else if (strcmp(op, "MINNAN") == 0) addtobuffer(result, ",MINNAN");
			else if (strcmp(op, "MAXNAN") == 0) addtobuffer(result, ",MAXNAN");
			else if (strcmp(op, "SUMNAN") == 0) addtobuffer(result, ",ADDNAN");
			else addtobuffer(result, ",+");
		}
		n++;
	}

	if (n == 0) {
		addtobuffer(result, "UNKN");
	}
	else if (strcmp(op, "AVG") == 0) {
		/* Divides by the SELECTED count, not the non-NaN count.
		 * If any selected DEF is UNKN, the running sum propagates
		 * UNKN and the result is UNKN. For NaN-aware averaging,
		 * combine @SUMNAN:/@COUNT: at the caller. */
		char numstr[20];

		snprintf(numstr, sizeof(numstr), ",%d,/", n);
		addtobuffer(result, numstr);
	}
}
