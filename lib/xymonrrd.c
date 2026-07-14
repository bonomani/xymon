/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* This is a library module, part of libxymon.                                */
/* It contains routines for working with RRD graphs.                          */
/*                                                                            */
/* Copyright (C) 2002-2011 Henrik Storner <henrik@storner.dk>                 */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char rcsid[] = "$Id$";

#include <ctype.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include "libxymon.h"
#include "version.h"

/* This is for mapping a status-name -> RRD file */
xymonrrd_t *xymonrrds = NULL;
void * xymonrrdtree;

/* This is the information needed to generate links on the trends column page  */
xymongraph_t *xymongraphs = NULL;

static const char *xymonlinkfmt = "<table summary=\"%s Graph\"><tr><td><A HREF=\"%s&amp;action=menu\"><IMG BORDER=0 SRC=\"%s&amp;graph=hourly&amp;action=view\" ALT=\"xymongraph %s\"></A></td><td> <td align=\"left\" valign=\"top\"> <a href=\"%s&amp;graph=custom&amp;action=selzoom\"> <img src=\"%s/zoom.%s\" border=0 alt=\"Zoom graph\" style='padding: 3px'> </a> </td></tr></table>\n";

static const char *metafmt = "<RRDGraph>\n  <GraphType>%s</GraphType>\n  <GraphLink><![CDATA[%s]]></GraphLink>\n  <GraphImage><![CDATA[%s&amp;graph=hourly]]></GraphImage>\n</RRDGraph>\n";


/*
 * Graph metadata read from the [name] sections of graphs.cfg: keywords
 * that belong with the graph definition but are needed by the page
 * renderers (which never parse the full rrdtool definitions). Only the
 * section headers and the known keywords are scanned.
 */
typedef struct gdefmeta_t {
	char *name;
	int maxinstancesperimage;		/* MAXINSTANCESPERIMAGE N: instances per image when paging */
	int trends;		/* TRENDS: show on the trends page */
	int lazy;		/* LAZY: no file until the values first change */
	char *exstorepat;	/* EXSTOREPATTERN: instances never stored */
	char *storepat;		/* STOREPATTERN: only these stored; forces past LAZY */
	pcre2_code *exstore;	/* compiled on demand */
	pcre2_code *store;
	struct gdefmeta_t *next;
} gdefmeta_t;
static gdefmeta_t *gdefmetahead = NULL;

static void load_gdef_meta(void)
{
	static int done = 0;
	char fn[PATH_MAX];
	FILE *fd;
	strbuffer_t *inbuf;
	gdefmeta_t *cur = NULL;

	if (done) return;
	done = 1;

	snprintf(fn, sizeof(fn), "%s/etc/graphs.cfg", xgetenv("XYMONHOME"));
	fd = stackfopen(fn, "r", NULL);
	if (fd == NULL) return;

	inbuf = newstrbuffer(0);
	while (stackfgets(inbuf, NULL)) {
		char *p = STRBUF(inbuf);
		p += strspn(p, " \t");

		if (*p == '[') {
			char *delim = strchr(p, ']');
			cur = NULL;
			if (delim) {
				*delim = '\0';
				cur = (gdefmeta_t *)calloc(1, sizeof(gdefmeta_t));
				cur->name = strdup(p+1);
				cur->next = gdefmetahead;
				gdefmetahead = cur;
			}
		}
		else if (cur && (strncasecmp(p, "MAXINSTANCESPERIMAGE", 20) == 0) && isspace((int)p[20])) {
			cur->maxinstancesperimage = atoi(p+20);
			if (cur->maxinstancesperimage < 0) cur->maxinstancesperimage = 0;
		}
		else if (cur && (strncasecmp(p, "TRENDS", 6) == 0) && ((p[6] == '\0') || isspace((int)p[6]))) {
			cur->trends = 1;
		}
		else if (cur && (strncasecmp(p, "LAZY", 4) == 0) && ((p[4] == '\0') || isspace((int)p[4]))) {
			cur->lazy = 1;
		}
		else if (cur && (strncasecmp(p, "EXSTOREPATTERN", 14) == 0) && isspace((int)p[14])) {
			char *pat = p + 14 + strspn(p+14, " \t");
			pat[strcspn(pat, " \t\r\n")] = '\0';
			if (*pat && !cur->exstorepat) cur->exstorepat = strdup(pat);
		}
		else if (cur && (strncasecmp(p, "STOREPATTERN", 12) == 0) && isspace((int)p[12])) {
			char *pat = p + 12 + strspn(p+12, " \t");
			pat[strcspn(pat, " \t\r\n")] = '\0';
			if (*pat && !cur->storepat) cur->storepat = strdup(pat);
		}
		else if (cur && (strncasecmp(p, "INCLUDE", 7) == 0) && isspace((int)p[7])) {
			/* A variant inherits the base's metadata; its own
			 * keywords (before or after) override - later wins. */
			char *bname = p + 7; 
			gdefmeta_t *base;
			bname += strspn(bname, " \t");
			bname[strcspn(bname, " \t\r\n")] = '\0';
			for (base = gdefmetahead; (base && strcmp(base->name, bname)); base = base->next) ;
			if (base && (base != cur)) {
				if (cur->maxinstancesperimage == 0) cur->maxinstancesperimage = base->maxinstancesperimage;
				if (base->trends) cur->trends = 1;
				if (base->lazy) cur->lazy = 1;
				if (base->exstorepat && !cur->exstorepat) cur->exstorepat = strdup(base->exstorepat);
				if (base->storepat && !cur->storepat) cur->storepat = strdup(base->storepat);
			}
		}
	}
	stackfclose(fd);
	freestrbuffer(inbuf);
}

