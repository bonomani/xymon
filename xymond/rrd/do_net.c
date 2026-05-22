/*----------------------------------------------------------------------------*/
/* Xymon RRD handler module.                                                  */
/*                                                                            */
/* Copyright (C) 2004-2011 Henrik Storner <henrik@hswn.dk>                    */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char do_net_rcsid[] = "$Id$";

#include "smokeping.h"

int do_net_rrd(char *hostname, char *testname, char *classname, char *pagepaths, char *msg, time_t tstamp)
{
	static char *xymonnet_params[]       = { "DS:sec:GAUGE:600:0:U", NULL };
	static void *xymonnet_tpl            = NULL;

	char *p;
	float seconds = 0.0;
	int do_default = 1;

	if (xymonnet_tpl == NULL) xymonnet_tpl = setup_template(xymonnet_params);

	if (strcmp(testname, "http") == 0) {
		char *line1, *url = NULL, *eoln;

		do_default = 0;

		line1 = msg;
		while ((line1 = strchr(line1, '\n')) != NULL) {
			line1++; /* Skip the newline */
			eoln = strchr(line1, '\n'); if (eoln) *eoln = '\0';

			if ( (strncmp(line1, "&green", 6) == 0) || 
			     (strncmp(line1, "&yellow", 7) == 0) ||
			     (strncmp(line1, "&red", 4) == 0) ) {
				p = strstr(line1, "http");
				if (p) {
					url = xstrdup(p);
					p = strchr(url, ' ');
					if (p) *p = '\0';
				}
			}
			else if (url && ((p = strstr(line1, "Seconds:")) != NULL) && (sscanf(p, "Seconds: %f", &seconds) == 1)) {
				char *urlfn = url;

				if (strncmp(urlfn, "http://", 7) == 0) urlfn += 7;
				p = urlfn; while ((p = strchr(p, '/')) != NULL) *p = ',';
				setupfn3("%s.%s.%s.rrd", "tcp", "http", urlfn);
				snprintf(rrdvalues, sizeof(rrdvalues), "%d:%.2f", (int)tstamp, seconds);
				create_and_update_rrd(hostname, testname, classname, pagepaths, xymonnet_params, xymonnet_tpl);
				xfree(url); url = NULL;
			}

			if (eoln) *eoln = '\n';
		}

		if (url) xfree(url);
	}
	else if (strcmp(testname, xgetenv("PINGCOLUMN")) == 0) {
		/*
		 * Ping-tests, possibly using fping.
		 */
		char *tmod = "ms";

		do_default = 0;

		if ((p = strstr(msg, "time=")) != NULL) {
			/* Standard ping, reports ".... time=0.2 ms" */
			seconds = atof(p+5);
			tmod = p + 5; tmod += strspn(tmod, "0123456789. ");
		}
		else if ((p = strstr(msg, "alive")) != NULL) {
			/* fping, reports ".... alive (0.43 ms)" */
			seconds = atof(p+7);
			tmod = p + 7; tmod += strspn(tmod, "0123456789. ");
		}

		if (strncmp(tmod, "ms", 2) == 0) seconds = seconds / 1000.0;
		else if (strncmp(tmod, "usec", 4) == 0) seconds = seconds / 1000000.0;

		setupfn2("%s.%s.rrd", "tcp", testname);
		snprintf(rrdvalues, sizeof(rrdvalues), "%d:%.6f", (int)tstamp, seconds);
		create_and_update_rrd(hostname, testname, classname, pagepaths, xymonnet_params, xymonnet_tpl);

		/* SmokePing-style data: xymonping with --samples appends
		 * "samples=v1,v2,...,vN loss=k/M" (alive hosts) or
		 * "loss=M/M" (unreachable hosts). All parsing/RRD shaping
		 * lives in lib/smokeping.c so future smoke probes can reuse
		 * it. The legacy RRD above still gets written -- keeps the
		 * existing [conn] graph working for smoke hosts.
		 *
		 * The RRD shape is keyed off the reported denominator N
		 * (loss=K/N), not $SMOKEPINGSAMPLES, so a host configured
		 * with smoke_conn:N != $SMOKEPINGSAMPLES still records all
		 * its samples. The [conn-smoke] graph (web/showgraph.c)
		 * reads the per-file DS count back via rrd_info_r, so the
		 * graph naturally matches whatever N landed here. */
		if (strstr(msg, "loss=") != NULL) {
			char *lp = strstr(msg, "loss=");
			int reported_total = 0, dummy_k = 0;
			int n_slots, capacity;
			double *samples;
			int nrecv = 0, lost = 0, totalsent = 0;
			double median, lossfrac;

			/* Peek at "loss=K/N" so we know how big a buffer to
			 * allocate before parsing the samples= list. Clamp N
			 * to SMOKEPING_MAX_SAMPLES: a malformed or hostile
			 * status line with a huge denominator would otherwise
			 * size a per-N RRD template cache entry (never freed)
			 * and a samples buffer for it. */
			(void)sscanf(lp + 5, "%d/%d", &dummy_k, &reported_total);
			if (reported_total > SMOKEPING_MAX_SAMPLES) reported_total = SMOKEPING_MAX_SAMPLES;

			n_slots = (reported_total > 0 ? reported_total : smokeping_sample_count());
			capacity = n_slots + 4;
			samples = (double *)calloc(capacity, sizeof(double));
			if (!samples) {
				errprintf("calloc(%d doubles) failed for smoke samples; skipping\n", capacity);
				return 0;
			}

			smokeping_parse_message(msg, samples, capacity, &nrecv, &lost, &totalsent);

			if (totalsent <= 0) totalsent = nrecv + lost;
			if (totalsent <= 0) totalsent = nrecv;
			lossfrac = (totalsent > 0 ? (double)lost / (double)totalsent : 0.0);

			median = smokeping_median(samples, nrecv);

			setupfn2("%s.%s-smoke.rrd", "tcp", testname);
			smokeping_format_rrdvalues_n(rrdvalues, sizeof(rrdvalues), tstamp,
			                             median, lossfrac, samples, nrecv,
			                             n_slots);
			free(samples);
			create_and_update_rrd(hostname, testname, classname, pagepaths,
			                      smokeping_rrd_params_n(n_slots),
			                      smokeping_rrd_template_n(n_slots));
		}

		return 0;
	}
	else if (strcmp(testname, "ntp") == 0) {
		/*
		 * sntp output: 
		 *    2009 Nov 13 11:29:10.000313 + 0.038766 +/- 0.052900 secs
		 * ntpdate output: 
		 *    server 172.16.10.2, stratum 3, offset -0.040324, delay 0.02568
		 *    13 Nov 11:29:06 ntpdate[7038]: adjust time server 172.16.10.2 offset -0.040324 sec
		 */

		char dataforntpstat[100];
		char *offsetval = NULL;
		char offsetbuf[40];
		char *msgcopy = strdup(msg);

		if (strstr(msgcopy, "ntpdate") != NULL) {
			/* Old-style "ntpdate" output */
			char *p;

			p = strstr(msgcopy, "offset ");
			if (p) {
				p += 7;
				offsetval = strtok(p, " \r\n\t");
			}
		}
		else if (strstr(msgcopy, " secs") != NULL) {
			/* Probably new "sntp" output */
			char *year, *tm, *offsetdirection, *offset, *plusminus, *errorbound, *secs;

			tm = offsetdirection = plusminus = errorbound = secs = NULL;
			year = strtok(msgcopy, " ");
			tm = year ? strtok(NULL, " ") : NULL;
			offsetdirection = tm ? strtok(NULL, " ") : NULL;
			offset = offsetdirection ? strtok(NULL, " ") : NULL;
			plusminus = offset ? strtok(NULL, " ") : NULL;
			errorbound = plusminus ? strtok(NULL, " ") : NULL;
			secs = errorbound ? strtok(NULL, " ") : NULL;

			if ( offsetdirection && ((strcmp(offsetdirection, "+") == 0) || (strcmp(offsetdirection, "-") == 0)) &&
			     plusminus && (strcmp(plusminus, "+/-") == 0) && 
			     secs && (strcmp(secs, "secs") == 0) ) {
				/* Looks sane */
				snprintf(offsetbuf, sizeof(offsetbuf), "%s%s", offsetdirection, offset);
				offsetval = offsetbuf;
			}
		}
		
		if (offsetval) {
			snprintf(dataforntpstat, sizeof(dataforntpstat), "offset=%s", offsetval);
			do_ntpstat_rrd(hostname, testname, classname, pagepaths, dataforntpstat, tstamp);
		}

		xfree(msgcopy);
	}


	if (do_default) {
		/*
		 * Normal network tests - pick up the "Seconds:" value
		 */
		p = strstr(msg, "\nSeconds:");
		if (p && (sscanf(p+1, "Seconds: %f", &seconds) == 1)) {
			setupfn2("%s.%s.rrd", "tcp", testname);
			snprintf(rrdvalues, sizeof(rrdvalues), "%d:%f", (int)tstamp, seconds);
			return create_and_update_rrd(hostname, testname, classname, pagepaths, xymonnet_params, xymonnet_tpl);
		}
	}

	return 0;
}

