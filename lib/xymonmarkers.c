/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* Parser for self-describing metric markers in status messages. See         */
/* xymonmarkers.h for the wire format.                                       */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                          */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),      */
/* version 2. See the file "COPYING" for details.                            */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char xymonmarkers_rcsid[] = "$Id$";

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "libxymon.h"

/* Copy and validate a marker name: [A-Za-z0-9_-]{1,NAMELEN_MAX}, terminated
 * by whitespace or end-of-line. Returns a malloc'ed copy, or NULL. */
static char *marker_name(char *p)
{
	char *result;
	int len = 0;

	while (p[len] && (isalnum((int)p[len]) || (p[len] == '_') || (p[len] == '-'))) len++;
	if ((len == 0) || (len > XYMON_MARKER_NAMELEN_MAX)) return NULL;
	if (p[len] && (p[len] != ' ') && (p[len] != '\t') && (p[len] != '\n') && (p[len] != '\r')) return NULL;

	result = (char *)malloc(len + 1);
	memcpy(result, p, len); result[len] = '\0';

	return result;
}

static xymonmarker_t *find_or_add(xymonmarker_t **head, xymonmarker_t **tail, int *count, char *name)
{
	xymonmarker_t *walk;

	for (walk = *head; (walk && strcmp(walk->name, name)); walk = walk->next) ;
	if (walk) { xfree(name); return walk; }

	if (*count >= XYMON_MARKER_MAX) { xfree(name); return NULL; }

	walk = (xymonmarker_t *)calloc(1, sizeof(xymonmarker_t));
	walk->name = name;
	walk->instancespec = -1;
	if (*tail) (*tail)->next = walk; else *head = walk;
	*tail = walk;
	(*count)++;

	return walk;
}

xymonmarker_t *xymon_markers_parse(char *msg)
{
	xymonmarker_t *head = NULL, *tail = NULL;
	int count = 0;
	char *bol, *eoln;
	xymonmarker_t *block = NULL;	/* non-NULL while inside a METRICS/DEVMON block */

	if (!msg) return NULL;

	for (bol = msg; (bol && *bol); bol = (eoln ? eoln+1 : NULL)) {
		eoln = strchr(bol, '\n');

		/* Marker banners are recognized even inside an open block, like
		 * the block writer does - a new banner simply starts the next
		 * block. Everything else on block lines is content. */
		if (strncmp(bol, XYMON_METRICS_MARKER, strlen(XYMON_METRICS_MARKER)) == 0) {
			char *name = marker_name(bol + strlen(XYMON_METRICS_MARKER));
			if (name) {
				block = find_or_add(&head, &tail, &count, name);
				if (block) block->store = 1;
			}
		}
		else if (strncmp(bol, DEVMON_RRD_MARKER, strlen(DEVMON_RRD_MARKER)) == 0) {
			/* Legacy devmon banner: store and show combined */
			char *name = marker_name(bol + strlen(DEVMON_RRD_MARKER));
			if (name) {
				block = find_or_add(&head, &tail, &count, name);
				if (block) { block->store = 1; block->show = 1; }
			}
		}
		else if (strncmp(bol, XYMON_GRAPH_MARKER, strlen(XYMON_GRAPH_MARKER)) == 0) {
			char *p = bol + strlen(XYMON_GRAPH_MARKER);
			char *name = marker_name(p);
			if (name) {
				xymonmarker_t *marker = find_or_add(&head, &tail, &count, name);
				if (marker) {
					marker->show = 1;

					/* Optional attributes up to end-of-line / closing marker */
					while (*p && (*p != '\n') && strncmp(p, "-->", 3)) {
						if (strncmp(p, "instances=all", 13) == 0) {
							marker->instancespec = 0;
							p += 9;
						}
						else if ((strncmp(p, "instances=", 10) == 0) && isdigit((int)p[10])) {
							marker->instancespec = atoi(p+10);
							p += 6; while (isdigit((int)*p)) p++;
						}
						else p++;
					}
				}
			}
		}
		else if (block) {
			/* Inside a data block: count the lines that create RRD files.
			 * The writer only writes "instance value" lines - exactly two
			 * space-separated fields - so count precisely those, or the
			 * paging count would exceed the files that exist. */
			if (strncmp(bol, "-->", 3) == 0) {
				block = NULL;
			}
			else if (strncmp(bol, "DS:", 3) == 0) {
				/* dataset definitions, not an instance */
			}
			else {
				char *p = bol + strspn(bol, " ");
				size_t f1 = strcspn(p, " \r\n");
				if ((f1 > 0) && (p[f1] == ' ')) {
					char *q = p + f1 + strspn(p + f1, " ");
					size_t f2 = strcspn(q, " \r\n");
					char *rest = q + f2 + strspn(q + f2, " ");
					if ((f2 > 0) && ((*rest == '\0') || (*rest == '\n') || (*rest == '\r'))) block->blockinstances++;
				}
			}
		}
	}

	/* A block left unclosed at end-of-message is malformed: whatever was
	 * counted is the status text, not instances. Unknown count degrades
	 * to an unsliced render instead of an inflated slicing. */
	if (block) block->blockinstances = 0;

	return head;
}

void xymon_markers_free(xymonmarker_t *head)
{
	xymonmarker_t *walk, *zombie;

	for (walk = head; (walk); ) {
		zombie = walk; walk = walk->next;
		xfree(zombie->name);
		xfree(zombie);
	}
}

/*
 * The paging count used when rendering this marker's graph: an explicit
 * instances= attribute wins; else the number of instance lines in the message's
 * own METRICS block (exact by construction); else 0 = render unsliced.
 */
int xymon_marker_instancecount(xymonmarker_t *marker)
{
	if (marker->instancespec >= 0) return marker->instancespec;
	if (marker->store && (marker->blockinstances > 0)) return marker->blockinstances;
	return 0;
}

/*
 * Cheap probe used by the RRD-writer dispatch: does this message carry a
 * data block? Only line-anchored banners count.
 */
int xymon_markers_have_store(char *msg)
{
	char *p;

	if (!msg) return 0;

	for (p = msg; (p); ) {
		p = strstr(p, "<!--");
		if (!p) return 0;
		if ((p == msg) || (*(p-1) == '\n')) {
			if (strncmp(p, XYMON_METRICS_MARKER, strlen(XYMON_METRICS_MARKER)) == 0) return 1;
			if (strncmp(p, DEVMON_RRD_MARKER, strlen(DEVMON_RRD_MARKER)) == 0) return 1;
		}
		p += 4;
	}

	return 0;
}