int xymon_gdef_maxinstancesperimage(char *name)
{
	gdefmeta_t *walk;

	for (walk = gdefmetahead; (walk && strcmp(walk->name, name)); walk = walk->next) ;
	return ((walk && (walk->maxinstancesperimage > 0)) ? walk->maxinstancesperimage : 0);
}


/* Filename lookup: match "name.instance.rrd" against the graph
 * definitions, with the same partial-match boundary rule as
 * find_xymon_graph(). The scan must be loaded first. */
static gdefmeta_t *gdefmeta_forfile(char *fn)
{
	gdefmeta_t *walk;

	load_gdef_meta();
	for (walk = gdefmetahead; (walk); walk = walk->next) {
		int nlen = strlen(walk->name);
		if (strncmp(walk->name, fn, nlen) != 0) continue;
		if ((fn[nlen] != '.') && (fn[nlen] != ',') && (fn[nlen] != '\0')) continue;
		return walk;
	}
	return NULL;
}

int xymon_gdef_lazy_forfile(char *fn)
{
	gdefmeta_t *walk = gdefmeta_forfile(fn);

	return (walk && walk->lazy);
}

static pcre2_code *storepat_compile(char *pattern)
{
	int err;
	PCRE2_SIZE errofs;
	pcre2_code *result = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, PCRE2_CASELESS, &err, &errofs, NULL);

	if (!result) errprintf("graphs.cfg store pattern '%s' invalid at offset %d\n", pattern, (int)errofs);
	return result;
}

static int storepat_match(pcre2_code *pat, char *fn, size_t fnlen)
{
	pcre2_match_data *md;
	int result;

	md = pcre2_match_data_create_from_pattern(pat, NULL);
	result = pcre2_match(pat, (PCRE2_SPTR)fn, fnlen, 0, 0, md, NULL);
	pcre2_match_data_free(md);
	return (result >= 0);
}

/*
 * The RRD writer's storage gate: may this file be written at all, and if
 * so, does a STOREPATTERN match force it past the LAZY creation gate?
 * Patterns match the filename minus its ".rrd" suffix, case-insensitively.
 * Returns 0 = drop, 1 = store.
 */
