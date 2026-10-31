/* Regression test for lib/metric.c: a metric sample, the rule that judges
 * it, and the batch that holds a report's samples.
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
 * The batch:
 *   - keeps its own copies of the strings, so a sample outlives the row
 *     buffer it was read from;
 *   - judging a set records the verdict on the set's first sample: colour
 *     and the rule that gave it;
 *   - a test's colour is the worst verdict among its samples, green when
 *     none; samples of other tests do not count;
 *   - clearing drops the samples and the batch can be filled again.
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
	metricbatch_t *b;
	char rowbuf[64];
	int i, j;

	metric_set(&s[0], "disk", "/var", "pct", 92, METRIC_OK);
	metric_set(&s[1], "disk", "/var", "free", 4000, METRIC_OK);

	expect("metric_set", (strcmp(s[0].test, "disk") == 0) && (strcmp(s[0].instance, "/var") == 0)
	       && (strcmp(s[0].name, "pct") == 0) && (s[0].value == 92) && (s[0].state == METRIC_OK)
	       && (s[0].phase == METRIC_NATIVE) && (s[0].color == COL_GREEN) && !s[0].judged,
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

	/* The batch keeps copies: the row buffer is overwritten after the add. */
	b = metric_batch_new();
	strcpy(rowbuf, "/var");
	i = metric_batch_add(b, "disk", rowbuf, "free", 4000, METRIC_OK);
	j = metric_batch_add(b, "disk", rowbuf, "pct", 92, METRIC_OK);
	strcpy(rowbuf, "/overwritten");
	expect("batch copies", (strcmp(metric_batch_sample(b, i)->instance, "/var") == 0)
	       && (strcmp(metric_batch_sample(b, j)->instance, "/var") == 0)
	       && (metric_batch_sample(b, i)->instance != rowbuf),
	       "a sample points at the caller's buffer instead of its own copy");
	expect("batch index", (i == 0) && (j == 1) && (b->count == 2), "indices or count are off after two adds");

	/* Judging a pair records the verdict on the first sample. */
	metric_rule(&r[0], "pct", METRIC_GE, 95, COL_RED);
	metric_rule(&r[1], "pct", METRIC_GE, 90, COL_YELLOW);
	expect("batch judge", metric_batch_judge(b, i, 2, r, 2) == COL_YELLOW, "the pair was not judged yellow");
	expect("batch verdict", metric_batch_sample(b, i)->judged && (metric_batch_sample(b, i)->color == COL_YELLOW)
	       && (metric_batch_sample(b, i)->hit.level == 90) && (metric_batch_sample(b, i)->hit.color == COL_YELLOW),
	       "the verdict on the first sample does not name the rule that tripped");
	expect("batch second untouched", !metric_batch_sample(b, j)->judged && (metric_batch_sample(b, j)->color == COL_GREEN),
	       "the verdict was written on the second sample");

	/* A test's colour is the worst verdict among its samples; other tests do not count. */
	i = metric_batch_add(b, "memory", NULL, "swap", 85, METRIC_OK);
	metric_rule(&r[0], "swap", METRIC_GT, 80, COL_RED);
	metric_batch_judge(b, i, 1, r, 1);
	expect("batch color", metric_batch_color(b, "disk") == COL_YELLOW, "disk is not the yellow of its mount");
	expect("batch color other", metric_batch_color(b, "memory") == COL_RED, "memory is not the red of its swap row");
	expect("batch color none", metric_batch_color(b, "cpu") == COL_GREEN, "a test with no samples is not green");

	/* A verdict set by hand counts too: a count sample coloured by its own check. */
	i = metric_batch_add(b, "cpu", "x", "count", 0, METRIC_OK);
	metric_batch_sample(b, i)->color = COL_RED;
	expect("batch hand colour", metric_batch_color(b, "cpu") == COL_RED, "a colour set on a sample is not folded");

	/* Clearing drops everything and the batch takes samples again. */
	metric_batch_clear(b);
	expect("batch clear", (b->count == 0) && (metric_batch_color(b, "disk") == COL_GREEN), "clearing left samples behind");
	i = metric_batch_add(b, "disk", "/", "pct", 1, METRIC_OK);
	expect("batch reuse", (i == 0) && (b->count == 1), "the cleared batch did not take a sample at index 0");
	metric_batch_free(b);

	/* Growth: more samples than the first allocation, every one intact. */
	b = metric_batch_new();
	for (i = 0; (i < 1000); i++) {
		char name[16];
		sprintf(name, "m%d", i);
		metric_batch_add(b, "many", name, "v", (double)i, METRIC_OK);
	}
	for (i = 0; (i < 1000); i++) {
		char name[16];
		sprintf(name, "m%d", i);
		if ((metric_batch_sample(b, i)->value != (double)i) || (strcmp(metric_batch_sample(b, i)->instance, name) != 0)) break;
	}
	expect("batch growth", (i == 1000) && (b->count == 1000), "a sample was lost or changed when the batch grew");
	metric_batch_free(b);

	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	return 0;
}
