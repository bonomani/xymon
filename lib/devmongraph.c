/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* This is a library module, part of libxymon.                                */
/* Parser/collector for DEVMON RRD and DEVMON GRAPH markers carried in        */
/* status payloads.                                                           */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                           */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char rcsid[] = "$Id$";

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "libxymon.h"

#include "devmongraph.h"

/*
 * A valid DEVMON marker name is a non-empty sequence of [A-Za-z0-9_-]
 * up to DEVMON_GRAPH_NAMELEN_MAX characters. This matches the names
 * used in devmon templates' `name:` option and what graph-definition
 * sections in graphs.cfg accept between `[` and `]`. Anything else is
 * rejected silently rather than fed downstream into URLs or HTML.
 */
static int is_valid_name(const char *name, int namelen)
{
	int i;

	if ((namelen <= 0) || (namelen > DEVMON_GRAPH_NAMELEN_MAX)) return 0;
	for (i = 0; i < namelen; i++) {
		unsigned char c = (unsigned char)name[i];
		if (!(isalnum(c) || (c == '_') || (c == '-'))) return 0;
	}
	return 1;
}

void devmongraphs_init(devmongraphs_t *g)
{
	g->names = NULL;
	g->count = 0;
	g->allocated = 0;
	g->oom = 0;
}

int devmongraphs_add_line(devmongraphs_t *g, const char *line)
{
	const char *marker_rrd   = "<!--DEVMON RRD: ";
	const char *marker_graph = "<!--DEVMON GRAPH: ";
	int markerlen;
	const char *name, *end;
	int namelen, i;
	char **tmp;
	char *namecopy;

	if (g->oom) return -1;
	if (line == NULL) return 0;

	if (strncmp(line, marker_rrd, strlen(marker_rrd)) == 0) {
		markerlen = strlen(marker_rrd);
	}
	else if (strncmp(line, marker_graph, strlen(marker_graph)) == 0) {
		markerlen = strlen(marker_graph);
	}
	else {
		return 0;
	}

	name = line + markerlen;
	while (*name && isspace((unsigned char)*name)) name++;
	end = name;
	while (*end && !isspace((unsigned char)*end)) end++;
	namelen = (int)(end - name);

	if (!is_valid_name(name, namelen)) return 0;

	/* deduplicate within this collection */
	for (i = 0; i < g->count; i++) {
		if (((int)strlen(g->names[i]) == namelen) &&
		    (strncmp(g->names[i], name, namelen) == 0))
			return 0;
	}

	/* hard cap */
	if (g->count >= DEVMON_GRAPH_MAX) return 0;

	/* grow the backing array if needed */
	if (g->count >= g->allocated) {
		int newsize = g->allocated + 4;

		tmp = (char **)realloc(g->names, newsize * sizeof(char *));
		if (tmp == NULL) {
			devmongraphs_free(g);
			g->oom = 1;
			return -1;
		}
		g->names = tmp;
		g->allocated = newsize;
	}

	namecopy = (char *)malloc(namelen + 1);
	if (namecopy == NULL) {
		devmongraphs_free(g);
		g->oom = 1;
		return -1;
	}
	strncpy(namecopy, name, namelen);
	namecopy[namelen] = '\0';

	g->names[g->count++] = namecopy;
	return 1;
}

int devmongraphs_count(const devmongraphs_t *g)
{
	return g->count;
}

const char *devmongraphs_name(const devmongraphs_t *g, int i)
{
	if ((i < 0) || (i >= g->count)) return NULL;
	return g->names[i];
}

int devmongraphs_oom(const devmongraphs_t *g)
{
	return g->oom;
}

void devmongraphs_free(devmongraphs_t *g)
{
	int i;

	if (g->names) {
		for (i = 0; i < g->count; i++) {
			if (g->names[i]) xfree(g->names[i]);
		}
		xfree(g->names);
	}
	g->names = NULL;
	g->count = 0;
	g->allocated = 0;
	g->oom = 0;
}
