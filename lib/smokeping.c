/*----------------------------------------------------------------------------*/
/* Xymon SmokePing helpers -- implementation                                  */
/*                                                                            */
/* See lib/smokeping.h for the API.                                           */
/*----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <locale.h>

#include "smokeping.h"

/* strtod_l is POSIX 2008; declared by <stdlib.h> under
 * _POSIX_C_SOURCE >= 200809L. Xymon's build doesn't set that macro
 * project-wide, so we forward-declare locally to keep the rest of
 * the includes untouched. */
extern double strtod_l(const char *nptr, char **endptr, locale_t loc);

/* Return a C-numeric locale handle for strtod_l, lazy-initialised on
 * first call. xymond_rrd inherits the system locale; on de_DE (and
 * other comma-as-decimal locales) strtod("0.000310", ...) parses only
 * "0" and silently truncates every sample to its integer part. The
 * smoke wire format is fixed at "%.6f" (dot decimal) regardless of
 * what the consumer's locale claims, so parse with a forced C locale.
 * Returns (locale_t)0 on newlocale failure -- callers should fall
 * back to plain strtod, which at worst preserves the existing bug. */
static locale_t smokeping_c_locale(void)
{
	static locale_t c_loc = (locale_t)0;
	static int tried = 0;
	if (!tried) {
		c_loc = newlocale(LC_NUMERIC_MASK, "C", (locale_t)0);
		tried = 1;
	}
	return c_loc;
}

/* Forward decls; we don't include libxymon.h so the unit test can
 * compile this TU standalone with its own shims. */
extern char *xgetenv(const char *name);
extern void *setup_template(char **params);

static int cached_n = 0;

/* Per-N cache of params/template. A smoke handler may need a different
 * RRD shape per host (smoke_conn:N != $SMOKEPINGSAMPLES), so we keep a
 * tiny linear cache keyed by N. The expected cardinality is 1 in the
 * common case and a small handful in heterogeneous setups. */
struct smoke_n_cache {
	int n;
	char **params;
	void *tpl;
	struct smoke_n_cache *next;
};
static struct smoke_n_cache *cache_head = NULL;

int smokeping_sample_count(void)
{
	char *envn;

	if (cached_n > 0) return cached_n;
	envn = xgetenv("SMOKEPINGSAMPLES");
	cached_n = (envn ? atoi(envn) : 20);
	if (cached_n <= 0) cached_n = 20;
	return cached_n;
}

static struct smoke_n_cache *cache_lookup_or_create(int n)
{
	struct smoke_n_cache *c;

	for (c = cache_head; c; c = c->next) {
		if (c->n == n) return c;
	}
	c = (struct smoke_n_cache *)calloc(1, sizeof(*c));
	c->n = n;
	c->next = cache_head;
	cache_head = c;
	return c;
}

char **smokeping_rrd_params_n(int n)
{
	struct smoke_n_cache *c;
	int i;
	char buf[64];

	if (n <= 0) n = smokeping_sample_count();
	c = cache_lookup_or_create(n);
	if (c->params) return c->params;

	c->params = (char **)calloc(n + 1, sizeof(char *));
	for (i = 0; i < n; i++) {
		snprintf(buf, sizeof(buf), "DS:ping%d:GAUGE:600:0:U", i + 1);
		c->params[i] = strdup(buf);
	}
	c->params[n] = NULL;
	return c->params;
}

/* The summary file's datasets: the run's median and loss, then the
 * smoke column's verdict (see smokeping_format_summary) - the loss over
 * the last hour, the colour it gave and the levels it was judged by. */
static char *summary_params[] = {
	"DS:median:GAUGE:600:0:U",
	"DS:loss:GAUGE:600:0:U",
	"DS:losshour:GAUGE:600:0:1",
	"DS:lossstate:GAUGE:600:0:2",
	"DS:losswarn:GAUGE:600:0:1",
	"DS:losscrit:GAUGE:600:0:1",
	NULL
};

char **smokeping_summary_params(void)
{
	return summary_params;
}

void *smokeping_summary_template(void)
{
	static void *tpl = NULL;

	if (!tpl) tpl = setup_template(summary_params);
	return tpl;
}

char **smokeping_rrd_params(void)
{
	return smokeping_rrd_params_n(smokeping_sample_count());
}

void *smokeping_rrd_template_n(int n)
{
	struct smoke_n_cache *c;

	if (n <= 0) n = smokeping_sample_count();
	c = cache_lookup_or_create(n);
	if (c->tpl) return c->tpl;
	c->tpl = setup_template(smokeping_rrd_params_n(n));
	return c->tpl;
}

void *smokeping_rrd_template(void)
{
	return smokeping_rrd_template_n(smokeping_sample_count());
}

