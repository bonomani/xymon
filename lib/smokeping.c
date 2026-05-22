/*----------------------------------------------------------------------------*/
/* Xymon SmokePing helpers -- implementation                                  */
/*                                                                            */
/* See lib/smokeping.h for the API.                                           */
/*----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "smokeping.h"

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

	c->params = (char **)calloc(n + 3, sizeof(char *));
	c->params[0] = strdup("DS:median:GAUGE:600:0:U");
	c->params[1] = strdup("DS:loss:GAUGE:600:0:U");
	for (i = 0; i < n; i++) {
		snprintf(buf, sizeof(buf), "DS:ping%d:GAUGE:600:0:U", i + 1);
		c->params[2 + i] = strdup(buf);
	}
	c->params[n + 2] = NULL;
	return c->params;
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
		while (*vp && (nrecv < samples_max)) {
			double v;
			if ((*vp == ' ') || (*vp == '\n') || (*vp == '\0')) break;
			v = strtod(vp, &qq);
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

int smokeping_format_rrdvalues_n(char *out, int outlen, time_t tstamp,
                                 double median, double lossfrac,
                                 const double *sorted_samples,
                                 int received, int n_slots)
{
	int off, i;

	if (n_slots <= 0) n_slots = smokeping_sample_count();

	off = snprintf(out, outlen, "%d:", (int)tstamp);
	if (received > 0) {
		off += snprintf(out + off, outlen - off, "%.6f:%.6f", median, lossfrac);
	}
	else {
		off += snprintf(out + off, outlen - off, "U:%.6f", lossfrac);
	}
	for (i = 0; (i < n_slots) && (off < outlen); i++) {
		if (i < received) {
			off += snprintf(out + off, outlen - off, ":%.6f", sorted_samples[i]);
		}
		else {
			off += snprintf(out + off, outlen - off, ":U");
		}
	}
	return off;
}

int smokeping_format_rrdvalues(char *out, int outlen, time_t tstamp,
                               double median, double lossfrac,
                               const double *sorted_samples, int received)
{
	return smokeping_format_rrdvalues_n(out, outlen, tstamp, median,
	                                    lossfrac, sorted_samples,
	                                    received, smokeping_sample_count());
}
