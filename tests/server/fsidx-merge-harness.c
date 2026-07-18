/* Harness for the fileset index's two-writer schema merge (the g= field).
 * Two xymond_rrd processes (status- and data-channel) share one on-disk
 * index; schema fields merge by declaration timestamp so a stale writer
 * ADOPTS the newer bundle instead of ping-ponging its old copy back.
 * Drives the real filesetindex.c through its public API: seeds a host
 * tree from a hand-written file, mutates the file as "the other writer",
 * flushes, and prints the published lines for the shell to assert on.
 *
 * Usage: harness <rrddir> <scenario>
 *   adopt-newer   memory holds gen 100, disk changes to gen 200 -> adopt
 *   ignore-older  memory holds gen 200, disk regresses to gen 50 -> keep
 *   legacy-fill   no generations anywhere -> weak fill (old behavior)
 *   live-wins     live declaration outranks any on-disk generation
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include "libxymon.h"

static char *rrddir;

static void writeindex(const char *host, const char *content)
{
	char fn[PATH_MAX];
	FILE *fd;

	snprintf(fn, sizeof(fn), "%s/%s/.fileset-index", rrddir, host);
	fd = fopen(fn, "w");
	if (!fd) { perror(fn); exit(1); }
	fprintf(fd, "# xymon fileset index v1\n%s", content);
	fclose(fd);
}

static void dumpindex(const char *host)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[4096];

	snprintf(fn, sizeof(fn), "%s/%s/.fileset-index", rrddir, host);
	fd = fopen(fn, "r");
	if (!fd) { perror(fn); exit(1); }
	while (fgets(line, sizeof(line), fd)) if (line[0] != '#') fputs(line, stdout);
	fclose(fd);
}

int main(int argc, char *argv[])
{
	char *scenario;

	if (argc < 3) { fprintf(stderr, "usage: %s <rrddir> <scenario>\n", argv[0]); return 2; }
	rrddir = argv[1];
	scenario = argv[2];

	if (strcmp(scenario, "adopt-newer") == 0) {
		/* Seed memory from a gen-100 file (the stale writer's view),
		 * then "the other writer" publishes gen 200 with a changed
		 * spec. Our flush must adopt, not republish the stale spec. */
		writeindex("h1", "f.a.rrd 1000 u=v:ms h=v:600 g=100\n");
		fsidx_note_schema(rrddir, "h1", "f.a.rrd", 1000);	/* seeds the tree */
		writeindex("h1", "f.a.rrd 1500 u=v:msec h=v:300 g=200\n");
		fsidx_flush(rrddir, "h1");
		dumpindex("h1");
	}
	else if (strcmp(scenario, "ignore-older") == 0) {
		/* Memory holds the newer declaration; a regressed (older-gen)
		 * disk copy must not win the merge. */
		writeindex("h1", "f.a.rrd 1000 u=v:msec g=200\n");
		fsidx_note_schema(rrddir, "h1", "f.a.rrd", 1000);
		writeindex("h1", "f.a.rrd 1500 u=v:old g=50\n");
		fsidx_flush(rrddir, "h1");
		dumpindex("h1");
	}
	else if (strcmp(scenario, "legacy-fill") == 0) {
		/* Pre-g= files: equal (zero) generations weak-fill empty
		 * slots, exactly the old behavior. */
		writeindex("h1", "f.a.rrd 1000\n");
		fsidx_note_schema(rrddir, "h1", "f.a.rrd", 1000);
		writeindex("h1", "f.a.rrd 1500 u=v:legacy\n");
		fsidx_flush(rrddir, "h1");
		dumpindex("h1");
	}
	else if (strcmp(scenario, "live-wins") == 0) {
		/* A live declaration stamps the current time as generation,
		 * outranking anything a file can carry. */
		writeindex("h1", "f.a.rrd 1000 u=v:stale g=200\n");
		fsidx_set_units("v:live");
		fsidx_note_schema(rrddir, "h1", "f.a.rrd", 1000);
		fsidx_set_units(NULL);
		fsidx_flush(rrddir, "h1");
		dumpindex("h1");
	}
	else {
		fprintf(stderr, "unknown scenario %s\n", scenario);
		return 2;
	}

	return 0;
}
