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
/* Copyright (C) 2026 Bruno Manzoni                                           */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

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
