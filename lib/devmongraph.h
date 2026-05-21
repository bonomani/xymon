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
 * Initialize an empty collection. After this, devmongraphs_count() == 0
 * and devmongraphs_oom() == 0.
 */
extern void devmongraphs_init(devmongraphs_t *g);

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

/* Number of unique marker names currently collected. */
extern int devmongraphs_count(const devmongraphs_t *g);

/* The i-th name (0 <= i < count). Returns NULL on out-of-range index. */
extern const char *devmongraphs_name(const devmongraphs_t *g, int i);

/* Sticky out-of-memory flag (non-zero after a failed allocation). */
extern int devmongraphs_oom(const devmongraphs_t *g);

/* Free all names and reset the collection. */
extern void devmongraphs_free(devmongraphs_t *g);

#endif
