/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * tests/server/analysis-threshold-harness.c
 *
 * Driver for client_config_thresholds() (xymond/client_config.c), used by
 * analysis-threshold.sh. It loads the hosts.cfg and analysis.cfg given on
 * argv, fills a batch with samples given as further arguments, each
 * "test instance name value state" with "-" for no instance and a state of
 * ok or stale, then judges every test named in the batch under the host's
 * THRESHOLD rules and prints, per test, "test <name> <colour>" followed by
 * the lines the rules wrote, then "sample <test> <instance> <name> <colour>"
 * for every sample, and the rules as --dump-config prints them. Before the
 * THRESHOLD rules it runs the keyword rules -- LOAD, UP, CLOCK compiled to
 * tagged threshold rules -- the same way, printing "keyword <test> <colour>"
 * and their lines, and it prints what get_cpu_thresholds() and
 * get_memory_thresholds() read back from those rules for testhost and
 * otherhost as "cpu <host> ..." and "mem <host> ...".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"
#include "client_config.h"

int main(int argc, char *argv[])
{
	metricbatch_t *b;
	void *hinfo;
	int i;

	if ((argc < 3) || (((argc - 3) % 5) != 0)) {
		fprintf(stderr, "usage: %s hosts.cfg analysis.cfg [test instance name value ok|stale]...\n", argv[0]);
		return 2;
	}

	load_hostnames(argv[1], NULL, get_fqdn());
	load_client_config(argv[2]);
	hinfo = hostinfo("testhost");
	if (!hinfo) { fprintf(stderr, "testhost not in hosts.cfg\n"); return 2; }

	b = metric_batch_new();
	client_config_batch(b);
	for (i = 3; (i < argc); i += 5) {
		metric_batch_add(b, argv[i], ((strcmp(argv[i+1], "-") == 0) ? NULL : argv[i+1]), argv[i+2],
				 atof(argv[i+3]), ((strcmp(argv[i+4], "stale") == 0) ? METRIC_STALE : METRIC_OK));
	}

	/* Each distinct test once, in the order first seen. */
	for (i = 0; (i < b->count); i++) {
		metricsample_t *s = metric_batch_sample(b, i);
		strbuffer_t *lines;
		int j, color;

		for (j = 0; (j < i); j++) if (strcmp(metric_batch_sample(b, j)->test, s->test) == 0) break;
		if (j < i) continue;

		lines = newstrbuffer(0);
		color = client_config_keywords(hinfo, "", s->test, lines);
		printf("keyword %s %s\n%s", s->test, colorname(color), STRBUF(lines));
		clearstrbuffer(lines);
		color = client_config_thresholds(hinfo, "", s->test, lines);
		printf("test %s %s\n%s", s->test, colorname(color), STRBUF(lines));
		freestrbuffer(lines);
	}

	{
		char *hosts[2] = { "testhost", "otherhost" };
		int h;

		for (h = 0; (h < 2); h++) {
			float loadyellow, loadred;
			int recentlimit, ancientlimit, uptimecolor, maxclockdiff, clockdiffcolor;
			int physyellow, physred, swapyellow, swapred, actyellow, actred;
			void *hi = hostinfo(hosts[h]);

			if (!hi) continue;
			get_cpu_thresholds(hi, "", &loadyellow, &loadred, &recentlimit, &ancientlimit, &uptimecolor, &maxclockdiff, &clockdiffcolor);
			printf("cpu %s load %.1f %.1f up %d %d %s clock %d %s\n", hosts[h], loadyellow, loadred,
			       recentlimit, ancientlimit, colorname(uptimecolor), maxclockdiff, colorname(clockdiffcolor));
			get_memory_thresholds(hi, "", &physyellow, &physred, &swapyellow, &swapred, &actyellow, &actred);
			printf("mem %s phys %d %d swap %d %d act %d %d\n", hosts[h], physyellow, physred, swapyellow, swapred, actyellow, actred);
		}
	}

	for (i = 0; (i < b->count); i++) {
		metricsample_t *s = metric_batch_sample(b, i);
		printf("sample %s %s %s %s\n", s->test, (s->instance ? s->instance : "-"), s->name, colorname(s->color));
	}

	dump_client_config();
	return 0;
}