int xymon_gdef_store_allowed(char *fn, int *forced)
{
	gdefmeta_t *walk = gdefmeta_forfile(fn);
	size_t fnlen;

	if (forced) *forced = 0;
	if (!walk || (!walk->exstorepat && !walk->storepat)) return 1;

	fnlen = strlen(fn);
	if ((fnlen > 4) && (strcmp(fn+fnlen-4, ".rrd") == 0)) fnlen -= 4;

	if (walk->exstorepat) {
		if (!walk->exstore) walk->exstore = storepat_compile(walk->exstorepat);
		if (walk->exstore && storepat_match(walk->exstore, fn, fnlen)) return 0;
	}
	if (walk->storepat) {
		if (!walk->store) walk->store = storepat_compile(walk->storepat);
		if (walk->store) {
			if (!storepat_match(walk->store, fn, fnlen)) return 0;
			if (forced) *forced = 1;
		}
	}
	return 1;
}

/* Does this graph's config make its file set diverge from what a status
 * message shows? Then a message-derived paging count cannot be trusted. */
int xymon_gdef_fileset_unknown(char *name)
{
	gdefmeta_t *walk;

	for (walk = gdefmetahead; (walk && strcmp(walk->name, name)); walk = walk->next) ;
	return (walk && (walk->lazy || walk->exstorepat || walk->storepat));
}


/*
 * Define the mapping between Xymon columns and RRD graphs.
 * Normally they are identical, but some RRD's use different names.
 */
static void rrd_setup(void)
{
	static int setup_done = 0;
	SBUF_DEFINE(lenv);
	char *ldef, *p, *services;
	SBUF_DEFINE(tcptests);
	int count;
	xymonrrd_t *lrec;
	xymongraph_t *grec;


	/* Do nothing if we have been called within the past 5 minutes */
	if ((setup_done + 300) >= getcurrenttime(NULL)) return;


	/* 
	 * Must free any old data first.
	 * NB: These lists are NOT null-terminated ! 
	 *     Stop when svcname becomes a NULL.
	 */
	lrec = xymonrrds;
	while (lrec && lrec->svcname) {
		if (lrec->xymonrrdname != lrec->svcname) xfree(lrec->xymonrrdname);
		xfree(lrec->svcname);
		lrec++;
	}
	if (xymonrrds) {
		xfree(xymonrrds);
		xtreeDestroy(xymonrrdtree);
	}

	grec = xymongraphs;
	while (grec && grec->xymonrrdname) {
		if (grec->xymonpartname) xfree(grec->xymonpartname);
		xfree(grec->xymonrrdname);
		grec++;
	}
	if (xymongraphs) xfree(xymongraphs);


	/* Get the tcp services, and count how many there are */
	services = strdup(init_tcp_services());
	SBUF_MALLOC(tcptests, strlen(services)+1);
	strncpy(tcptests, services, tcptests_buflen);
	count = 0; p = strtok(tcptests, " "); while (p) { count++; p = strtok(NULL, " "); }
	strncpy(tcptests, services, tcptests_buflen);

	/* Setup the xymonrrds table, mapping test-names to RRD files */
	SBUF_MALLOC(lenv, strlen(xgetenv("TEST2RRD")) + strlen(tcptests) + count*strlen(",=tcp") + 1);
	strncpy(lenv, xgetenv("TEST2RRD"), lenv_buflen); 
	p = lenv+strlen(lenv)-1; if (*p == ',') *p = '\0';	/* Drop a trailing comma */
	p = strtok(tcptests, " "); 
	while (p) {
		unsigned int curlen = strlen(lenv);
		snprintf(lenv+curlen, (lenv_buflen - curlen), ",%s=tcp", p); 
		p = strtok(NULL, " ");
	}
	xfree(tcptests);
	xfree(services);

	count = 0; p = lenv; do { count++; p = strchr(p+1, ','); } while (p);
	xymonrrds = (xymonrrd_t *)calloc((count+1), sizeof(xymonrrd_t));

	xymonrrdtree = xtreeNew(strcasecmp);
	lrec = xymonrrds; ldef = strtok(lenv, ",");
	while (ldef) {
		p = strchr(ldef, '=');
		if (p) {
			*p = '\0'; 
			lrec->svcname = strdup(ldef);
			lrec->xymonrrdname = strdup(p+1);
		}
		else {
			lrec->svcname = lrec->xymonrrdname = strdup(ldef);
		}
		xtreeAdd(xymonrrdtree, lrec->svcname, lrec);

		ldef = strtok(NULL, ",");
		lrec++;
	}
	xfree(lenv);

	/* Setup the xymongraphs table, describing how to make graphs from an RRD.
	 * Graph metadata from graphs.cfg contributes too: gdefs marked TRENDS
	 * become table members without a GRAPHS env entry. */
	load_gdef_meta();
	lenv = strdup(xgetenv("GRAPHS"));
	p = lenv+strlen(lenv)-1; if (*p == ',') *p = '\0';	/* Drop a trailing comma */
	count = 0; p = lenv; do { count++; p = strchr(p+1, ','); } while (p);
	{
		gdefmeta_t *meta;
		for (meta = gdefmetahead; (meta); meta = meta->next) count += (meta->trends != 0);
	}
	xymongraphs = (xymongraph_t *)calloc((count+1), sizeof(xymongraph_t));

	grec = xymongraphs; ldef = strtok(lenv, ",");
	while (ldef) {
		p = strchr(ldef, ':');
		if (p) {
			*p = '\0'; 
			grec->xymonrrdname = strdup(ldef);
			grec->xymonpartname = strdup(p+1);
			p = strchr(grec->xymonpartname, ':');
			if (p) {
				*p = '\0';
				grec->maxgraphs = atoi(p+1);
				if (strlen(grec->xymonpartname) == 0) {
					xfree(grec->xymonpartname);
					grec->xymonpartname = NULL;
				}
			}
		}
		else {
			grec->xymonrrdname = strdup(ldef);
		}

		ldef = strtok(NULL, ",");
		grec++;
	}
	xfree(lenv);

	/* Append gdefs marked TRENDS in graphs.cfg that GRAPHS did not list */
	{
		gdefmeta_t *meta;
		for (meta = gdefmetahead; (meta); meta = meta->next) {
			xymongraph_t *walk;
			if (!meta->trends) continue;
			for (walk = xymongraphs; (walk->xymonrrdname && strcmp(walk->xymonrrdname, meta->name)); walk++) ;
			if (walk->xymonrrdname == NULL) {
				walk->xymonrrdname = strdup(meta->name);
				grec = walk;
			}
		}
	}

	/* MAXINSTANCESPERIMAGE in the graph definition overrides a legacy ::N suffix:
	 * the split size belongs with the graph, not in a second file. */
	for (grec = xymongraphs; (grec->xymonrrdname); grec++) {
		int maxinstancesperimage = xymon_gdef_maxinstancesperimage(grec->xymonrrdname);
		if (maxinstancesperimage > 0) grec->maxgraphs = maxinstancesperimage;
	}

	setup_done = getcurrenttime(NULL);
}


