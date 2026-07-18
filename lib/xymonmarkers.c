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

	len = strspn(p, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-");
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
	int block_metrics = 0;		/* current block opened by METRICS, not the legacy banner */
	int blockds = 0;		/* DS specs declared by the current block's first DS line */

	if (!msg) return NULL;

	for (bol = msg; (bol && *bol); bol = (eoln ? eoln+1 : NULL)) {
		char *close;
		int selfclosed;

		eoln = strchr(bol, '\n');
		/* A banner carrying its own "-->" is an empty, self-closed block. */
		close = strstr(bol, "-->");
		selfclosed = (close && ((eoln == NULL) || (close < eoln)));

		/* Marker banners are recognized even inside an open block, like
		 * the block writer does - a new banner simply starts the next
		 * block. Everything else on block lines is content. */
		if (strncmp(bol, XYMON_METRICS_MARKER, strlen(XYMON_METRICS_MARKER)) == 0) {
			char *name = marker_name(bol + strlen(XYMON_METRICS_MARKER));
			if (name) {
				block = find_or_add(&head, &tail, &count, name);
				block_metrics = 1;
				blockds = 0;
				if (block) {
					char *p = bol + strlen(XYMON_METRICS_MARKER);

					block->store = 1;
					/* banner attributes, up to end-of-line */
					while (*p && (*p != '\n')) {
						if ((strncmp(p, " lazy", 5) == 0) &&
						    ((p[5] == ' ') || (p[5] == '\n') || (p[5] == '\r') || (p[5] == '\0'))) block->lazy = 1;
						p++;
					}
				}
				if (selfclosed) block = NULL;
			}
		}
		else if (strncmp(bol, DEVMON_RRD_MARKER, strlen(DEVMON_RRD_MARKER)) == 0) {
			/* Legacy devmon banner: store and show combined */
			char *name = marker_name(bol + strlen(DEVMON_RRD_MARKER));
			if (name) {
				block = find_or_add(&head, &tail, &count, name);
				block_metrics = 0;
				blockds = 0;
				if (block) { block->store = 1; block->show = 1; }
				if (selfclosed) block = NULL;
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
						else if ((strncmp(p, "instances=", 10) == 0) && isdigit((unsigned char)p[10])) {
							marker->instancespec = atoi(p+10);
							p += 6; while (isdigit((unsigned char)*p)) p++;
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
				/* Dataset definitions, not an instance. The leading run
				 * of DS: tokens on the block's FIRST DS line is how many
				 * values an instance line must carry to create a file -
				 * exactly what the writer requires (it ignores later DS
				 * lines and stops at the first non-DS token). */
				if (blockds == 0) {
					char *p = bol;
					char *end = (eoln ? eoln : bol + strlen(bol));
					while (p < end) {
						while ((p < end) && (*p == ' ')) p++;
						if ((p >= end) || (strncmp(p, "DS:", 3) != 0)) break;
						blockds++;
						while ((p < end) && (*p != ' ')) p++;
					}
				}
			}
			else {
				char *p = bol + strspn(bol, " ");
				size_t kwlen = strspn(p, "ABCDEFGHIJKLMNOPQRSTUVWXYZ");
				size_t f1;

				/* In a METRICS block, an ALL-CAPS keyword ending in ':'
				 * opens a declaration line (DS: is the known one) - never
				 * an instance, even for keywords this parser has never
				 * heard of. Same contract as the block writer. Legacy
				 * DEVMON blocks predate the contract and may carry
				 * instances named like a keyword ("CPU:1"). */
				if (block_metrics && (kwlen > 0) && (p[kwlen] == ':')) continue;
				f1 = strcspn(p, " \r\n");
				if ((f1 > 0) && (p[f1] == ' ')) {
					char *q = p + f1 + strspn(p + f1, " ");
					size_t f2 = strcspn(q, " \r\n");
					char *rest = q + f2 + strspn(q + f2, " ");
					if ((f2 > 0) && ((*rest == '\0') || (*rest == '\n') || (*rest == '\r'))) {
						/* Count only lines the writer will actually
						 * write: one non-empty colon-separated value
						 * per declared DS, and a DS line must exist. */
						int vals = 0;
						size_t vi = 0;
						while (vi < f2) {
							while ((vi < f2) && (q[vi] == ':')) vi++;
							if (vi < f2) { vals++; while ((vi < f2) && (q[vi] != ':')) vi++; }
						}
						if ((blockds > 0) && (vals >= blockds)) block->blockinstances++;
					}
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
	/* A lazy block's file set is the EVER-active instances, which the
	 * current message cannot know (an instance that goes idle keeps its
	 * file) - a derived count would hide trailing files. Render
	 * unsliced unless an explicit instances= says otherwise. */
	if (marker->lazy) return 0;
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
