/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* A metric sample: one number a client analyser measured, with the identity  */
/* a rule addresses it by, the rule that judges it, and the batch that holds  */
/* every sample of one report.                                                */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                           */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#ifndef __METRIC_H__
#define __METRIC_H__

/* What the sample's value means. A rule compares an OK sample only: a value
 * nothing measured, or one the analyser does not believe (a percentage over
 * 100 where none is possible), is a state, not a number, and comparing it
 * would turn an absent or broken measurement into a colour. */
typedef enum { METRIC_OK, METRIC_UNMEASURED, METRIC_INVALID } metricstate_t;

/* Where the sample was read. Native is the client report as xymond_client
 * parses it; stored is a dataset on its way into an RRD file, the same
 * number again later, which is what lets one judge tell the two apart. */
typedef enum { METRIC_NATIVE, METRIC_STORED } metricphase_t;

/* How a rule compares. The keywords in analysis.cfg use all four: DISK is
 * at or above a percent and at or below a units-free figure, LOAD and MEM*
 * are strictly above, UP is strictly below the recent-reboot limit. */
typedef enum { METRIC_GE, METRIC_GT, METRIC_LE, METRIC_LT } metricop_t;

/* One condition on one named metric, and the colour it gives. */
typedef struct metricrule_t {
	char *name;
	metricop_t op;
	double level;
	int color;
} metricrule_t;

typedef struct metricsample_t {
	char *test;		/* the status it feeds: "disk" */
	char *instance;		/* the measured object: a mount point; NULL where the test has one */
	char *name;		/* what was measured: "pct", "free" */
	double value;		/* a load average is not an integer */
	metricstate_t state;
	metricphase_t phase;

	/* The verdict, once judged: the colour, and a copy of the rule that
	 * gave it, so the renderer can name the level that was passed. A sample
	 * that was never judged, or that nothing tripped, is COL_GREEN. */
	int color;
	int judged;		/* a rule tripped: hit is meaningful */
	metricrule_t hit;

	void *data;		/* the analyser's own: a rule's alert group, say */
} metricsample_t;

/* Every sample of one client report, in the order the analysers measured
 * them: the renderer walks a test's samples in table order. The batch owns
 * copies of the strings, since an analyser's row buffer is gone before the
 * status is written. */
typedef struct metricbatch_t {
	metricsample_t *samples;
	int count, size;
} metricbatch_t;

extern void metric_set(metricsample_t *s, char *test, char *instance, char *name, double value, metricstate_t state);
extern void metric_rule(metricrule_t *r, char *name, metricop_t op, double level, int color);
extern int metric_trips(metricsample_t *s, metricrule_t *r);
extern int metric_judge(metricsample_t *samples, int nsamples, metricrule_t *rules, int nrules, metricrule_t **tripped);

extern metricbatch_t *metric_batch_new(void);
extern void metric_batch_clear(metricbatch_t *b);
extern void metric_batch_free(metricbatch_t *b);
extern int metric_batch_add(metricbatch_t *b, char *test, char *instance, char *name, double value, metricstate_t state);
extern metricsample_t *metric_batch_sample(metricbatch_t *b, int idx);
extern int metric_batch_judge(metricbatch_t *b, int first, int nsamples, metricrule_t *rules, int nrules);
extern int metric_batch_color(metricbatch_t *b, char *test);

#endif