xymonrrd_t *find_xymon_rrd(char *service, char *flags)
{
	/* Lookup an entry in the xymonrrds table */
	xtreePos_t handle;

	rrd_setup();

	if (flags && (strchr(flags, 'R') != NULL)) {
		/* Don't do RRD's for reverse tests, since they have no data */
		return NULL;
	}

	handle = xtreeFind(xymonrrdtree, service);
	if (handle == xtreeEnd(xymonrrdtree)) 
		return NULL;
	else {
		return (xymonrrd_t *)xtreeData(xymonrrdtree, handle);
	}
}

xymongraph_t *find_xymon_graph(char *rrdname)
{
	/* Lookup an entry in the xymongraphs table */
	xymongraph_t *grec;
	int found = 0;
	char *dchar;

	rrd_setup();
	grec = xymongraphs; 
	while (!found && (grec->xymonrrdname != NULL)) {
		found = (strncmp(grec->xymonrrdname, rrdname, strlen(grec->xymonrrdname)) == 0);
		if (found) {
			/* Check that it's not a partial match, e.g. "ftp" matches "ftps" */
			dchar = rrdname + strlen(grec->xymonrrdname);
			if ( (*dchar != '.') && (*dchar != ',') && (*dchar != '\0') ) found = 0;
		}

		if (!found) grec++;
	}

	return (found ? grec : NULL);
}


