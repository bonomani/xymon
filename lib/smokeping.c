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
static char **cached_params = NULL;
static void *cached_tpl = NULL;

int smokeping_sample_count(void)
{
	char *envn;

	if (cached_n > 0) return cached_n;
	envn = xgetenv("SMOKEPINGSAMPLES");
	cached_n = (envn ? atoi(envn) : 20);
	if (cached_n <= 0) cached_n = 20;
	return cached_n;
}

char **smokeping_rrd_params(void)
{
	int i, n;
	char buf[64];

	if (cached_params) return cached_params;
	n = smokeping_sample_count();
	cached_params = (char **)calloc(n + 3, sizeof(char *));
	cached_params[0] = strdup("DS:median:GAUGE:600:0:U");
	cached_params[1] = strdup("DS:loss:GAUGE:600:0:U");
	for (i = 0; i < n; i++) {
		snprintf(buf, sizeof(buf), "DS:ping%d:GAUGE:600:0:U", i + 1);
		cached_params[2 + i] = strdup(buf);
	}
	cached_params[n + 2] = NULL;
	return cached_params;
}

void *smokeping_rrd_template(void)
{
	if (cached_tpl) return cached_tpl;
	cached_tpl = setup_template(smokeping_rrd_params());
	return cached_tpl;
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
			if ((*vp == ' ') || (*vp == '\n') || (*vp == '\0')) break;
			samples_out[nrecv++] = strtod(vp, &qq);
			if (qq == vp) break;	/* not a number */
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

int smokeping_format_rrdvalues(char *out, int outlen, time_t tstamp,
                               double median, double lossfrac,
                               const double *sorted_samples, int received)
{
	int off, i, n;

	n = smokeping_sample_count();

	off = snprintf(out, outlen, "%d:", (int)tstamp);
	if (received > 0) {
		off += snprintf(out + off, outlen - off, "%.6f:%.6f", median, lossfrac);
	}
	else {
		off += snprintf(out + off, outlen - off, "U:%.6f", lossfrac);
	}
	for (i = 0; (i < n) && (off < outlen); i++) {
		if (i < received) {
			off += snprintf(out + off, outlen - off, ":%.6f", sorted_samples[i]);
		}
		else {
			off += snprintf(out + off, outlen - off, ":U");
		}
	}
	return off;
}