int smokeping_parse_message(const char *msg, double *samples_out,
                            int samples_max, int *received_out,
                            int *lost_out, int *total_out)
{
	const char *p, *sp;
	int k = 0, n = 0;
	int nrecv = 0;

	*received_out = 0;
	*lost_out = 0;
	*total_out = 0;

	p = strstr(msg, "loss=");
	if (!p) return 0;
	if (sscanf(p + 5, "%d/%d", &k, &n) >= 1) {
		*lost_out = k;
		*total_out = n;
	}

	sp = strstr(msg, "samples=");
	if (sp) {
		const char *vp = sp + strlen("samples=");
		char *qq;
		locale_t c_loc = smokeping_c_locale();
		while (*vp && (nrecv < samples_max)) {
			double v;
			if ((*vp == ' ') || (*vp == '\n') || (*vp == '\0')) break;
			v = (c_loc ? strtod_l(vp, &qq, c_loc) : strtod(vp, &qq));
			if (qq == vp) break;	/* not a number */
			/* Drop NaN / +-inf so a malformed sample can't pollute the
			 * downstream median (qsort with < and > is unordered for NaN
			 * and would silently corrupt the sort). */
			if (isfinite(v)) samples_out[nrecv++] = v;
			vp = qq;
			if (*vp == ',') vp++;
		}
	}
	*received_out = nrecv;
	return 1;
}

int smokeping_from_fping_count(const char *line, char *out, int outlen)
{
	const char *p = line;
	char ip[64];
	double ms[SMOKEPING_MAX_SAMPLES];
	int iplen, received = 0, total = 0, off, i;
	double sum = 0.0;
	locale_t c_loc = smokeping_c_locale();

	iplen = (int)strcspn(p, " \t\n");
	if ((iplen == 0) || (iplen >= (int)sizeof(ip))) return 0;
	memcpy(ip, p, iplen); ip[iplen] = '\0';
	p += iplen; p += strspn(p, " \t");
	if ((*p != ':') || ((p[1] != ' ') && (p[1] != '\t'))) return 0;
	p++;

	while (1) {
		p += strspn(p, " \t");
		if ((*p == '\0') || (*p == '\n')) break;
		if (total == SMOKEPING_MAX_SAMPLES) return 0;
		if ((*p == '-') && ((p[1] == ' ') || (p[1] == '\t') || (p[1] == '\n') || (p[1] == '\0'))) {
			p++;
		}
		else {
			char *end;
			double v = (c_loc ? strtod_l(p, &end, c_loc) : strtod(p, &end));

			if ((end == p) || !isfinite(v) || (v < 0) ||
			    ((*end != ' ') && (*end != '\t') && (*end != '\n') && (*end != '\0'))) return 0;
			ms[received++] = v; sum += v;
			p = end;
		}
		total++;
	}
	if (total == 0) return 0;

	if (received == 0)
		off = snprintf(out, outlen, "%s is unreachable loss=%d/%d", ip, total, total);
	else {
		off = snprintf(out, outlen, "%s is alive (%.3f ms) samples=", ip, sum / received);
		for (i = 0; ((i < received) && (off >= 0) && (off < outlen)); i++)
			off += snprintf(out + off, outlen - off, "%s%.6f", (i ? "," : ""), ms[i] / 1000.0);
		if ((off >= 0) && (off < outlen))
			off += snprintf(out + off, outlen - off, " loss=%d/%d", total - received, total);
	}
	return ((off >= 0) && (off < outlen));
}

int smokeping_format_verdict(const char *msg, char *out, int outlen)
{
	static const char *keys[] = { "losshour=", "lossstate=", "losswarn=", "losscrit=", NULL };
	locale_t c_loc = smokeping_c_locale();
	int off = 0, i;

	for (i = 0; (keys[i] && (off >= 0) && (off < outlen)); i++) {
		const char *p = strstr(msg, keys[i]);
		char *end = NULL;
		double v = NAN;

		if (p) {
			p += strlen(keys[i]);
			v = (c_loc ? strtod_l(p, &end, c_loc) : strtod(p, &end));
			if ((end == p) || !isfinite(v) || (v < 0)) v = NAN;
		}
		if (isfinite(v)) off += snprintf(out + off, outlen - off, ":%.6f", v);
		else off += snprintf(out + off, outlen - off, ":U");
	}
	return (((off >= 0) && (off < outlen)) ? off : -1);
}

int smokeping_hist_format(const smoke_hist_t *h, char *out, int outlen)
{
	int off, i;

	off = snprintf(out, outlen, "%d %d", h->hourstate, h->burst);
	for (i = 0; ((i < h->nruns) && (off >= 0) && (off < outlen)); i++) {
		const smoke_run_t *r = &h->run[i];
		char med[32], spr[32];

		if (isfinite(r->median)) snprintf(med, sizeof(med), "%.6f", r->median); else strcpy(med, "U");
		if (isfinite(r->spread)) snprintf(spr, sizeof(spr), "%.6f", r->spread); else strcpy(spr, "U");
		off += snprintf(out + off, outlen - off, " %ld:%d:%d:%s:%s", (long)r->t, r->lost, r->sent, med, spr);
	}
	return (((off >= 0) && (off < outlen)) ? off : -1);
}