static char *xymon_graph_text(char *hostname, char *dispname, char *service, int bgcolor,
			      xymongraph_t *graphdef, int itemcount, hg_stale_rrds_t nostale, const char *fmt,
			      int locatorbased, time_t starttime, time_t endtime)
{
	STATIC_SBUF_DEFINE(rrdurl);
	static int gwidth = 0, gheight = 0;
	SBUF_DEFINE(svcurl);
	int rrdparturlsize;
	char rrdservicename[100];
	char *cgiurl = xgetenv("CGIBINURL");

	MEMDEFINE(rrdservicename);

	if (locatorbased) {
		char *qres = locator_query(hostname, ST_RRD, &cgiurl);
		if (!qres) {
			errprintf("Cannot find RRD files for host %s\n", hostname);
			return "";
		}
	}

	if (!gwidth) {
		gwidth = atoi(xgetenv("RRDWIDTH"));
		gheight = atoi(xgetenv("RRDHEIGHT"));
	}

	dbgprintf("rrdlink_url: host %s, rrd %s (partname:%s, maxgraphs:%d, count=%d)\n", 
		hostname, 
		graphdef->xymonrrdname, textornull(graphdef->xymonpartname), graphdef->maxgraphs, itemcount);

	if ((service != NULL) && (strcmp(graphdef->xymonrrdname, "tcp") == 0)) {
		snprintf(rrdservicename, sizeof(rrdservicename), "tcp:%s", service);
	}
	else if ((service != NULL) && (strcmp(graphdef->xymonrrdname, "ncv") == 0)) {
		snprintf(rrdservicename, sizeof(rrdservicename), "ncv:%s", service);
	}
	else if ((service != NULL) && (strcmp(graphdef->xymonrrdname, "devmon") == 0)) {
		snprintf(rrdservicename, sizeof(rrdservicename), "devmon:%s", service);
	}
	else {
		strncpy(rrdservicename, graphdef->xymonrrdname, sizeof(rrdservicename));
	}

	SBUF_MALLOC(svcurl, 
		    2048                    + 
		    strlen(cgiurl)          +
		    strlen(hostname)        + 
		    strlen(rrdservicename)  + 
		    strlen(urlencode(dispname ? dispname : hostname)));

	rrdparturlsize = 2048 +
			 strlen(fmt)        +
			 3*svcurl_buflen    +
			 strlen(rrdservicename) +
			 strlen(xgetenv("XYMONSKIN"));

	if (rrdurl == NULL) {
		SBUF_MALLOC(rrdurl, rrdparturlsize);
	}
	*rrdurl = '\0';

	{
		SBUF_DEFINE(rrdparturl);
		int first = 1;
		int step;

		/* The item count comes from status content (a linecount override
		 * or a count= marker), so an absurd or negative value must not
		 * drive the part loop into building a giant page - such a graph
		 * renders unsliced instead. */
		if ((itemcount < 0) || (itemcount > 4096)) itemcount = 0;

		step = (graphdef->maxgraphs > 0 ? graphdef->maxgraphs : 5);
		if (itemcount) {
			/* Spread itemcount instances evenly over the needed number of
			 * graphs. gcount is the graph count (ceil); the per-graph step
			 * must round UP too, otherwise a count that gcount does not
			 * divide leaves every graph under-filled below maxgraphs and
			 * spawns extra graphs - e.g. 25 items at maxgraphs=2 gives
			 * gcount=13 but a floored step=1, so 25 single-item graphs
			 * instead of 13. Rounding up yields step=2 (last graph holds
			 * the remainder), never exceeding maxgraphs. */
			int gcount = (itemcount / step); if ((gcount*step) != itemcount) gcount++;
			step = ((itemcount + gcount - 1) / gcount);
		}

		SBUF_MALLOC(rrdparturl, rrdparturlsize);
		do {
			if (itemcount > 0) {
				snprintf(svcurl, svcurl_buflen, 
					"%s/showgraph.sh?host=%s&amp;service=%s&amp;graph_width=%d&amp;graph_height=%d&amp;first=%d&amp;count=%d", 
					cgiurl, hostname, rrdservicename, 
					gwidth, gheight,
					first, step);
			}
			else {
				snprintf(svcurl, svcurl_buflen,
					"%s/showgraph.sh?host=%s&amp;service=%s&amp;graph_width=%d&amp;graph_height=%d", 
					cgiurl, hostname, rrdservicename,
					gwidth, gheight);
			}

			strncat(svcurl, "&amp;disp=", (svcurl_buflen - strlen(svcurl)));
			strncat(svcurl, urlencode(dispname ? dispname : hostname), (svcurl_buflen - strlen(svcurl)));

			if (nostale == HG_WITHOUT_STALE_RRDS) strncat(svcurl, "&amp;nostale", (svcurl_buflen - strlen(svcurl)));
			if (bgcolor != -1) snprintf(svcurl+strlen(svcurl), (svcurl_buflen - strlen(svcurl)), "&amp;color=%s", colorname(bgcolor));
			snprintf(svcurl+strlen(svcurl), (svcurl_buflen - strlen(svcurl)), "&amp;graph_start=%d&amp;graph_end=%d", (int)starttime, (int)endtime);

			snprintf(rrdparturl, rrdparturl_buflen, fmt, rrdservicename, svcurl, svcurl, rrdservicename, svcurl, xgetenv("XYMONSKIN"), xgetenv("IMAGEFILETYPE"));
			if ((strlen(rrdparturl) + strlen(rrdurl) + 1) >= rrdurl_buflen) {
				SBUF_REALLOC(rrdurl, rrdurl_buflen + strlen(rrdparturl) + 4096);
			}
			strncat(rrdurl, rrdparturl, (rrdurl_buflen - strlen(rrdurl)));
			first += step;
		} while (first <= itemcount);
		xfree(rrdparturl);
	}

	dbgprintf("URLtext: %s\n", rrdurl);

	xfree(svcurl);

	MEMUNDEFINE(rrdservicename);

	return rrdurl;
}

