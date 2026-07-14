/* test.cfg braced-config parser: parse the RFC's worked example and assert
 * the TEST -> METRIC -> backend model, plus grammar edge cases (inline vs
 * block bodies, comments, quotes, ';' vs newline, nested backends). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

static int failures = 0;

static void ck(const char *label, int cond)
{
	if (!cond) { fprintf(stderr, "FAIL: %s\n", label); failures++; }
}

static const char *CFG =
	"# a comment line\n"
	"TEST cpu    { SOURCE client; METRIC la }\n"
	"TEST disk   { SOURCE client; METRIC disk { COUNTLINES } }\n"
	"TEST smtp {\n"
	"        SOURCE network\n"
	"        PORT   25\n"
	"        METRIC tcp\n"
	"}\n"
	"TEST diskio {\n"
	"        SOURCE   script\n"
	"        CMD      \"/path with spaces/diskio.py\"   # quoted, has spaces\n"
	"        INTERVAL 5m\n"
	"        METRIC diskio_ops     { LAZY; EXCLUDE loop }\n"
	"        METRIC diskio_busy    { LAZY; STOREPATTERN ,root }\n"
	"        METRIC diskio_total {\n"
	"                RRD      { LAZY }\n"
	"                GRAPHITE { PREFIX servers.disk }\n"
	"        }\n"
	"}\n"
	"TEST storage {\n"
	"        SOURCE  script\n"
	"        HANDLER markers\n"
	"        GRAPHS  storage_io\n"
	"        METRIC  storage_io { LAZY }\n"
	"}\n"
	"TEST trends { SOURCE server }\n";

int main(void)
{
	char err[200];
	tc_test_t *tests, *t;
	tc_metric_t *m;
	tc_backend_t *b;

	tests = testcfg_parse(CFG, err, sizeof(err));
	ck("parse succeeds", tests != NULL);
	if (!tests) { fprintf(stderr, "parse error: %s\n", err); return 1; }

	/* cpu: inline block, one metric, no storage */
	t = testcfg_find(tests, "cpu");
	ck("cpu found", t != NULL);
	ck("cpu source client", t && t->source && strcmp(t->source, "client") == 0);
	ck("cpu has metric la", testcfg_metric(t, "la") != NULL);

	/* disk: metric with a COUNTLINES flag */
	t = testcfg_find(tests, "disk");
	m = testcfg_metric(t, "disk");
	ck("disk.disk countlines", m && m->countlines);

	/* smtp: block-body verbs, port kept */
	t = testcfg_find(tests, "smtp");
	ck("smtp source network", t && t->source && strcmp(t->source, "network") == 0);
	ck("smtp port 25", t && t->port && strcmp(t->port, "25") == 0);
	ck("smtp metric tcp", testcfg_metric(t, "tcp") != NULL);

	/* diskio: quoted CMD with spaces; per-metric storage on the default backend */
	t = testcfg_find(tests, "diskio");
	ck("diskio quoted cmd", t && t->cmd && strcmp(t->cmd, "/path with spaces/diskio.py") == 0);
	ck("diskio interval", t && t->interval && strcmp(t->interval, "5m") == 0);

	m = testcfg_metric(t, "diskio_ops");
	b = testcfg_backend(m, NULL);   /* default rrd */
	ck("ops lazy", b && b->lazy);
	ck("ops exclude loop", b && b->excludepat && strcmp(b->excludepat, "loop") == 0);

	m = testcfg_metric(t, "diskio_busy");
	b = testcfg_backend(m, NULL);
	ck("busy lazy", b && b->lazy);
	ck("busy storepattern ,root", b && b->storepat && strcmp(b->storepat, ",root") == 0);
	ck("busy has no exclude", b && b->excludepat == NULL);

	/* diskio_total: two explicit backend blocks */
	m = testcfg_metric(t, "diskio_total");
	ck("total has rrd backend", testcfg_backend(m, "rrd") != NULL);
	ck("total rrd lazy", testcfg_backend(m, "rrd") && testcfg_backend(m, "rrd")->lazy);
	b = testcfg_backend(m, "graphite");
	ck("total has graphite backend", b != NULL);
	ck("total graphite raw kv kept", b && b->nkv >= 2 &&
	   strcasecmp(b->kv[0], "PREFIX") == 0 && strcmp(b->kv[1], "servers.disk") == 0);

	/* storage: overrides captured */
	t = testcfg_find(tests, "storage");
	ck("storage handler override", t && t->handler && strcmp(t->handler, "markers") == 0);
	ck("storage graphs override", t && t->graphs && strcmp(t->graphs, "storage_io") == 0);

	/* trends: pseudo-column, no metrics */
	t = testcfg_find(tests, "trends");
	ck("trends source server", t && t->source && strcmp(t->source, "server") == 0);
	ck("trends has no metrics", t && t->metrics == NULL);

	testcfg_free(tests);

	/* Syntax error: unbalanced brace is reported, not crashed. */
	ck("unbalanced brace fails", testcfg_parse("TEST x { SOURCE client", err, sizeof(err)) == NULL);

	printf(failures ? "FAILED\n" : "ALL OK\n");
	return failures ? 1 : 0;
}
