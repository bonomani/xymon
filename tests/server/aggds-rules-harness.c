/* AGGDS aggregate rules: sum/avg/max/min/count over the latest stored
 * values of a metric set, evaluated per host with first-match shadowing
 * and a freshness window. Drives the real analysis.cfg parser, store and
 * checker from client_config.c. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <utime.h>

#include "libxymon.h"
#include "client_config.h"

/* load_client_config() skips the reload when the previously loaded file
 * is unmodified - bump a file's mtime into the future to defeat that. */
static void touch_future(const char *path, int offset)
{
	struct utimbuf t;

	t.actime = t.modtime = time(NULL) + offset;
	utime(path, &t);
}

static int failures = 0;

static void expect(const char *label, const char *text, const char *needle, int want)
{
	int have = (text && strstr(text, needle) != NULL);

	if (have != want) {
		fprintf(stderr, "%s: '%s' %s in:\n%s\n", label, needle,
			(want ? "missing" : "unexpected"), (text ? text : "(null)"));
		failures++;
	}
}

/* Build a dsnames tree the way setup_template() does */
static void *mktree(const char *ds1, const char *ds2)
{
	void *tree = xtreeNew(strcmp);
	rrdtplnames_t *tpl;

	tpl = (rrdtplnames_t *)calloc(1, sizeof(rrdtplnames_t));
	tpl->dsnam = strdup(ds1); tpl->idx = 1;
	xtreeAdd(tree, tpl->dsnam, tpl);
	if (ds2) {
		tpl = (rrdtplnames_t *)calloc(1, sizeof(rrdtplnames_t));
		tpl->dsnam = strdup(ds2); tpl->idx = 2;
		xtreeAdd(tree, tpl->dsnam, tpl);
	}
	return tree;
}

int main(void)
{
	void *opstree = mktree("reads", "writes");
	char vals[128];
	time_t now = getcurrenttime(NULL);
	strbuffer_t *res;
	char *out;

	{
		/* "!" forces a file load - a bare $HOSTSCFG path detours
		 * through a xymond network query first */
		char hostsfn[1024];
		snprintf(hostsfn, sizeof(hostsfn), "!%s", getenv("HOSTSCFG"));
		load_hostnames(hostsfn, NULL, get_fqdn());
	}
	load_client_config(NULL);

	/* Three fresh instances: reads 10+5+118=133, writes 20+6+302=328 */
	snprintf(vals, sizeof(vals), "%d:10:20", (int)now);
	update_aggds_store("testhost", "diskio_ops.ada0.rrd", opstree, vals);
	snprintf(vals, sizeof(vals), "%d:5:6", (int)now);
	update_aggds_store("testhost", "diskio_ops.ada1.rrd", opstree, vals);
	snprintf(vals, sizeof(vals), "%d:118:302", (int)now);
	update_aggds_store("testhost", "diskio_ops.da0.rrd", opstree, vals);
	/* A stale instance, last updated an hour ago: excluded everywhere */
	snprintf(vals, sizeof(vals), "%d:1000:1000", (int)(now - 3600));
	update_aggds_store("testhost", "diskio_ops.gone.rrd", opstree, vals);
	/* An unrelated file that must not match the pattern */
	snprintf(vals, sizeof(vals), "%d:5000:5000", (int)now);
	update_aggds_store("testhost", "other_metric.x.rrd", opstree, vals);

	res = check_aggds_thresholds("testhost", "linux", "/");
	out = (res ? STRBUF(res) : NULL);

	/* sum(reads)=133 > 100 -> yellow; the stale and unrelated values
	 * (1000/5000) must not be inside, or the sum would differ */
	expect("sum over fresh matching values", out, "modify testhost.diskio yellow aggds:sum(reads) Total reads high: 133.00", 1);
	/* A second aggregate on the SAME column gets its own modify source,
	 * so the two do not clobber each other in xymond's modifier list */
	expect("per-aggregate modify source", out, "modify testhost.diskio yellow aggds:max(reads) Max read 118.00", 1);
	/* count(reads)=3 (stale excluded), rule is < 3 -> no red modify */
	expect("count excludes stale instances", out, "modify testhost.diskio red", 0);
	/* max(writes)=302 > 250 -> yellow on another column, default text */
	expect("max with default status text", out, "modify testhost.diskio2 yellow aggds:max(writes) max(writes)=302.00 (> 250.00)", 1);
	/* avg(reads)=44.33 not > 100 -> nothing for diskio3 */
	expect("avg below threshold stays quiet", out, "diskio3", 0);
	/* first-match shadowing: the second, tighter sum rule for the same
	 * column+aggregate+color is shadowed even though it would match */
	expect("first match wins per column/aggregate/color", out, "SHADOWED", 0);

	/* A host with no stored values: no result at all */
	res = check_aggds_thresholds("otherhost", "linux", "/");
	expect("no data, no modifies", (res ? STRBUF(res) : NULL), "modify", 0);

	/* Dropping a host empties its slice of the store: no aggregates
	 * linger, and repopulating afterwards works. */
	flush_aggds_store("testhost");
	res = check_aggds_thresholds("testhost", "linux", "/");
	expect("flushed host has no modifies", (res ? STRBUF(res) : NULL), "modify", 0);
	snprintf(vals, sizeof(vals), "%d:200:1", (int)now);
	update_aggds_store("testhost", "diskio_ops.ada0.rrd", opstree, vals);
	res = check_aggds_thresholds("testhost", "linux", "/");
	expect("store repopulates after a flush", (res ? STRBUF(res) : NULL), "Total reads high: 200.00", 1);

	/* A reload that removes every AGGDS rule tears the store down; a
	 * later reload with rules starts from scratch and works. */
	{
		char cfgpath[1024];
		snprintf(cfgpath, sizeof(cfgpath), "%s/etc/analysis.cfg", getenv("XYMONHOME"));
		touch_future(cfgpath, 10);
	}
	load_client_config(getenv("EMPTYCFG"));
	update_aggds_store("testhost", "diskio_ops.ada0.rrd", opstree, vals);
	res = check_aggds_thresholds("testhost", "linux", "/");
	expect("no rules, no store, no modifies", (res ? STRBUF(res) : NULL), "modify", 0);
	touch_future(getenv("EMPTYCFG"), 20);
	load_client_config(NULL);
	snprintf(vals, sizeof(vals), "%d:150:1", (int)now);
	update_aggds_store("testhost", "diskio_ops.ada0.rrd", opstree, vals);
	res = check_aggds_thresholds("testhost", "linux", "/");
	expect("store rebuilt after rules return", (res ? STRBUF(res) : NULL), "Total reads high: 150.00", 1);

	printf(failures ? "FAILED\n" : "ALL OK\n");
	return failures ? 1 : 0;
}
