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
extern void fsidx_flush(char *rrddir, char *hostname);
extern void fsidx_flush_all(char *rrddir);
extern void fsidx_drop(char *rrddir, char *hostname);

/* Reader side (CGIs, htmllog): number of fresh index entries whose filename
 * is "<prefix>.<instance>.rrd", or -1 when the host has no readable index
 * (callers keep their previous behaviour). maxage 0 = no freshness cut. */
extern int fsidx_count_prefix(char *hostname, char *prefix, time_t maxage);

#endif
