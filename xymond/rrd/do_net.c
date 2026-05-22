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

/* SmokePing-style RRD has a fixed DS count baked in at first call.
 * Layout: DS:median, DS:loss (fraction 0..1), DS:ping1..pingN (sorted asc).
 * Received samples shorter than N pad the trailing pingX slots with U. */
static char **smokeping_params = NULL;
static void *smokeping_tpl = NULL;
static int smokeping_n = 0;

static int smokeping_qsort_cmp(const void *a, const void *b)
{
	double da = *(const double *)a, db = *(const double *)b;
	return (da < db) ? -1 : (da > db);
}

static void ensure_smokeping_template(void)
{
	int i;
	char *envn;
	char buf[64];

	if (smokeping_params) return;

	envn = xgetenv("SMOKEPINGSAMPLES");
	smokeping_n = (envn ? atoi(envn) : 20);
	if (smokeping_n <= 0) smokeping_n = 20;

	smokeping_params = (char **)calloc(smokeping_n + 3, sizeof(char *));
	smokeping_params[0] = strdup("DS:median:GAUGE:600:0:U");
	smokeping_params[1] = strdup("DS:loss:GAUGE:600:0:U");
	for (i = 0; i < smokeping_n; i++) {
		snprintf(buf, sizeof(buf), "DS:ping%d:GAUGE:600:0:U", i + 1);
		smokeping_params[2 + i] = strdup(buf);
	}
	smokeping_params[smokeping_n + 2] = NULL;
	smokeping_tpl = setup_template(smokeping_params);
}

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
		 * "loss=M/M" (unreachable hosts). The presence of "loss=" is the
		 * smoke-mode marker, so unreachable hosts still get a smoke RRD
		 * update (U for samples, lossfrac=1.0). The first RRD above
		 * keeps backwards compat with the existing [conn] graph. */
		if ((p = strstr(msg, "loss=")) != NULL) {
			char *q, *vp;
			char *sp;
			double *samples;
			int nrecv = 0, lost = 0, totalsent = 0;
			int i, capacity;
			double median = 0.0, lossfrac = 0.0;
			int k = 0, n = 0;

			if (sscanf(p + strlen("loss="), "%d/%d", &k, &n) >= 1) {
				lost = k;
				totalsent = n;
			}

			ensure_smokeping_template();
			capacity = smokeping_n + 4;
			samples = (double *)calloc(capacity, sizeof(double));

			/* Parse comma-separated sample values (in seconds). Absent
			 * for unreachable hosts. */
			if ((sp = strstr(msg, "samples=")) != NULL) {
				vp = sp + strlen("samples=");
				while (*vp && (nrecv < capacity)) {
					if ((*vp == ' ') || (*vp == '\n') || (*vp == '\0')) break;
					samples[nrecv++] = strtod(vp, &q);
					if (q == vp) break;	/* not a number */
					vp = q;
					if (*vp == ',') vp++;
				}
			}

			if (totalsent <= 0) totalsent = (nrecv + lost);
			if (totalsent <= 0) totalsent = nrecv;
			lossfrac = (totalsent > 0 ? (double)lost / (double)totalsent : 0.0);

			if (nrecv > 0) {
				qsort(samples, nrecv, sizeof(double), smokeping_qsort_cmp);
				median = (nrecv & 1)
					? samples[nrecv / 2]
					: (samples[nrecv/2 - 1] + samples[nrecv/2]) / 2.0;
			}

			setupfn2("%s.%s-smoke.rrd", "tcp", testname);
			{
				int off = snprintf(rrdvalues, sizeof(rrdvalues), "%d:", (int)tstamp);
				if (nrecv > 0) {
					off += snprintf(rrdvalues + off, sizeof(rrdvalues) - off, "%.6f:%.6f", median, lossfrac);
				}
				else {
					off += snprintf(rrdvalues + off, sizeof(rrdvalues) - off, "U:%.6f", lossfrac);
				}
				for (i = 0; (i < smokeping_n) && (off < (int)sizeof(rrdvalues)); i++) {
					if (i < nrecv) {
						off += snprintf(rrdvalues + off, sizeof(rrdvalues) - off, ":%.6f", samples[i]);
					}
					else {
						off += snprintf(rrdvalues + off, sizeof(rrdvalues) - off, ":U");
					}
				}
			}
			free(samples);
			create_and_update_rrd(hostname, testname, classname, pagepaths, smokeping_params, smokeping_tpl);
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