char *xymon_graph_data(char *hostname, char *dispname, char *service, int bgcolor,
			xymongraph_t *graphdef, int itemcount,
			hg_stale_rrds_t nostale, hg_link_t wantmeta, int locatorbased,
			time_t starttime, time_t endtime)
{
	return xymon_graph_text(hostname, dispname, 
				 service, bgcolor, graphdef, 
				 itemcount, nostale,
				 ((wantmeta == HG_META_LINK) ? metafmt : xymonlinkfmt),
				 locatorbased, starttime, endtime);
}


rrdtpldata_t *setup_template(char *params[])
{
	int i;
	rrdtpldata_t *result;
	rrdtplnames_t *nam;
	int dsindex = 1;

	result = (rrdtpldata_t *)calloc(1, sizeof(rrdtpldata_t));
	result->dsnames = xtreeNew(strcmp);

	for (i = 0; (params[i]); i++) {
		if (strncasecmp(params[i], "DS:", 3) == 0) {
			char *pname, *pend;

			pname = params[i] + 3;
			pend = strchr(pname, ':');
			if (pend) {
				int plen = (pend - pname);

				nam = (rrdtplnames_t *)calloc(1, sizeof(rrdtplnames_t));
				nam->idx = dsindex++;

				if (result->template == NULL) {
					result->template = (char *)malloc(plen + 1);
					*result->template = '\0';
					nam->dsnam = (char *)malloc(plen+1); strncpy(nam->dsnam, pname, plen); nam->dsnam[plen] = '\0';
				}
				else {
					/* Hackish way of getting the colon delimiter */
					pname--; plen++;
					result->template = (char *)realloc(result->template, strlen(result->template) + plen + 1);
					nam->dsnam = (char *)malloc(plen); strncpy(nam->dsnam, pname+1, plen-1); nam->dsnam[plen-1] = '\0';
				}
				strncat(result->template, pname, plen);

				xtreeAdd(result->dsnames, nam->dsnam, nam);
			}
		}
	}

	return result;
}