int smokeping_hist_parse(const char *line, smoke_hist_t *h)
{
	const char *p = line;
	int n;

	memset(h, 0, sizeof(*h));
	if (sscanf(p, "%d %d%n", &h->hourstate, &h->burst, &n) < 2) { h->hourstate = h->burst = 0; return 0; }
	if ((h->hourstate < 0) || (h->hourstate > 2)) h->hourstate = 0;
	h->burst = (h->burst != 0);
	p += n;
	while (*p && (h->nruns < SMOKE_MAXRUNS)) {
		smoke_run_t r;
		long t;
		char med[32], spr[32];
		locale_t c_loc = smokeping_c_locale();

		p += strspn(p, " \t");
		if (*p == '\0' || *p == '\n') break;
		if (sscanf(p, "%ld:%d:%d:%31[^:]:%31[^ \t\n]", &t, &r.lost, &r.sent, med, spr) != 5) break;
		r.t = (time_t)t;
		r.median = (strcmp(med, "U") ? (c_loc ? strtod_l(med, NULL, c_loc) : strtod(med, NULL)) : NAN);
		r.spread = (strcmp(spr, "U") ? (c_loc ? strtod_l(spr, NULL, c_loc) : strtod(spr, NULL)) : NAN);
		if ((r.sent > 0) && (r.lost >= 0) && (r.lost <= r.sent)) h->run[h->nruns++] = r;
		p += strcspn(p, " \t\n");
	}
	return h->nruns;
}

void smokeping_hist_add(smoke_hist_t *h, const smoke_run_t *run, time_t window)
{
	int i, keep = 0;

	for (i = 0; (i < h->nruns); i++) {
		if (h->run[i].t > run->t - window) h->run[keep++] = h->run[i];
	}
	h->nruns = keep;
	if (h->nruns == SMOKE_MAXRUNS) {
		memmove(&h->run[0], &h->run[1], (SMOKE_MAXRUNS - 1) * sizeof(smoke_run_t));
		h->nruns--;
	}
	h->run[h->nruns++] = *run;
}

void smokeping_judge(smoke_hist_t *h, time_t window, int minpings,
                     const smoke_levels_t *lv, smoke_verdict_t *v)
{
	const smoke_run_t *last = (h->nruns ? &h->run[h->nruns - 1] : NULL);
	int i, state = 0, burststate = 0;

	memset(v, 0, sizeof(*v));
	for (i = 0; (i < h->nruns); i++) {
		if (last && (h->run[i].t <= last->t - window)) continue;
		v->hourlost += h->run[i].lost;
		v->hoursent += h->run[i].sent;
	}

	v->judged = ((v->hoursent > 0) && (v->hoursent >= minpings));
	if (v->judged) {
		double pct = 100.0 * v->hourlost / v->hoursent;

		if ((lv->crit > 0) && ((pct >= lv->crit) || ((h->hourstate == 2) && (pct >= lv->crit * 2 / 3)))) state = 2;
		else if ((lv->warn > 0) && ((pct >= lv->warn) || ((h->hourstate >= 1) && (pct >= lv->warn * 2 / 3)))) state = 1;
	}
	h->hourstate = state;

	v->burst = (last && (lv->burst > 0) && (last->sent > 0) && (100.0 * last->lost / last->sent >= lv->burst));
	if (v->burst) burststate = (h->burst ? 2 : 1);
	h->burst = v->burst;

	v->state = ((state > burststate) ? state : burststate);
}

static int qsort_double(const void *a, const void *b)
{
	double da = *(const double *)a, db = *(const double *)b;
	return (da < db) ? -1 : (da > db);
}

double smokeping_median(double *samples, int received)
{
	if (received <= 0) return NAN;
	qsort(samples, received, sizeof(double), qsort_double);
	if (received & 1) return samples[received / 2];
	return (samples[received / 2 - 1] + samples[received / 2]) / 2.0;
}

int smokeping_format_samples_n(char *out, int outlen, time_t tstamp,
                               const double *sorted_samples,
                               int received, int n_slots)
{
	int off, i, lower;

	if (n_slots <= 0) n_slots = smokeping_sample_count();
	lower = ((received < n_slots) ? (n_slots - received) / 2 : 0);

	off = snprintf(out, outlen, "%d", (int)tstamp);
	for (i = 0; (i < n_slots) && (off < outlen); i++) {
		if ((i >= lower) && (i - lower < received)) {
			off += snprintf(out + off, outlen - off, ":%.6f", sorted_samples[i - lower]);
		}
		else {
			off += snprintf(out + off, outlen - off, ":U");
		}
	}
	return off;
}

int smokeping_format_summary(char *out, int outlen, time_t tstamp,
                             double median, double lossfrac, int received,
                             const char *msg)
{
	int off;

	if (received > 0) off = snprintf(out, outlen, "%d:%.6f:%.6f", (int)tstamp, median, lossfrac);
	else off = snprintf(out, outlen, "%d:U:%.6f", (int)tstamp, lossfrac);
	if ((off < 0) || (off >= outlen)) return -1;
	return ((smokeping_format_verdict(msg, out + off, outlen - off) < 0) ? -1 : (int)strlen(out));
}
