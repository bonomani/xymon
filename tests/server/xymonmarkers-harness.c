/*
 * tests/server/xymonmarkers-harness.c
 *
 * Unit tests for lib/xymonmarkers.c, the parser for the XYMON METRICS,
 * XYMON GRAPH and legacy DEVMON RRD markers a status message carries.
 * Run by tests/server/xymonmarkers.sh, linked against libxymoncomm.a.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

static int failures = 0;

static void expect_int(const char *label, int got, int want)
{
	if (got != want) {
		fprintf(stderr, "FAIL %s: got %d, want %d\n", label, got, want);
		failures++;
	}
}

static void expect_str(const char *label, const char *got, const char *want)
{
	if ((got == NULL) != (want == NULL) || (got && strcmp(got, want))) {
		fprintf(stderr, "FAIL %s: got %s, want %s\n", label,
			got ? got : "(null)", want ? want : "(null)");
		failures++;
	}
}

/* xymon_metrics_marker(): 0 = not a marker, 1 = unnamed, 2 = named. */
static void banner(const char *label, char *line, int want, const char *wantname)
{
	char *name = NULL;
	int got = xymon_metrics_marker(line, &name);

	expect_int(label, got, want);
	expect_str(label, name, wantname);
	if (name) xfree(name);
}

static xymonmarker_t *find(xymonmarker_t *head, const char *name)
{
	for (; head; head = head->next) if (strcmp(head->name, name) == 0) return head;
	return NULL;
}

