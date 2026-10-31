/* Regression test for lib/metric.c: a metric sample and the rule that
 * judges it.
 *
 * metric_judge() is the one comparison the client analysers share, so what
 * it promises is pinned here rather than in each analyser's status text:
 *   - a rule trips at or above its level, or at or below it with "below"
 *     set, on a sample of the metric the rule names and no other;
 *   - the colour of a set of samples is the worst colour of any rule that
 *     trips, green when none does, and the rule reported is the first in
 *     rule order among those of that colour;
 *   - an unmeasured sample trips nothing, whatever value it carries.
 *
 * Driven through the library's public interface only.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

static int failures = 0;

static void expect(const char *label, int cond, const char *detail)
{
	if (!cond) {
		fprintf(stderr, "%s: %s\n", label, detail);
		failures++;
	}
}

static void rule(metricrule_t *r, char *name, long level, int below, int color)
{
	r->name = name; r->level = level; r->below = below; r->color = color;
}

int main(int argc, char *argv[])
{
	metricsample_t s[2];
	metricrule_t r[3], *hit;

	metric_set(&s[0], "disk", "/var", "pct", 92, METRIC_OK);
	metric_set(&s[1], "disk", "/var", "free", 4000, METRIC_OK);

	expect("metric_set", (strcmp(s[0].test, "disk") == 0) && (strcmp(s[0].instance, "/var") == 0)
	       && (strcmp(s[0].name, "pct") == 0) && (s[0].value == 92) && (s[0].state == METRIC_OK)
	       && (s[0].phase == METRIC_NATIVE),
	       "the sample does not carry what it was set to");

	/* At or above: 92 against 90 trips, against 92 trips, against 93 does not. */
	rule(&r[0], "pct", 90, 0, COL_YELLOW);
	expect("above", metric_trips(&s[0], &r[0]), "92 >= 90 did not trip");
	rule(&r[0], "pct", 92, 0, COL_YELLOW);
	expect("at", metric_trips(&s[0], &r[0]), "92 >= 92 did not trip");
	rule(&r[0], "pct", 93, 0, COL_YELLOW);
	expect("under", !metric_trips(&s[0], &r[0]), "92 >= 93 tripped");

	/* At or below, on the units-free metric. */
	rule(&r[0], "free", 4000, 1, COL_RED);
	expect("below at", metric_trips(&s[1], &r[0]), "4000 <= 4000 did not trip");
	rule(&r[0], "free", 3999, 1, COL_RED);
	expect("below over", !metric_trips(&s[1], &r[0]), "4000 <= 3999 tripped");

	/* A rule names one metric: the pct sample does not answer a free rule. */
	rule(&r[0], "free", 100, 0, COL_RED);
	expect("name", !metric_trips(&s[0], &r[0]), "a free rule tripped on the pct sample");

	/* Worst colour wins, whatever the rule order. */
	rule(&r[0], "pct", 90, 0, COL_YELLOW);
	rule(&r[1], "pct", 91, 0, COL_RED);
	expect("worst", metric_judge(s, 2, r, 2, &hit) == COL_RED, "yellow first in order was not outranked by red");
	expect("worst hit", hit == &r[1], "the reported rule is not the red one");

	/* Nothing trips: green, and no rule reported. */
	rule(&r[0], "pct", 95, 0, COL_YELLOW);
	rule(&r[1], "free", 1000, 1, COL_RED);
	hit = &r[0];
	expect("green", metric_judge(s, 2, r, 2, &hit) == COL_GREEN, "a set with no tripping rule is not green");
	expect("green hit", hit == NULL, "a rule was reported with nothing tripping");

	/* Two rules of the same colour trip: the first in rule order is reported. */
	rule(&r[0], "free", 5000, 1, COL_RED);
	rule(&r[1], "pct", 90, 0, COL_RED);
	expect("first", (metric_judge(s, 2, r, 2, &hit) == COL_RED) && (hit == &r[0]),
	       "two red rules tripping did not report the first in order");

	/* An unmeasured sample trips nothing: the 0 a "-" reads as is not a value. */
	metric_set(&s[1], "disk", "/mnt/hung", "free", 0, METRIC_UNMEASURED);
	rule(&r[0], "free", 1000, 1, COL_RED);
	expect("unmeasured", !metric_trips(&s[1], &r[0]), "an unmeasured sample tripped a rule");
	expect("unmeasured judge", metric_judge(&s[1], 1, r, 1, NULL) == COL_GREEN, "an unmeasured sample coloured the set");

	/* A tripped pointer may be left out. */
	rule(&r[0], "pct", 90, 0, COL_YELLOW);
	expect("no hit pointer", metric_judge(s, 1, r, 1, NULL) == COL_YELLOW, "judging without a tripped pointer failed");

	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	return 0;
}
