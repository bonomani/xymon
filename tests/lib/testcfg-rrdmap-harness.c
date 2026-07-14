/* test.cfg overlays the TEST2RRD column->RRD mapping: a single-metric TEST
 * binds its column to that metric, overriding the env for the same column
 * and adding new ones, while columns with no section fall back to the env. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

static int failures = 0;

static void expect_rrd(const char *service, const char *want)
{
	xymonrrd_t *r = find_xymon_rrd((char *)service, NULL);
	const char *got = r ? r->xymonrrdname : "(none)";
	if (!r || strcmp(r->xymonrrdname, want)) {
		fprintf(stderr, "FAIL: %s -> %s, wanted %s\n", service, got, want);
		failures++;
	}
}

int main(void)
{
	/* TEST2RRD env: http maps to tcp, cpu to la. test.cfg then overrides
	 * cpu (to cpu2) and adds a fresh column diskquick (-> diskfam). */
	expect_rrd("http", "tcp");          /* env only, no test.cfg section: fallback */
	expect_rrd("cpu", "cpu2");          /* test.cfg overrides env "cpu=la" */
	expect_rrd("diskquick", "diskfam"); /* test.cfg adds a column absent from env */

	/* A multi-metric test binds no single RRD name: it must NOT create a
	 * mapping (diskio stays unmapped -> find returns its own name only if
	 * env had it; here env doesn't, so find returns NULL). */
	if (find_xymon_rrd("diskio", NULL) != NULL) {
		fprintf(stderr, "FAIL: multi-metric test wrongly mapped diskio\n");
		failures++;
	}

	printf(failures ? "FAILED\n" : "ALL OK\n");
	return failures ? 1 : 0;
}
