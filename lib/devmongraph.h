/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* This is a library module, part of libxymon.                                */
/* Parser/collector for DEVMON RRD and DEVMON GRAPH markers carried in        */
/* status payloads. Used by the column page renderer to discover which        */
/* graph-definitions to display.                                              */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                           */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#ifndef __DEVMONGRAPH_H_
#define __DEVMONGRAPH_H_

#include <stdio.h>
#include <time.h>

#include "xymonrrd.h"

/*
 * Defensive caps for marker parsing. Names are used downstream as
 * graph-definition lookup keys and URL parameters, so they must be
 * bounded both in count and in size.
 */
#define DEVMON_GRAPH_NAMELEN_MAX 64
#define DEVMON_GRAPH_MAX         256

typedef struct devmongraphs_t {
	char **names;
	int    count;
	int    allocated;
	int    oom;
} devmongraphs_t;

/*
 * Context for rendering the collected markers to an output stream.
 * Filled by the caller; passed unchanged to devmongraphs_render().
 */
typedef struct devmongraph_render_ctx_t {
	FILE         *output;
	char         *hostname;
	char         *displayname;
	char         *service;
	int           color;
	int           linecount;
	int           locatorbased;
	time_t        starttime;
	time_t        endtime;
	xymongraph_t *fallback;  /* used when a marker name has no exact gdef */
} devmongraph_render_ctx_t;

/*
 * Initialize an empty collection. After this, devmongraphs_count() == 0
 * and devmongraphs_oom() == 0.
 */
extern void devmongraphs_init(devmongraphs_t *g);

/*
 * Quick check: does this line look like it starts with a DEVMON
 * marker prefix? Used by callers that scan a buffer line-by-line and
 * want to special-case marker lines (e.g. to reset a line counter)
 * without committing the name to the collection yet.
 */
extern int devmongraphs_is_marker_line(const char *line);

/*
 * Quick check: is this rrdname the legacy "devmon" catch-all (used
 * by TEST2RRD entries like `temp=devmon`, `if_load=devmon`, ...)?
 * Used by callers that special-case devmon columns when deciding
 * whether to assume a graph exists before scanning for markers.
 */
extern int devmongraphs_is_devmon_rrdname(const char *rrdname);

/*
 * Inspect one line. If it carries a valid DEVMON marker, add the
 * marker's graph name to the collection. Two marker forms are
 * recognized:
 *
 *   <!--DEVMON RRD: <graphname> <dir> <max>          (real RRD payload)
 *   <!--DEVMON GRAPH: <graphname> <source> <dir> <max>
 *                                                    (alias / extra view)
 *
 * Lines that are not markers, names that fail validation, names already
 * present, or additions beyond DEVMON_GRAPH_MAX are silently ignored
 * (return 0). On allocation failure the collection is freed, the sticky
 * `oom` flag is set, and -1 is returned.
 *
 * Returns:
 *   1 if a new name was added
 *   0 if nothing was added (no marker / invalid / duplicate / over cap)
 *  -1 on OOM
 */
extern int devmongraphs_add_line(devmongraphs_t *g, const char *line);

/*
 * Scan a multi-line text buffer (e.g. a Xymon status message body)
 * for DEVMON markers and add every distinct name to the collection.
 * Lines are split on '\n' and stripped of leading whitespace before
 * being passed to devmongraphs_add_line(). The buffer itself is not
 * modified.
 *
 * Returns the number of new names added, or -1 on OOM.
 */
extern int devmongraphs_scan(devmongraphs_t *g, const char *text);

/* Number of unique marker names currently collected. */
extern int devmongraphs_count(const devmongraphs_t *g);

/* The i-th name (0 <= i < count). Returns NULL on out-of-range index. */
extern const char *devmongraphs_name(const devmongraphs_t *g, int i);

/* Sticky out-of-memory flag (non-zero after a failed allocation). */
extern int devmongraphs_oom(const devmongraphs_t *g);

/* Free all names and reset the collection. */
extern void devmongraphs_free(devmongraphs_t *g);

/*
 * Render every collected marker as an <IMG ...> graph entry written
 * to ctx->output. For each marker name we:
 *   1. Look up the same-named graph-definition via find_xymon_graph().
 *   2. Fall back to ctx->fallback if the lookup misses (preserves the
 *      legacy "devmon" catch-all behavior; logged at debug level).
 *   3. Skip with an errprintf if both lookups fail.
 *   4. Otherwise produce the graph URL via xymon_graph_data().
 */
extern void devmongraphs_render(const devmongraphs_t *g,
                                const devmongraph_render_ctx_t *ctx);

#endif
