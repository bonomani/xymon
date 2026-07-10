/* Regression test for issue #234: status pages paged graphs from a guessed
 * status-text line count, emitting graph images with no RRD data behind them.
 * When xymond_rrd has recorded the real per-status RRD update count in
 * <XYMONRRDS>/<host>/.<service>.count, htmllog must page from that instead -
 * and must ignore missing, stale or unparsable count files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <utime.h>

#include "libxymon.h"

static int failures = 0;
static char countfn[1024];

static void expect_contains(const char *label, const char *text, const char *needle)
{
	if (!text || !strstr(text, needle)) {
		fprintf(stderr, "%s: missing '%s'\n", label, needle);
		failures++;
	}
}

static void expect_not_contains(const char *label, const char *text, const char *needle)
{
	if (text && strstr(text, needle)) {
		fprintf(stderr, "%s: unexpected '%s'\n", label, needle);
		failures++;
	}
}

static void write_count(const char *service, const char *value)
{
	FILE *fd;

	snprintf(countfn, sizeof(countfn), "%s/testhost/.%s.count", getenv("XYMONRRDS"), service);
	fd = fopen(countfn, "w");
	if (!fd) { perror(countfn); exit(2); }
	fprintf(fd, "%s\n", value);
	fclose(fd);
}

static void make_stale(void)
{
	struct utimbuf ub;

	ub.actime = ub.modtime = time(NULL) - 2*86400;
	if (utime(countfn, &ub) != 0) { perror("utime"); exit(2); }
}

static char *render_log(const char *service, const char *restofmsg)
{
	char *html = NULL;
	size_t htmlsz = 0;
	FILE *out;

	out = open_memstream(&html, &htmlsz);
	if (!out) { perror("open_memstream"); exit(2); }

	generate_html_log("testhost", "Test Host", (char *)service, "127.0.0.1",
			  COL_GREEN, 0, "tester", "",
			  0, "0 minutes", "green status ok", (char *)restofmsg,
			  NULL, 0, NULL, NULL, 0, NULL,
			  0, 1, 0, 0, NULL, NULL,
			  NULL, NULL, NULL, 3600, out);

	fclose(out);
	return html;
}

int main(void)
{
	char dfmsg[4096];
	char dir[1024];
	char *html;
	int i;

	histlocation = HIST_NONE;

	snprintf(dir, sizeof(dir), "%s/testhost", getenv("XYMONRRDS"));
	if ((mkdir(dir, 0755) != 0)) { perror(dir); exit(2); }

	/* A df report: header plus 20 filesystem lines -> legacy linecount 20 */
	snprintf(dfmsg, sizeof(dfmsg), "Filesystem 1024-blocks Used Avail Capacity Mounted on\n");
	for (i = 1; i <= 20; i++)
		snprintf(dfmsg + strlen(dfmsg), sizeof(dfmsg) - strlen(dfmsg),
			 "/dev/da%dp2 1000 500 500 50%% /fs%d\n", i, i);

	/* The issue #234 case: only 5 RRD files were updated for this status.
	 * A fresh recorded count pages 1x5 - no dead images 6-20. */
	write_count("disk", "5");
	html = render_log("disk", dfmsg);
	expect_contains("fresh count pages by files", html, "<!-- linecount=5 -->");
	expect_contains("fresh count pages by files", html, "first=1&amp;count=5");
	expect_not_contains("fresh count pages by files", html, "first=6");
	free(html);

	/* A stale count (host stopped updating RRDs) must not be trusted:
	 * fall back to the legacy text guess, mirroring showgraph's 24h rule. */
	make_stale();
	html = render_log("disk", dfmsg);
	expect_contains("stale count falls back", html, "<!-- linecount=20 -->");
	expect_contains("stale count falls back", html, "first=16&amp;count=5");
	free(html);

	/* An unparsable count falls back to the legacy guess. */
	write_count("disk", "bogus");
	html = render_log("disk", dfmsg);
	expect_contains("garbage count falls back", html, "<!-- linecount=20 -->");
	free(html);

	/* A zero count is "nothing to say", not "no graphs": legacy guess. */
	write_count("disk", "0");
	html = render_log("disk", dfmsg);
	expect_contains("zero count falls back", html, "<!-- linecount=20 -->");
	free(html);

	/* No count file at all (locator setups, older xymond_rrd): legacy guess. */
	remove(countfn);
	html = render_log("disk", dfmsg);
	expect_contains("missing count falls back", html, "<!-- linecount=20 -->");
	expect_contains("missing count falls back", html, "first=16&amp;count=5");
	free(html);

	/* An explicit <!-- linecount=N --> in the status overrides everything -
	 * it is a deliberate knob (hobbit-perl-client), checked before any count. */
	write_count("disk", "5");
	html = render_log("disk", "<!-- linecount=3 -->\nstatus body");
	expect_contains("explicit comment wins", html, "first=1&amp;count=3");
	expect_not_contains("explicit comment wins", html, "count=5");
	free(html);

	/* Non-multigraph services never page by count: a stray count file for
	 * cpu (maps to la, single RRD) must not add first=/count= to its link. */
	write_count("cpu", "7");
	html = render_log("cpu", "up: 5 days, 1 users, 2 procs, load=0.05\n");
	expect_contains("non-multigraph untouched", html, "service=la");
	expect_not_contains("non-multigraph untouched", html, "first=");
	free(html);

	printf(failures ? "FAILED\n" : "ALL OK\n");
	return failures ? 1 : 0;
}
