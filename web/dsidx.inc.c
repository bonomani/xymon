/*
 * web/dsidx.inc.c
 *
 * Parse-time expansion of the graphs.cfg @DSIDX@ family (@DSIDX@,
 * @PREVDSIDX@, @DSSTART:N@, and the @SMOKE:name@ line) and the DEF-line
 * helpers it needs.
 *
 * #include'd by web/showgraph.c and by tests/web/dsidx-harness.c, so the
 * test drives this code rather than a copy of it.
 *
 * The including TU must provide gdef_t with the fields defs, dsfams,
 * dscount and dsidx_runtime, and the xfree() macro.
 */

/* Replace all occurrences of `needle` in `src` with `repl`. Returns a
 * malloc'd string; caller frees. */
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
	memcpy(q, src, strlen(src) + 1);
	return out;
}

/* A line that is only "@SMOKE:name@": returns the length of name (an
 * identifier) and points *name at it, else 0. */
static int smoke_line_name(const char *line, const char **name)
{
	int len;

	if (strncmp(line, "@SMOKE:", 7) != 0) return 0;
	line += 7;
	len = (int)strspn(line, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_");
	if ((len == 0) || (line[len] != '@') || (line[len + 1] != '\0')) return 0;
	*name = line;
	return len;
}

/* The lines "@SMOKE:name@" stands for, over name1..nameN: SmokePing's
 * smoke. The samples pair from the outside in - 1 with N, 2 with N-1 -
 * and each pair draws an invisible base up to its lower sample and the
 * gap to its upper one stacked on it, in a grey darker toward the
 * middle pair, so where most samples lie is darkest. A pair missing a
 * sample draws nothing. Fewer than 3 samples make no smoke. Writes the
 * lines into out (when not NULL) and returns how many there are.
 * Pairing by slot is only right for samples stored as SmokePing stores
 * them - sorted, the lost ones as UNKN centred around them - which
 * nothing here can check (graphs.cfg(5)). */
static int smoke_lines(const char *name, int namelen, int n, char **out)
{
	int ibot, itop, count = 0;
	double half = n / 2.0;
	char buf[256];

	if (n < 3) return 0;
	for (ibot = 1, itop = n; (itop > ibot); ibot++, itop--) {
		int grey = (int)(190 / half * (half - ibot)) + 50;

		if (out) {
			snprintf(buf, sizeof(buf), "CDEF:%.*ssmoke%d=%.*s%d,UN,UNKN,%.*s%d,%.*s%d,-,IF",
				 namelen, name, ibot, namelen, name, ibot, namelen, name, itop, namelen, name, ibot);
			out[count] = strdup(buf);
			snprintf(buf, sizeof(buf), "AREA:%.*s%d", namelen, name, ibot);
			out[count + 1] = strdup(buf);
			snprintf(buf, sizeof(buf), "AREA:%.*ssmoke%d#%02x%02x%02x::STACK", namelen, name, ibot, grey, grey, grey);
			out[count + 2] = strdup(buf);
		}
		count += 3;
	}
	return count;
}

/* Classify a def line for @DSIDX@ expansion.
 *   *body  - the line content after any @DSSTART:N@ prefix is stripped
 *   *start - lower bound of the index loop:
 *              * explicit @DSSTART:N@ prefix wins
 *              * else 2 if the line uses @PREVDSIDX@ (skips ping0)
 *              * else 1
 * Returns 1 if the line should be looped, 0 if it should be emitted once.
 * A "@SMOKE:name@" line counts as looped: it expands per file too. */
static int classify_dsidx_line(char *line, char **body, int *start)
{
	const char *smokename;

	*body = line;
	*start = 1;
	if (smoke_line_name(line, &smokename)) return 1;

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

/* Expand every @DSIDX@/@PREVDSIDX@-templated def line in `defs` into N
 * concrete copies, returning a freshly-allocated NULL-terminated array.
 * Non-templated lines are copied verbatim. Caller owns the result.
 * If n <= 0 the templates pass through unchanged so the literal tokens
 * reach rrdtool, which errors loudly -- the desired fail-fast signal. */
static char **expand_dsidx_array(char *const *defs, int n)
{
	int i, newcount = 0, outi = 0;
	char **newdefs;
	char idxstr[16], previdxstr[16];

	if (defs == NULL) return NULL;

	if (n <= 0) {
		for (i = 0; defs[i]; i++) newcount++;
		newdefs = (char **)calloc(newcount + 1, sizeof(char *));
		for (i = 0; defs[i]; i++) newdefs[i] = strdup(defs[i]);
		newdefs[newcount] = NULL;
		return newdefs;
	}

	for (i = 0; defs[i]; i++) {
		char *body;
		int start;
		const char *smokename;
		int smokelen = smoke_line_name(defs[i], &smokename);
		char *line = strdup(defs[i]);
		if (smokelen) {
			newcount += smoke_lines(smokename, smokelen, n, NULL);
		}
		else if (classify_dsidx_line(line, &body, &start)) {
			int m = n - start + 1;
			newcount += (m > 0 ? m : 0);
		}
		else {
			newcount++;
		}
		xfree(line);
	}

	newdefs = (char **)calloc(newcount + 1, sizeof(char *));
	for (i = 0; defs[i]; i++) {
		char *body;
		int start;
		const char *smokename;
		int smokelen = smoke_line_name(defs[i], &smokename);
		char *line = strdup(defs[i]);
		if (smokelen) {
			outi += smoke_lines(smokename, smokelen, n, newdefs + outi);
		}
		else if (classify_dsidx_line(line, &body, &start)) {
			int idx;
			for (idx = start; idx <= n; idx++) {
				char *tmp;
				snprintf(idxstr, sizeof(idxstr), "%d", idx);
				snprintf(previdxstr, sizeof(previdxstr), "%d", idx - 1);
				/* Replace @PREVDSIDX@ first so we don't accidentally chew the
				 * shorter @DSIDX@ inside it (currently they don't share a
				 * prefix, but this keeps the substitution order intent-clear). */
				tmp = str_replace_all(body, "@PREVDSIDX@", previdxstr);
				newdefs[outi++] = str_replace_all(tmp, "@DSIDX@", idxstr);
				xfree(tmp);
			}
		}
		else {
			newdefs[outi++] = strdup(defs[i]);
		}
		xfree(line);
	}
	newdefs[outi] = NULL;
	return newdefs;
}

/* Does any def line in `defs` use @DSIDX@/@PREVDSIDX@? */
static int defs_use_dsidx(char *const *defs)
{
	int i;
	if (defs == NULL) return 0;
	for (i = 0; defs[i]; i++) {
		if (strstr(defs[i], "@DSIDX@") || strstr(defs[i], "@PREVDSIDX@")) return 1;
	}
	return 0;
}

/* A family name: identifier characters, and "@RRDIDX@" anywhere. */
static int dsidx_famname_ok(const char *name, int len)
{
	int i = 0;

	while (i < len) {
		if (strncmp(name + i, "@RRDIDX@", 8) == 0) i += 8;
		else if (isalnum((int)name[i]) || (name[i] == '_')) i++;
		else return 0;
	}
	return (i == len);
}

/* The variable names that @DSIDX@-templated DEF and CDEF lines make, as
 * ",ping:1,s:2,": the name before "@DSIDX@" in "DEF:ping@DSIDX@=...",
 * with the index its line starts at. The name may hold "@RRDIDX@", as in
 * "DEF:p@RRDIDX@x@DSIDX@=...", one family per file. Aggregate tokens over
 * such a name walk the file's datasets instead of the matched files
 * (aggregate_next in aggregate-tokens.inc.c). Returns a malloc'd string,
 * or NULL. */
static char *dsidx_families(char *const *defs)
{
	char *fams = NULL;
	size_t len = 0;
	int i;

	for (i = 0; (defs && defs[i]); i++) {
		char *body, *vname, *eq;
		int start, namelen;
		char *line = strdup(defs[i]);

		if (classify_dsidx_line(line, &body, &start)) {
			if (strncmp(body, "DEF:", 4) == 0) vname = body + 4;
			else if (strncmp(body, "CDEF:", 5) == 0) vname = body + 5;
			else vname = NULL;
			eq = (vname ? strchr(vname, '=') : NULL);
			namelen = (eq ? (int)(eq - vname) - 7 : 0);
			if ((namelen > 0) && (strncmp(vname + namelen, "@DSIDX@", 7) == 0) &&
			    dsidx_famname_ok(vname, namelen)) {
				char entry[100];
				int elen = snprintf(entry, sizeof(entry), "%.*s:%d,", namelen, vname, start);

				if ((elen > 0) && (elen < (int)sizeof(entry))) {
					fams = (char *)realloc(fams, len + elen + 2);
					if (len == 0) fams[len++] = ',';
					memcpy(fams + len, entry, elen + 1);
					len += elen;
				}
			}
		}
		xfree(line);
	}
	return fams;
}

/* Parse-time entry point for @DSIDX@ blocks. Three regimes:
 *   1. Explicit DSCOUNT N -> expand defs[] in place; final shape is fixed.
 *   2. No DSCOUNT, but defs use @DSIDX@ -> leave defs[] as templates and
 *      mark dsidx_runtime=1, so render time can pick N from the actual
 *      RRD file (different hosts may store different sample counts).
 *   3. No @DSIDX@ at all -> nothing to do.
 */
static void expand_dsidx_in_block(gdef_t *gd)
{
	if (gd->defs == NULL) return;

	gd->dsfams = dsidx_families(gd->defs);
	if (gd->dscount > 0) {
		char **expanded = expand_dsidx_array(gd->defs, gd->dscount);
		int i;
		for (i = 0; gd->defs[i]; i++) xfree(gd->defs[i]);
		xfree(gd->defs);
		gd->defs = expanded;
		return;
	}

	if (defs_use_dsidx(gd->defs)) gd->dsidx_runtime = 1;
}

/* Pull the .rrd filename out of a DEF line of the form
 *   DEF:var=FILENAME:ds:CF
 * Returns a freshly-allocated string (caller frees) or NULL if the line
 * isn't a DEF or doesn't fit that shape. */
static char *def_rrdfile(const char *defline)
{
	const char *eq, *colon;
	char *out;
	size_t n;

	if (strncmp(defline, "DEF:", 4) != 0) return NULL;
	eq = strchr(defline + 4, '=');
	if (!eq) return NULL;
	colon = strchr(eq + 1, ':');
	if (!colon || colon == eq + 1) return NULL;
	n = colon - (eq + 1);
	out = (char *)malloc(n + 1);
	memcpy(out, eq + 1, n);
	out[n] = '\0';
	return out;
}

/* Walk a DS-template like "ping@DSIDX@" and return the literal prefix
 * before @DSIDX@ ("ping"). Caller frees. NULL if no @DSIDX@ present. */
static char *dsname_prefix(const char *tmpl)
{
	const char *at = strstr(tmpl, "@DSIDX@");
	char *out;
	size_t n;
	if (!at) return NULL;
	n = at - tmpl;
	out = (char *)malloc(n + 1);
	memcpy(out, tmpl, n);
	out[n] = '\0';
	return out;
}

/* Pull the DS name template out of a DEF line:
 *   DEF:var=file.rrd:DSNAME:CF -> DSNAME
 * Caller frees; NULL on parse failure. */
static char *def_dsname(const char *defline)
{
	const char *eq, *c1, *c2;
	char *out;
	size_t n;

	if (strncmp(defline, "DEF:", 4) != 0) return NULL;
	eq = strchr(defline + 4, '=');
	if (!eq) return NULL;
	c1 = strchr(eq + 1, ':');
	if (!c1) return NULL;
	c2 = strchr(c1 + 1, ':');
	if (!c2 || c2 == c1 + 1) return NULL;
	n = c2 - (c1 + 1);
	out = (char *)malloc(n + 1);
	memcpy(out, c1 + 1, n);
	out[n] = '\0';
	return out;
}
