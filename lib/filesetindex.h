/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* The writer-kept fileset index: one small per-host file recording every    */
/* RRD file the writer maintains, with its last data-write timestamp.        */
/* Bookkeeping happens at event time in xymond_rrd (the single creator of    */
/* RRD files); renderers read the one file instead of re-counting status     */
/* lines or scanning directories. The record format is extensible: units,    */
/* threshold relations and lazy baselines ride the same entries later.       */
/*                                                                            */
/* File: $XYMONRRDS/<host>/.fileset-index, "<rrdfn> <ts> [k=v ...]" lines.   */
/* Readers must ignore fields beyond the first two.                          */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                          */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),      */
/* version 2. See the file "COPYING" for details.                            */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#ifndef __FILESETINDEX_H__
#define __FILESETINDEX_H__

#include <time.h>

/* Writer side (xymond_rrd) */
extern void fsidx_note_write(char *rrddir, char *hostname, char *rrdfn, time_t ts);
extern void fsidx_set_units(char *unitspec);	/* sticky "ds:unit[,...]" for following writes; NULL clears */
extern void fsidx_set_thresholds(char *thrspec);	/* sticky "base:relop-operand:sev[,...]"; NULL clears */

/* Durable lazy baselines: a flat instance is an entry with a (value,
 * since) record and no RRD file. get returns the live value string (do
 * not free) or NULL; set learns or refreshes last-seen (keeping since);
 * clear removes it when the file materializes. */
extern char *fsidx_baseline_get(char *rrddir, char *hostname, char *rrdfn, time_t *since);
extern void fsidx_baseline_set(char *rrddir, char *hostname, char *rrdfn, char *values, time_t ts);
extern void fsidx_baseline_clear(char *rrddir, char *hostname, char *rrdfn);
extern void fsidx_flush(char *rrddir, char *hostname);
extern void fsidx_flush_all(char *rrddir);
extern void fsidx_drop(char *rrddir, char *hostname);

/* Reader side (CGIs, htmllog): number of fresh index entries whose filename
 * is "<prefix>.<instance>.rrd", or -1 when the host has no readable index
 * (callers keep their previous behaviour). maxage 0 = no freshness cut. */
extern int fsidx_count_prefix(char *hostname, char *prefix, time_t maxage);

/* Same, but entries matched by a compiled regex (a gdef's FNPATTERN).
 * `pattern` is a pcre2_code* passed as void* to keep this header free of
 * the PCRE include-order dance. */
extern int fsidx_count_pattern(char *hostname, void *pattern, time_t maxage);

/* The per-DS units recorded for one file: malloc'd "ds:unit[,...]" spec,
 * or NULL (no index, or no units declared). Caller frees. */
extern char *fsidx_units(char *hostname, char *rrdfn);

/* The threshold relations recorded for one file: malloc'd
 * "base:relop-operand:sev[,...]" spec, or NULL. Caller frees. */
extern char *fsidx_thresholds(char *hostname, char *rrdfn);

#endif
