/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* A metric sample: one number a client analyser measured, with the identity  */
/* a rule addresses it by, and the rule that judges it. The analysers in      */
/* xymond_client parsed a value, compared it and formatted the line in one    */
/* breath, each with its own copy of the comparison; this is the one copy,    */
/* so every analyser judges the way every other does, and a value is a thing  */
/* that can be named, stored and judged once rather than a local variable.    */
/*                                                                            */
/* The batch is where a report's samples live between being measured and     */
/* being rendered: the analyser adds and judges, the status is written from   */
/* what the batch holds, and whatever comes after -- storage, a block on the  */
/* wire -- reads the same samples instead of parsing the text again.         */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                           */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

void metric_set(metricsample_t *s, char *test, char *instance, char *name, double value, metricstate_t state)
{
	s->test = test;
	s->instance = instance;
	s->name = name;
	s->value = value;
	s->state = state;
	s->phase = METRIC_NATIVE;
	s->color = COL_GREEN;
	s->judged = 0;
	s->data = NULL;
}

void metric_rule(metricrule_t *r, char *name, metricop_t op, double level, int color)
{
	r->name = name;
	r->op = op;
	r->level = level;
	r->color = color;
}

/* Does the rule's condition hold on this sample? Only a sample of the metric
 * the rule names, and only one that was measured: an unmeasured or invalid
 * sample trips nothing, whatever value it carries. */
int metric_trips(metricsample_t *s, metricrule_t *r)
{
	if (s->state != METRIC_OK) return 0;
	if (strcmp(s->name, r->name) != 0) return 0;

	switch (r->op) {
	  case METRIC_GE: return (s->value >= r->level);
	  case METRIC_GT: return (s->value >  r->level);
	  case METRIC_LE: return (s->value <= r->level);
	  case METRIC_LT: return (s->value <  r->level);
	}

	return 0;
}

/* The colour of a set of samples under a set of rules: the worst colour of
 * any rule that trips, COL_GREEN when none does. *tripped, when given, names
 * the rule that gave the colour -- the first in rule order among those of
 * that colour, so a caller may put the rules it wants reported first. */
int metric_judge(metricsample_t *samples, int nsamples, metricrule_t *rules, int nrules, metricrule_t **tripped)
{
	int color = COL_GREEN;
	int i, j;

	if (tripped) *tripped = NULL;

	for (i = 0; (i < nrules); i++) {
		if (rules[i].color <= color) continue;
		for (j = 0; (j < nsamples); j++) {
			if (metric_trips(&samples[j], &rules[i])) {
				color = rules[i].color;
				if (tripped) *tripped = &rules[i];
				break;
			}
		}
	}

	return color;
}

metricbatch_t *metric_batch_new(void)
{
	metricbatch_t *b = (metricbatch_t *)calloc(1, sizeof(metricbatch_t));

	return b;
}

/* Drop the samples and keep the storage: one batch serves every report a
 * process handles. */
void metric_batch_clear(metricbatch_t *b)
{
	int i;

	for (i = 0; (i < b->count); i++) {
		if (b->samples[i].test) xfree(b->samples[i].test);
		if (b->samples[i].instance) xfree(b->samples[i].instance);
		if (b->samples[i].name) xfree(b->samples[i].name);
	}
	b->count = 0;
}

void metric_batch_free(metricbatch_t *b)
{
	metric_batch_clear(b);
	if (b->samples) xfree(b->samples);
	xfree(b);
}

/* Add a sample and return its index. An index, not a pointer: the array
 * grows, and a pointer taken before the next add would dangle. */
int metric_batch_add(metricbatch_t *b, char *test, char *instance, char *name, double value, metricstate_t state)
{
	metricsample_t *s;

	if (b->count == b->size) {
		b->size = (b->size ? 2*b->size : 64);
		b->samples = (metricsample_t *)realloc(b->samples, b->size * sizeof(metricsample_t));
	}

	s = &b->samples[b->count];
	metric_set(s, (test ? strdup(test) : NULL), (instance ? strdup(instance) : NULL), (name ? strdup(name) : NULL), value, state);

	return b->count++;
}

metricsample_t *metric_batch_sample(metricbatch_t *b, int idx)
{
	return (((idx >= 0) && (idx < b->count)) ? &b->samples[idx] : NULL);
}

/* Judge nsamples consecutive samples from first as one set -- a mount's
 * percent and units free under its DISK rule -- and record the verdict on
 * the first of them: its colour, and the rule that gave it. */
int metric_batch_judge(metricbatch_t *b, int first, int nsamples, metricrule_t *rules, int nrules)
{
	metricrule_t *hit = NULL;
	metricsample_t *s = metric_batch_sample(b, first);

	if (!s || ((first + nsamples) > b->count)) return COL_GREEN;

	s->color = metric_judge(s, nsamples, rules, nrules, &hit);
	s->judged = (hit != NULL);
	if (hit) s->hit = *hit;

	return s->color;
}

/* The colour of a test: the worst verdict among its samples, COL_GREEN
 * when none was judged above it. This is the fold where every sample of a
 * test counts the same; a test that weighs them otherwise folds by hand. */
int metric_batch_color(metricbatch_t *b, char *test)
{
	int color = COL_GREEN;
	int i;

	for (i = 0; (i < b->count); i++) {
		if (b->samples[i].test && (strcmp(b->samples[i].test, test) == 0) && (b->samples[i].color > color))
			color = b->samples[i].color;
	}

	return color;
}
