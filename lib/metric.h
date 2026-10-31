/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* A metric sample: one number a client analyser measured, with the identity  */
/* a rule addresses it by, and the rule that judges it.                       */
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

/* Where the sample was read. The native phase is the client report parsed by
 * xymond_client; a value read back from a status or an RRD file is another
 * phase of the same number, and the field is what lets one judge tell them
 * apart instead of judging each. Only the native phase exists today. */
typedef enum { METRIC_NATIVE } metricphase_t;

typedef struct metricsample_t {
	char *test;		/* the status it feeds: "disk" */
	char *instance;		/* the measured object: a mount point; NULL where the test has one */
	char *name;		/* what was measured: "pct", "free" */
	double value;		/* a load average is not an integer */
	metricstate_t state;
	metricphase_t phase;
} metricsample_t;

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

extern void metric_set(metricsample_t *s, char *test, char *instance, char *name, double value, metricstate_t state);
extern void metric_rule(metricrule_t *r, char *name, metricop_t op, double level, int color);
extern int metric_trips(metricsample_t *s, metricrule_t *r);
extern int metric_judge(metricsample_t *samples, int nsamples, metricrule_t *rules, int nrules, metricrule_t **tripped);

#endif