int main(void)
{
	xymonmarker_t *head, *m;
	char msg[2048];

	banner("bare", "<!--XYMON METRICS\n", 1, NULL);
	banner("self-closed", "<!--XYMON METRICS-->", 1, NULL);
	banner("named", "<!--XYMON METRICS: disk\n", 2, "disk");
	banner("named, blank", "<!--XYMON METRICS disk\n", 2, "disk");
	banner("colon only", "<!--XYMON METRICS:\n", 1, NULL);
	banner("glued word", "<!--XYMON METRICSFOO\n", 0, NULL);
	banner("bad name", "<!--XYMON METRICS: a/b\n", 0, NULL);
	banner("other marker", "<!--XYMON GRAPH: disk -->", 0, NULL);
	/* CRLF line ends: a CR before the newline ends the banner like the
	 * newline does; a CR inside a word is no line end. */
	banner("bare, CRLF", "<!--XYMON METRICS\r\n", 1, NULL);
	banner("colon only, CRLF", "<!--XYMON METRICS:\r\n", 1, NULL);
	banner("named, CRLF", "<!--XYMON METRICS: disk\r\n", 2, "disk");
	banner("lone CR", "<!--XYMON METRICS\rFOO\n", 0, NULL);

	/* An unnamed block takes the test name. An instance line counts
	 * when it carries one value per declared DS; the instance is
	 * everything before the last field, so it may contain spaces. */
	strcpy(msg,
		"status text\n"
		"<!--XYMON METRICS\n"
		"DS:used:GAUGE:600:0:U DS:free:GAUGE:600:0:U\n"
		"THRESHOLD:used:>90:crit\n"
		"/ 10:20\n"
		"/media/My Book 30:40\n"
		"/short 1\n"
		"-->\n"
		"more text\n");
	head = xymon_markers_parse(msg, "disk");
	m = find(head, "disk");
	expect_int("unnamed block found", (m != NULL), 1);
	if (m) {
		expect_int("unnamed block stores", m->store, 1);
		expect_int("unnamed block shows", m->show, 0);
		expect_int("instances: keyword line and short line not counted", m->blockinstances, 2);
		expect_int("count from the block", xymon_marker_instancecount(m), 2);
	}
	xymon_markers_free(head);

	/* GRAPH: an attribute-only first token is not a name, so the graph
	 * defaults to the test; instances= wins over the block's count. */
	strcpy(msg,
		"<!--XYMON METRICS: disk\n"
		"DS:used:GAUGE:600:0:U\n"
		"/ 10\n"
		"/var 20\n"
		"-->\n"
		"<!--XYMON GRAPH instances=5 -->\n"
		"<!--XYMON GRAPH: cpu instances=all -->\n"
		"<!--XYMON GRAPH: la note_instances=4 -->\n");
	head = xymon_markers_parse(msg, "disk");
	m = find(head, "disk");
	expect_int("GRAPH merges into the test's marker", (m != NULL) && m->store && m->show, 1);
	if (m) expect_int("instances= wins", xymon_marker_instancecount(m), 5);
	m = find(head, "cpu");
	expect_int("named GRAPH", (m != NULL) && m->show && !m->store, 1);
	if (m) expect_int("instances=all", m->instancespec, 0);
	m = find(head, "la");
	if (m) expect_int("note_instances= is no instances=", m->instancespec, -1);
	else expect_int("GRAPH la found", 0, 1);
	xymon_markers_free(head);

	/* An unnamed GRAPH banner with a CRLF line end defaults to the test. */
	strcpy(msg, "status text\r\n<!--XYMON GRAPH\r\n");
	head = xymon_markers_parse(msg, "cpu");
	m = find(head, "cpu");
	expect_int("unnamed GRAPH, CRLF", (m != NULL) && m->show, 1);
	xymon_markers_free(head);

	/* An unclosed block is status text, not instances. */
	strcpy(msg,
		"<!--XYMON METRICS: disk\n"
		"DS:used:GAUGE:600:0:U\n"
		"/ 10\n");
	head = xymon_markers_parse(msg, "disk");
	m = find(head, "disk");
	if (m) expect_int("unclosed block counts nothing", m->blockinstances, 0);
	else expect_int("unclosed block found", 0, 1);
	xymon_markers_free(head);

	/* Legacy devmon banner: store and show. Keyword-looking instances
	 * ("CPU:1") are instances there, unlike in a METRICS block. */
	strcpy(msg,
		"<!--DEVMON RRD: if_load 0 0\n"
		"DS:in:GAUGE:600:0:U\n"
		"CPU:1 10\n"
		"eth0 20\n"
		"-->\n");
	head = xymon_markers_parse(msg, "if");
	m = find(head, "if_load");
	expect_int("DEVMON stores and shows", (m != NULL) && m->store && m->show, 1);
	if (m) expect_int("DEVMON counts keyword-like instances", m->blockinstances, 2);
	xymon_markers_free(head);

	/* The writer dispatch probe: only line-anchored, valid banners. */
	expect_int("have_store: METRICS", xymon_markers_have_store("a\n<!--XYMON METRICS: d\n-->\n"), 1);
	expect_int("have_store: unnamed", xymon_markers_have_store("<!--XYMON METRICS\n-->\n"), 1);
	expect_int("have_store: DEVMON", xymon_markers_have_store("<!--DEVMON RRD: x 0 0\n-->\n"), 1);
	expect_int("have_store: mid-line", xymon_markers_have_store("text <!--XYMON METRICS: d\n"), 0);
	expect_int("have_store: bad name", xymon_markers_have_store("<!--XYMON METRICS: a/b\n"), 0);
	expect_int("have_store: unnamed, CRLF", xymon_markers_have_store("<!--XYMON METRICS\r\n-->\r\n"), 1);
	expect_int("have_store: GRAPH only", xymon_markers_have_store("<!--XYMON GRAPH: d -->\n"), 0);

	/* A DEVMON banner the parser rejects still stores files, so the
	 * caller must keep its legacy rendering. */
	expect_int("devmon_unparsed: bad name", xymon_markers_devmon_unparsed("<!--DEVMON RRD: a/b 0 0\n-->\n"), 1);
	expect_int("devmon_unparsed: good name", xymon_markers_devmon_unparsed("<!--DEVMON RRD: ab 0 0\n-->\n"), 0);

	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	printf("ALL OK\n");
	return 0;
}
