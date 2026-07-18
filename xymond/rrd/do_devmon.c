/*----------------------------------------------------------------------------*/
/* Xymon RRD handler module for Devmon                                        */
/*                                                                            */
/* Copyright (C) 2004-2011 Henrik Storner <henrik@hswn.dk>                    */
/* Copyright (C) 2008 Buchan Milne                                            */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char devmon_rcsid[] = "$Id $";

int do_devmon_rrd(char *hostname, char *testname, char *classname, char *pagepaths, char *msg, time_t tstamp)
{
#define MAXCOLS 20
	char *devmon_params[MAXCOLS+7] = { NULL, };

	char *eoln, *curline;
	static int ptnsetup = 0;
	static pcre2_code *inclpattern = NULL;
	static pcre2_code *exclpattern = NULL;
	int in_devmon = 1;
	int numds = 0;
	char *rrdbasename;
	int lineno = 0;

	rrdbasename = NULL;
	curline = msg;
	while (curline)  {
		char *fsline = NULL;
		char *p;
		char *columns[MAXCOLS];
		int columncount;
		char *ifname = NULL;
		int pused = -1;
		int wanteddisk = 1;
		long long aused = 0;
		char *dsval;
		int i;
		int rrdvalused;

		eoln = strchr(curline, '\n'); if (eoln) *eoln = '\0';
		lineno++;

		/* Tolerate CRLF messages: values and banner names must not
		 * carry a trailing CR into RRD updates or filenames. */
		i = strlen(curline);
		if (i && (curline[i-1] == '\r')) curline[i-1] = '\0';

		if(!strncmp(curline, "<!--DEVMON RRD: ",16)) {
			char *slash;

			in_devmon = 0;
			/*if(rrdbasename) {xfree(rrdbasename);rrdbasename = NULL;}*/
			rrdbasename = strtok(curline+16," ");
			if (rrdbasename == NULL) rrdbasename = xstrdup(testname);
			/* The banner name becomes an RRD filename prefix; setupfn2()
			 * only sanitizes the instance part, so strip path separators
			 * here - devmon's own names never contain them. */
			while ((slash = strchr(rrdbasename, '/')) != NULL) *slash = ',';
			dbgprintf("DEVMON: changing testname from %s to %s\n",testname,rrdbasename);
			numds = 0;
			setup_lazy(0);
			goto nextline;
		}
		if(!strncmp(curline, XYMON_METRICS_MARKER, strlen(XYMON_METRICS_MARKER))) {
			/* Same block format as the devmon banner, but the name becomes
			 * an RRD filename prefix from an arbitrary status message, so
			 * it is restricted to [A-Za-z0-9_-]. An invalid name opens no
			 * block (if an earlier block is still unclosed, its lines keep
			 * accumulating there - same as the legacy banner behaves). */
			char *name = strtok(curline + strlen(XYMON_METRICS_MARKER), " ");
			int namelen = (name ? strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") : 0);

			if (name && (namelen > 0) && (namelen <= XYMON_MARKER_NAMELEN_MAX) && (name[namelen] == '\0')) {
				char *attr;

				in_devmon = 0;
				rrdbasename = name;
				dbgprintf("METRICS: changing testname from %s to %s\n",testname,rrdbasename);
				numds = 0;
				setup_lazy(0);
				while ((attr = strtok(NULL, " ")) != NULL) {
					if (strcmp(attr, "lazy") == 0) setup_lazy(1);
				}
			}
			else {
				dbgprintf("METRICS: invalid block name, skipping block\n");
			}
			goto nextline;
		}
		if(in_devmon == 0 && !strncmp(curline, "-->",3)) {
			in_devmon = 1;
			goto nextline;
		}
		if (in_devmon != 0 ) goto nextline;

		for (columncount=0; (columncount<MAXCOLS); columncount++) columns[columncount] = "";
		fsline = xstrdup(curline); columncount = 0; p = strtok(fsline, " ");
		while (p && (columncount < MAXCOLS)) { columns[columncount++] = p; p = strtok(NULL, " "); }

		/* DS:ds0:COUNTER:600:0:U DS:ds1:COUNTER:600:0:U */
		if (!strncmp(curline, "DS:",3)) {
			dbgprintf("Looking for DS definitions in %s\n",curline);
			while ( numds < MAXCOLS) {
				char *spec, *cp;
				int ncolon = 0;

				dbgprintf("Seeing if column %d that has %s is a DS\n",numds,columns[numds]);
				if (strncmp(columns[numds],"DS:",3)) break;
				spec = xstrdup(columns[numds]);
				/* A DS spec may declare a unit as an optional 7th
				 * colon field (DS:name:GAUGE:600:0:U:ms). rrdtool
				 * accepts only the 6-field spec, so cut the suffix
				 * before it reaches rrdcreate. */
				for (cp = spec; (*cp); cp++) {
					if (*cp != ':') continue;
					if (++ncolon == 6) { *cp = '\0'; break; }
				}
				devmon_params[numds] = spec;
				numds++;
			}
			dbgprintf("Found %d DS definitions\n",numds);
			devmon_params[numds] = NULL;

			goto nextline;
		}

		/* A block line whose first token is an ALL-CAPS keyword ending in
		 * ':' is a declaration - DS: is one, handled above. Declarations
		 * the writer does not know are ignored by contract, so the block
		 * dialect can grow keyword lines without breaking deployed
		 * writers; instance names must not look like one. */
		{
			int kwlen = strspn(columns[0], "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
			if ((kwlen > 0) && (columns[0][kwlen] == ':')) {
				dbgprintf("Skipping unknown declaration on line %d (%s)\n",lineno,columns[0]);
				goto nextline;
			}
		}

		dbgprintf("Found %d columns in devmon rrd data\n",columncount);
		if (columncount > 2) {
			dbgprintf("Skipping line %d, found %d (max 2) columns in devmon rrd data, space in repeater name?\n",lineno,columncount);
			goto nextline;
		}

		/* Now we should be on to values:
		 * eth0.0 4678222:9966777
		 */
		ifname = xstrdup(columns[0]);
		dsval = strtok(columns[1],":");
		if (dsval == NULL) {
			dbgprintf("Skipping line %d, line is malformed\n",lineno);
			goto nextline;
		}
		/* Values come from the message, so every append is bounded -
		 * rrdvalues is a fixed static buffer and messages can be far
		 * larger than it. An oversized line is skipped, not truncated. */
		rrdvalused = snprintf(rrdvalues, sizeof(rrdvalues), "%d:", (int)tstamp);
		if ((rrdvalused < 0) || (rrdvalused + strlen(dsval) + 1 > sizeof(rrdvalues))) {
			dbgprintf("Skipping line %d, values too long\n",lineno);
			goto nextline;
		}
		strcpy(rrdvalues + rrdvalused, dsval); rrdvalused += strlen(dsval);
		for (i=1;i < numds;i++) {
			dsval = strtok(NULL,":");
			if (dsval == NULL) {
				dbgprintf("Skipping line %d, %d tokens present, expecting %d\n",lineno,i,numds);
				goto nextline;
			}
			if (rrdvalused + strlen(dsval) + 2 > sizeof(rrdvalues)) {
				dbgprintf("Skipping line %d, values too long\n",lineno);
				goto nextline;
			}
			rrdvalues[rrdvalused++] = ':';
			strcpy(rrdvalues + rrdvalused, dsval); rrdvalused += strlen(dsval);
		}
		/* File names in the format if_load.eth0.0.rrd; a lazy banner
		 * attribute is enforced by the generic creation gate in
		 * create_and_update_rrd(). METRICS blocks reversibly encode the
		 * instance (rrdinstance_encode) so an arbitrary instance - a mount
		 * point, a name with a comma - round-trips to one unambiguous file;
		 * the legacy banner keeps setupfn2()'s lossy '/'->',' so its
		 * existing files are untouched. */
		if (metrics_block) {
			char *encinst = rrdinstance_encode(ifname);
			setupfn2("%s.%s.rrd", rrdbasename, encinst);
			xfree(encinst);
		}
		else {
			setupfn2("%s.%s.rrd", rrdbasename, ifname);
		}
		dbgprintf("Sending from devmon to RRD for %s %s: %s\n",rrdbasename,ifname,rrdvalues);
		create_and_update_rrd(hostname, testname, classname, pagepaths, devmon_params, NULL);
		if (ifname) { xfree(ifname); ifname = NULL; }

		if (eoln) *eoln = '\n';

nextline:
		if (fsline) { xfree(fsline); fsline = NULL; }
		curline = (eoln ? (eoln+1) : NULL);
	}
	setup_lazy(0);	/* the banner flag must not leak into other handlers */

	return 0;
}
