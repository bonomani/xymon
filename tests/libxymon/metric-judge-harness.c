/* Regression test for lib/metric.c: a metric sample and the rule that
 * judges it.
 *
 * metric_judge() is the one comparison the client analysers share, so what
 * it promises is pinned here rather than in each analyser's status text:
 *   - a rule trips at or above its level (METRIC_GE), strictly above
 *     (METRIC_GT), at or below (METRIC_LE) or strictly below (METRIC_LT),
 *     on a sample of the metric the rule names and no other;
 *   - the colour of a set of samples is the worst colour of any rule that
 *     trips, green when none does, and the rule reported is the first in
 *     rule order among those of that colour;
 *   - an unmeasured or invalid sample trips nothing, whatever value it
 *     carries;
 *   - a value is real: a load average of 5.5 is above 5 and not above 5.5.
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
	metric_rule(&r[0], "pct", METRIC_GE, 90, COL_YELLOW);
	expect("ge above", metric_trips(&s[0], &r[0]), "92 >= 90 did not trip");
	metric_rule(&r[0], "pct", METRIC_GE, 92, COL_YELLOW);
	expect("ge at", metric_trips(&s[0], &r[0]), "92 >= 92 did not trip");
	metric_rule(&r[0], "pct", METRIC_GE, 93, COL_YELLOW);
	expect("ge under", !metric_trips(&s[0], &r[0]), "92 >= 93 tripped");

	/* Strictly above: at the level does not trip. */
	metric_rule(&r[0], "pct", METRIC_GT, 92, COL_YELLOW);
	expect("gt at", !metric_trips(&s[0], &r[0]), "92 > 92 tripped");
	metric_rule(&r[0], "pct", METRIC_GT, 91, COL_YELLOW);
	expect("gt above", metric_trips(&s[0], &r[0]), "92 > 91 did not trip");

	/* At or below, and strictly below, on the units-free metric. */
	metric_rule(&r[0], "free", METRIC_LE, 4000, COL_RED);
	expect("le at", metric_trips(&s[1], &r[0]), "4000 <= 4000 did not trip");
	metric_rule(&r[0], "free", METRIC_LE, 3999, COL_RED);
	expect("le over", !metric_trips(&s[1], &r[0]), "4000 <= 3999 tripped");
	metric_rule(&r[0], "free", METRIC_LT, 4000, COL_RED);
	expect("lt at", !metric_trips(&s[1], &r[0]), "4000 < 4000 tripped");
	metric_rule(&r[0], "free", METRIC_LT, 4001, COL_RED);
	expect("lt under", metric_trips(&s[1], &r[0]), "4000 < 4001 did not trip");

	/* A real value: a load of 5.5 is above 5 and not above 5.5. */
	metric_set(&s[0], "cpu", NULL, "load", 5.5, METRIC_OK);
	metric_rule(&r[0], "load", METRIC_GT, 5, COL_YELLOW);
	expect("real above", metric_trips(&s[0], &r[0]), "5.5 > 5 did not trip");
	metric_rule(&r[0], "load", METRIC_GT, 5.5, COL_YELLOW);
	expect("real at", !metric_trips(&s[0], &r[0]), "5.5 > 5.5 tripped");
	metric_set(&s[0], "disk", "/var", "pct", 92, METRIC_OK);

	/* A rule names one metric: the pct sample does not answer a free rule. */
	metric_rule(&r[0], "free", METRIC_GE, 100, COL_RED);
	expect("name", !metric_trips(&s[0], &r[0]), "a free rule tripped on the pct sample");

	/* Worst colour wins, whatever the rule order. */
	metric_rule(&r[0], "pct", METRIC_GE, 90, COL_YELLOW);
	metric_rule(&r[1], "pct", METRIC_GE, 91, COL_RED);
	expect("worst", metric_judge(s, 2, r, 2, &hit) == COL_RED, "yellow first in order was not outranked by red");
	expect("worst hit", hit == &r[1], "the reported rule is not the red one");

	/* Nothing trips: green, and no rule reported. */
	metric_rule(&r[0], "pct", METRIC_GE, 95, COL_YELLOW);
	metric_rule(&r[1], "free", METRIC_LE, 1000, COL_RED);
	hit = &r[0];
	expect("green", metric_judge(s, 2, r, 2, &hit) == COL_GREEN, "a set with no tripping rule is not green");
	expect("green hit", hit == NULL, "a rule was reported with nothing tripping");

	/* Two rules of the same colour trip: the first in rule order is reported. */
	metric_rule(&r[0], "free", METRIC_LE, 5000, COL_RED);
	metric_rule(&r[1], "pct", METRIC_GE, 90, COL_RED);
	expect("first", (metric_judge(s, 2, r, 2, &hit) == COL_RED) && (hit == &r[0]),
	       "two red rules tripping did not report the first in order");

	/* An unmeasured sample trips nothing: the 0 a "-" reads as is not a value. */
	metric_set(&s[1], "disk", "/mnt/hung", "free", 0, METRIC_UNMEASURED);
	metric_rule(&r[0], "free", METRIC_LE, 1000, COL_RED);
	expect("unmeasured", !metric_trips(&s[1], &r[0]), "an unmeasured sample tripped a rule");
	expect("unmeasured judge", metric_judge(&s[1], 1, r, 1, NULL) == COL_GREEN, "an unmeasured sample coloured the set");

	/* An invalid sample is a state too: a percentage the analyser does not believe. */
	metric_set(&s[1], "memory", NULL, "swap", 250, METRIC_INVALID);
	metric_rule(&r[0], "swap", METRIC_GT, 80, COL_RED);
	expect("invalid", !metric_trips(&s[1], &r[0]), "an invalid sample tripped a rule");

	/* A tripped pointer may be left out. */
	metric_rule(&r[0], "pct", METRIC_GE, 90, COL_YELLOW);
	expect("no hit pointer", metric_judge(s, 1, r, 1, NULL) == COL_YELLOW, "judging without a tripped pointer failed");

	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	return 0;
}
