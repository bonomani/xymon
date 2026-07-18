/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* The writer-kept fileset index. See filesetindex.h for the contract.       */
/*                                                                            */
/* Writer model: an in-memory tree per host, seeded on first touch from the  */
/* existing index file - or, when none exists, from a one-off scan of the    */
/* host's RRD directory (the rebuild path after deletion/corruption).        */
/* Flushes are atomic (tmp + rename) and merge with the on-disk file under   */
/* flock, because the status- and data-channel xymond_rrd instances both     */
/* write the same hosts; last-write timestamps merge by max. Timestamp-only  */
/* changes are flushed at most every FSIDX_FLUSHIVL seconds; a new or        */
/* scanned entry flushes immediately.                                        */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                          */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),      */
/* version 2. See the file "COPYING" for details.                            */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char filesetindex_rcsid[] = "$Id$";

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>

#include "libxymon.h"

#define FSIDX_NAME ".fileset-index"
#define FSIDX_HEADER "# xymon fileset index v1"
#define FSIDX_FLUSHIVL 300

/* FSIDX_SPECMAX / FSIDX_LINEMAX live in filesetindex.h (readers outside
 * this file need the line bound too). The baseline field is bounded by
 * the channel line length; keep the header's literal in sync with it. */
#if defined(MAX_LINE_LEN) && (MAX_LINE_LEN > 16384)
#error "FSIDX_LINEMAX (filesetindex.h) assumes MAX_LINE_LEN <= 16384"
#endif

typedef struct fsidx_host_t {
	void *files;		/* rrdfn (char*) -> (time_t) last data write, cast in a slot */
	int dirty_new;		/* an entry was added since the last flush */
	int dirty_ts;		/* only timestamps moved since the last flush */
	time_t lastflush;
} fsidx_host_t;

typedef struct fsidx_entry_t {
	char *fn;
	time_t ts;
	char *units;		/* "ds:unit[,ds:unit...]" or NULL */
	char *heartbeats;	/* "ds:heartbeat[,...]" as currently declared, or NULL */
	char *thresholds;	/* "base:relop-operand:sev[,...]" or NULL */
	char *dsnames;		/* "ds1,ds2,...": positional DS names (for flat values) */
	char *baseline;		/* flat instance: its value string; no RRD file exists */
	time_t since;		/* ... unchanged since this data timestamp */
	int bl_cleared;		/* materialized this run: weak merges must not re-add b= */
	time_t gen;		/* when the schema fields (u/h/d/t) were last declared live */
} fsidx_entry_t;

static void *fsidx_hosts = NULL;	/* hostname -> fsidx_host_t */
static char *fsidx_pending_units = NULL;	/* sticky per-block writer state, see fsidx_set_units() */
static char *fsidx_pending_thresholds = NULL;	/* ditto, see fsidx_set_thresholds() */
static char *fsidx_pending_dsnames = NULL;	/* ditto: "ds1,ds2" - positional names for flat values */
static char *fsidx_pending_heartbeats = NULL;	/* ditto: "ds:heartbeat[,...]" - the declared heartbeats */

static void fsidx_path(char *buf, size_t bufsz, const char *rrddir, const char *hostname, const char *suffix)
{
	snprintf(buf, bufsz, "%s/%s/%s%s", rrddir, hostname, FSIDX_NAME, suffix);
}

/* strong units (a live write's declaration) replace what the entry has;
 * weak units (merged from the on-disk file) only fill an empty slot. */
static void fsidx_set(fsidx_host_t *h, const char *fn, time_t ts, const char *units, int strongunits)
{
	xtreePos_t handle = xtreeFind(h->files, (char *)fn);
	fsidx_entry_t *e;

	if (handle == xtreeEnd(h->files)) {
		e = (fsidx_entry_t *)calloc(1, sizeof(fsidx_entry_t));
		e->fn = strdup(fn);
		e->ts = ts;
		xtreeAdd(h->files, e->fn, e);
		h->dirty_new = 1;
	}
	else {
		e = (fsidx_entry_t *)xtreeData(h->files, handle);
		if (ts > e->ts) { e->ts = ts; h->dirty_ts = 1; }
	}

	if (units && (strongunits || !e->units)) {
		if (!e->units || strcmp(e->units, units)) {
			if (e->units) xfree(e->units);
			e->units = strdup(units);
			h->dirty_new = 1;	/* schema info: flush immediately */
		}
	}
}

static void fsidx_set_entry_thresholds(fsidx_host_t *h, const char *fn, const char *thr, int strong)
{
	xtreePos_t handle = xtreeFind(h->files, (char *)fn);
	fsidx_entry_t *e;

	if (handle == xtreeEnd(h->files)) return;
	e = (fsidx_entry_t *)xtreeData(h->files, handle);
	if (thr && (strong || !e->thresholds)) {
		if (!e->thresholds || strcmp(e->thresholds, thr)) {
			if (e->thresholds) xfree(e->thresholds);
			e->thresholds = strdup(thr);
			h->dirty_new = 1;
		}
	}
}

static void fsidx_set_entry_heartbeats(fsidx_host_t *h, const char *fn, const char *hb, int strong)
{
	xtreePos_t handle = xtreeFind(h->files, (char *)fn);
	fsidx_entry_t *e;

	if (handle == xtreeEnd(h->files)) return;
	e = (fsidx_entry_t *)xtreeData(h->files, handle);
	if (hb && (strong || !e->heartbeats)) {
		if (!e->heartbeats || strcmp(e->heartbeats, hb)) {
			if (e->heartbeats) xfree(e->heartbeats);
			e->heartbeats = strdup(hb);
			h->dirty_new = 1;
		}
	}
}

/* Replace one schema field outright (newer declaration adopted from the
 * other writer's disk state). Returns 1 when the value changed. */
static int fsidx_adopt_field(char **slot, const char *val)
{
	if (!val && !*slot) return 0;
	if (val && *slot && (strcmp(*slot, val) == 0)) return 0;
	if (*slot) xfree(*slot);
	*slot = (val ? strdup(val) : NULL);
	return 1;
}

/* Merge the on-disk index (possibly written by the other channel's writer)
 * into the in-memory tree. The schema fields (u/h/d/t) merge by their
 * declaration timestamp (g=): a NEWER disk bundle replaces ours outright,
 * an older one is ignored, equal generations weak-fill empty slots (the
 * legacy g-less behavior). This is what stops the two writers from
 * ping-ponging a changed spec: the stale process adopts instead of
 * republishing. Unknown trailing fields are ignored - future versions
 * carry record extensions there. */
static void fsidx_load_file(fsidx_host_t *h, const char *fn)
{
	FILE *fd = fopen(fn, "r");
	char line[FSIDX_LINEMAX];

	if (!fd) return;
	while (fgets(line, sizeof(line), fd)) {
		char *name, *tsstr, *tok, *units, *thr, *bl, *dsn, *hb, *sp = NULL;
		time_t ts, gen;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		tsstr = (name ? strtok_r(NULL, " \t\r\n", &sp) : NULL);
		if (!name || !tsstr) continue;
		ts = (time_t)atol(tsstr);
		if (ts <= 0) continue;
		units = NULL; thr = NULL; bl = NULL; dsn = NULL; hb = NULL; gen = 0;
		while ((tok = strtok_r(NULL, " \t\r\n", &sp)) != NULL) {
			if (strncmp(tok, "u=", 2) == 0) units = tok+2;
			else if (strncmp(tok, "h=", 2) == 0) hb = tok+2;
			else if (strncmp(tok, "t=", 2) == 0) thr = tok+2;
			else if (strncmp(tok, "b=", 2) == 0) bl = tok+2;
			else if (strncmp(tok, "d=", 2) == 0) dsn = tok+2;
			else if (strncmp(tok, "g=", 2) == 0) gen = (time_t)atol(tok+2);
			/* unknown fields: future record extensions, ignored */
		}
		/* The writers cap every spec at FSIDX_SPECMAX and the baseline
		 * at the channel line length - that is what makes FSIDX_LINEMAX
		 * an invariant. A hand-edited/corrupt file must not smuggle an
		 * oversized field back in, or the NEXT flush writes a record
		 * that splits on every later read. */
		if (units && (strlen(units) > FSIDX_SPECMAX)) units = NULL;
		if (hb && (strlen(hb) > FSIDX_SPECMAX)) hb = NULL;
		if (thr && (strlen(thr) > FSIDX_SPECMAX)) thr = NULL;
		if (dsn && (strlen(dsn) > FSIDX_SPECMAX)) dsn = NULL;
		if (bl && (strlen(bl) > MAX_LINE_LEN)) bl = NULL;	/* the writer's bound, see FSIDX_LINEMAX */
		fsidx_set(h, name, ts, NULL, 0);
		{
			xtreePos_t eh = xtreeFind(h->files, name);
			fsidx_entry_t *e;

			if (eh == xtreeEnd(h->files)) continue;
			e = (fsidx_entry_t *)xtreeData(h->files, eh);
			if (gen > e->gen) {
				/* Newer declaration on disk: adopt the bundle */
				int changed = 0;
				changed |= fsidx_adopt_field(&e->units, units);
				changed |= fsidx_adopt_field(&e->heartbeats, hb);
				changed |= fsidx_adopt_field(&e->dsnames, dsn);
				changed |= fsidx_adopt_field(&e->thresholds, thr);
				e->gen = gen;
				if (changed) h->dirty_new = 1;
			}
			else if (gen == e->gen) {
				if (units) fsidx_set(h, name, ts, units, 0);
				if (hb) fsidx_set_entry_heartbeats(h, name, hb, 0);
				if (thr) fsidx_set_entry_thresholds(h, name, thr, 0);
				if (dsn && !e->dsnames) e->dsnames = strdup(dsn);
			}
			/* gen < e->gen: ours is the newer declaration, ignore disk */
		}
		if (bl) {
			/* "b=<since>,<values>": a flat instance's baseline. Weak
			 * merge - live writer state wins over the file's copy. */
			char *comma = strchr(bl, ',');
			if (comma) {
				xtreePos_t bh = xtreeFind(h->files, name);
				if (bh != xtreeEnd(h->files)) {
					fsidx_entry_t *e = (fsidx_entry_t *)xtreeData(h->files, bh);
					if (!e->baseline && !e->bl_cleared) {
						*comma = '\0';
						e->since = (time_t)atol(bl);
						e->baseline = strdup(comma+1);
					}
				}
			}
		}
	}
	fclose(fd);
}

/* One-off rebuild: seed from the RRD files actually on disk. Runs only when
 * a host has no index file at all (first run, deletion, corruption). */
static void fsidx_scan_dir(fsidx_host_t *h, const char *rrddir, const char *hostname)
{
	char dirname[PATH_MAX];
	DIR *dir;
	struct dirent *d;

	snprintf(dirname, sizeof(dirname), "%s/%s", rrddir, hostname);
	dir = opendir(dirname);
	if (!dir) return;
	while ((d = readdir(dir)) != NULL) {
		size_t len = strlen(d->d_name);
		char fpath[PATH_MAX];
		struct stat st;

		if ((len < 5) || (strcmp(d->d_name + len - 4, ".rrd") != 0)) continue;
		snprintf(fpath, sizeof(fpath), "%s/%s", dirname, d->d_name);
		if ((stat(fpath, &st) != 0) || !S_ISREG(st.st_mode)) continue;
		fsidx_set(h, d->d_name, st.st_mtime, NULL, 0);
	}
	closedir(dir);
}

static fsidx_host_t *fsidx_gethost(char *rrddir, char *hostname)
{
	xtreePos_t handle;
	fsidx_host_t *h;

	if (!fsidx_hosts) fsidx_hosts = xtreeNew(strcasecmp);
	handle = xtreeFind(fsidx_hosts, hostname);
	if (handle != xtreeEnd(fsidx_hosts)) return (fsidx_host_t *)xtreeData(fsidx_hosts, handle);

	h = (fsidx_host_t *)calloc(1, sizeof(fsidx_host_t));
	h->files = xtreeNew(strcmp);
	xtreeAdd(fsidx_hosts, strdup(hostname), h);

	/* Seed: prefer the existing index; else scan the directory once */
	{
		char fn[PATH_MAX];
		struct stat st;

		fsidx_path(fn, sizeof(fn), rrddir, hostname, "");
		if (stat(fn, &st) == 0) fsidx_load_file(h, fn);
		/* An absent file - or one that yielded no entries (crash
		 * leftovers, corruption) - triggers the one-off rebuild scan */
		if (xtreeFirst(h->files) == xtreeEnd(h->files)) fsidx_scan_dir(h, rrddir, hostname);
		/* Seeding counts as new content so the file materializes */
		h->dirty_new = 1;
	}

	return h;
}

/* Strong-apply the sticky live declarations to one entry and stamp its
 * declaration generation - the merge authority for the schema bundle. */
static void fsidx_apply_pendings(fsidx_host_t *h, fsidx_entry_t *e)
{
	int declared = 0;

	if (fsidx_pending_units) { if (fsidx_adopt_field(&e->units, fsidx_pending_units)) h->dirty_new = 1; declared = 1; }
	if (fsidx_pending_heartbeats) { if (fsidx_adopt_field(&e->heartbeats, fsidx_pending_heartbeats)) h->dirty_new = 1; declared = 1; }
	if (fsidx_pending_dsnames) { if (fsidx_adopt_field(&e->dsnames, fsidx_pending_dsnames)) h->dirty_new = 1; declared = 1; }
	if (fsidx_pending_thresholds) { if (fsidx_adopt_field(&e->thresholds, fsidx_pending_thresholds)) h->dirty_new = 1; declared = 1; }
	if (declared) e->gen = getcurrenttime(NULL);
}

/* Event-time bookkeeping: ensure the entry exists (a new one is stamped
 * with the sample's own timestamp, once) and record the live schema
 * declarations. Does NOT advance an existing entry's freshness - that
 * belongs to fsidx_note_commit, after rrdtool accepts the data. */
void fsidx_note_schema(char *rrddir, char *hostname, char *rrdfn, time_t ts)
{
	fsidx_host_t *h;
	xtreePos_t handle;
	fsidx_entry_t *e;

	if (!rrddir || !hostname || !rrdfn || !(*rrdfn) || (ts <= 0)) return;
	h = fsidx_gethost(rrddir, hostname);
	handle = xtreeFind(h->files, rrdfn);
	if (handle == xtreeEnd(h->files)) {
		e = (fsidx_entry_t *)calloc(1, sizeof(fsidx_entry_t));
		e->fn = strdup(rrdfn);
		e->ts = ts;
		xtreeAdd(h->files, e->fn, e);
		h->dirty_new = 1;
	}
	else e = (fsidx_entry_t *)xtreeData(h->files, handle);
	fsidx_apply_pendings(h, e);
}

/* Commit-time freshness: the update was ACCEPTED by rrdtool, so the
 * entry's last-write advances to the applied data timestamp. A rejected
 * update never reaches here - a chronically broken producer goes stale
 * on schedule instead of looking forever fresh. */
void fsidx_note_commit(char *rrddir, char *hostname, char *rrdfn, time_t ts)
{
	fsidx_host_t *h;

	if (!rrddir || !hostname || !rrdfn || !(*rrdfn) || (ts <= 0)) return;
	h = fsidx_gethost(rrddir, hostname);
	fsidx_set(h, rrdfn, ts, NULL, 0);
}

/* Sticky positional DS names for following writes, same lifecycle as
 * fsidx_set_units(). Needed on flat records: their value string is
 * positional, and consumers (AGGDS) map values to datasets by name. */
void fsidx_set_dsnames(char *dsnspec)
{
	if (fsidx_pending_dsnames) { xfree(fsidx_pending_dsnames); fsidx_pending_dsnames = NULL; }
	if (dsnspec && (strlen(dsnspec) > FSIDX_SPECMAX)) return;
	if (dsnspec && *dsnspec) fsidx_pending_dsnames = strdup(dsnspec);
}

/* Sticky declared heartbeats for following writes, same lifecycle as
 * fsidx_set_units(). Spec: "ds:heartbeat[,...]", covering EVERY declared
 * DS (defaults included) so a changed declaration replaces the record
 * outright - the schema-reconcile tool compares files against this. */
void fsidx_set_heartbeats(char *hbspec)
{
	if (fsidx_pending_heartbeats) { xfree(fsidx_pending_heartbeats); fsidx_pending_heartbeats = NULL; }
	if (hbspec && (strlen(hbspec) > FSIDX_SPECMAX)) {
		errprintf("fileset index: heartbeat spec too long (%d), ignored\n", (int)strlen(hbspec));
		return;
	}
	if (hbspec && *hbspec) fsidx_pending_heartbeats = strdup(hbspec);
}

/* Sticky per-block writer state: the block writer declares the units of
 * the DS specs it is about to create files from; every note_write until
 * the next call carries them. NULL clears (a block without units, another
 * handler's writes). Same pattern as the writer's lazy gate. */
void fsidx_set_units(char *unitspec)
{
	if (fsidx_pending_units) { xfree(fsidx_pending_units); fsidx_pending_units = NULL; }
	if (unitspec && (strlen(unitspec) > FSIDX_SPECMAX)) {
		errprintf("fileset index: unit spec too long (%d), ignored\n", (int)strlen(unitspec));
		return;
	}
	if (unitspec && *unitspec) fsidx_pending_units = strdup(unitspec);
}

/* Sticky threshold relations for following writes, same lifecycle as
 * fsidx_set_units(). Spec: "base:relop-operand:sev[,...]". */
void fsidx_set_thresholds(char *thrspec)
{
	if (fsidx_pending_thresholds) { xfree(fsidx_pending_thresholds); fsidx_pending_thresholds = NULL; }
	if (thrspec && (strlen(thrspec) > FSIDX_SPECMAX)) {
		errprintf("fileset index: threshold spec too long (%d), ignored\n", (int)strlen(thrspec));
		return;
	}
	if (thrspec && *thrspec) fsidx_pending_thresholds = strdup(thrspec);
}

/* The lazy gate's durable baseline: a flat instance is an index entry
 * with a (value, since) record and NO RRD file. The writer consults and
 * maintains it here (in the loaded host tree - no file IO per update);
 * flushes persist it as "b=<since>,<values>". */
char *fsidx_baseline_get(char *rrddir, char *hostname, char *rrdfn, time_t *since)
{
	fsidx_host_t *h;
	xtreePos_t handle;
	fsidx_entry_t *e;

	if (!rrddir || !hostname || !rrdfn) return NULL;
	h = fsidx_gethost(rrddir, hostname);
	handle = xtreeFind(h->files, rrdfn);
	if (handle == xtreeEnd(h->files)) return NULL;
	e = (fsidx_entry_t *)xtreeData(h->files, handle);
	if (!e->baseline) return NULL;
	if (since) *since = e->since;
	return e->baseline;
}

void fsidx_baseline_set(char *rrddir, char *hostname, char *rrdfn, char *values, time_t ts)
{
	fsidx_host_t *h;
	xtreePos_t handle;
	fsidx_entry_t *e;

	if (!rrddir || !hostname || !rrdfn || !values) return;
	h = fsidx_gethost(rrddir, hostname);
	/* Ensure the entry and refresh last-seen: no rrdtool involved for a
	 * baseline, so event time IS commit time here. */
	fsidx_set(h, rrdfn, ts, NULL, 0);
	handle = xtreeFind(h->files, rrdfn);
	if (handle == xtreeEnd(h->files)) return;
	e = (fsidx_entry_t *)xtreeData(h->files, handle);
	fsidx_apply_pendings(h, e);
	if (!e->baseline) {
		e->baseline = strdup(values);
		e->since = ts;
		h->dirty_new = 1;
	}
	else if (e->ts < ts) {
		/* still flat: keep since, refresh the entry's last-seen */
		e->ts = ts;
		h->dirty_ts = 1;
	}
}

void fsidx_baseline_clear(char *rrddir, char *hostname, char *rrdfn)
{
	fsidx_host_t *h;
	xtreePos_t handle;
	fsidx_entry_t *e;

	if (!rrddir || !hostname || !rrdfn) return;
	h = fsidx_gethost(rrddir, hostname);
	handle = xtreeFind(h->files, rrdfn);
	if (handle == xtreeEnd(h->files)) return;
	e = (fsidx_entry_t *)xtreeData(h->files, handle);
	if (e->baseline) {
		xfree(e->baseline); e->baseline = NULL;
		e->since = 0;
		h->dirty_new = 1;	/* the record changed kind: flush now */
	}
	/* Tombstone either way: the file exists now, so the on-disk b= (ours
	 * or the other channel's) must not weak-merge back in. */
	e->bl_cleared = 1;
}

/* Iterate the loaded host's flat records (in-memory tree only - the
 * writer's own state; no file IO). cb receives (rrdfn, last-seen ts,
 * values, dsnames-or-NULL, userdata). */
void fsidx_flat_foreach(char *hostname, void (*cb)(const char *, time_t, const char *, const char *, void *), void *userdata)
{
	xtreePos_t handle, fh;
	fsidx_host_t *h;

	if (!fsidx_hosts || !hostname || !cb) return;
	handle = xtreeFind(fsidx_hosts, hostname);
	if (handle == xtreeEnd(fsidx_hosts)) return;
	h = (fsidx_host_t *)xtreeData(fsidx_hosts, handle);
	for (fh = xtreeFirst(h->files); (fh != xtreeEnd(h->files)); fh = xtreeNext(h->files, fh)) {
		fsidx_entry_t *e = (fsidx_entry_t *)xtreeData(h->files, fh);
		if (e->baseline) cb(e->fn, e->ts, e->baseline, e->dsnames, userdata);
	}
}

void fsidx_flush(char *rrddir, char *hostname)
{
	xtreePos_t handle, fh;
	fsidx_host_t *h;
	char fn[PATH_MAX], tmpfn[PATH_MAX];
	FILE *fd;
	int lockfd;
	time_t now = getcurrenttime(NULL);

	if (!fsidx_hosts || !rrddir || !hostname) return;
	handle = xtreeFind(fsidx_hosts, hostname);
	if (handle == xtreeEnd(fsidx_hosts)) return;
	h = (fsidx_host_t *)xtreeData(fsidx_hosts, handle);

	if (!h->dirty_new && !h->dirty_ts) return;
	if (!h->dirty_new && ((now - h->lastflush) < FSIDX_FLUSHIVL)) return;

	fsidx_path(fn, sizeof(fn), rrddir, hostname, "");
	/* Per-process tmp name: even unserialized writers must never share one */
	{
		char pidsuf[32];
		snprintf(pidsuf, sizeof(pidsuf), ".tmp.%d", (int)getpid());
		fsidx_path(tmpfn, sizeof(tmpfn), rrddir, hostname, pidsuf);
	}

	/* The status- and data-channel writers share this file: serialize the
	 * read-merge-write. The lock lives on a DEDICATED lockfile - locking
	 * the index itself would be meaningless after the rename replaces it
	 * (the blocked process would acquire the orphaned inode's lock while
	 * the file it guards is already a different one). */
	{
		char lockfn[PATH_MAX];
		fsidx_path(lockfn, sizeof(lockfn), rrddir, hostname, ".lock");
		lockfd = open(lockfn, O_RDWR | O_CREAT, 0644);
	}
	if (lockfd == -1) {
		/* Host directory may not exist yet (no file ever created) */
		return;
	}
	if (flock(lockfd, LOCK_EX) != 0) {
		errprintf("fileset index: cannot lock %s/%s: %s - skipping flush\n", hostname, FSIDX_NAME, strerror(errno));
		close(lockfd);
		return;
	}

	fsidx_load_file(h, fn);

	fd = fopen(tmpfn, "w");
	if (fd) {
		int ok;

		fprintf(fd, "%s\n", FSIDX_HEADER);
		for (fh = xtreeFirst(h->files); (fh != xtreeEnd(h->files)); fh = xtreeNext(h->files, fh)) {
			fsidx_entry_t *e = (fsidx_entry_t *)xtreeData(h->files, fh);
			fprintf(fd, "%s %ld", e->fn, (long)e->ts);
			if (e->units) fprintf(fd, " u=%s", e->units);
			if (e->heartbeats) fprintf(fd, " h=%s", e->heartbeats);
			if (e->dsnames) fprintf(fd, " d=%s", e->dsnames);
			if (e->thresholds) fprintf(fd, " t=%s", e->thresholds);
			if (e->gen) fprintf(fd, " g=%ld", (long)e->gen);
			if (e->baseline) fprintf(fd, " b=%ld,%s", (long)e->since, e->baseline);
			fprintf(fd, "\n");
		}
		ok = (fclose(fd) == 0);
		if (ok && (rename(tmpfn, fn) == 0)) {
			/* Only a published file clears the dirty state - a failed
			 * flush must retry, or a one-shot change is lost */
			h->dirty_new = h->dirty_ts = 0;
			h->lastflush = now;
		}
		else {
			errprintf("fileset index: cannot publish %s: %s\n", tmpfn, strerror(errno));
			unlink(tmpfn);
		}
	}
	else {
		errprintf("fileset index: cannot write %s: %s\n", tmpfn, strerror(errno));
	}

	flock(lockfd, LOCK_UN);
	close(lockfd);
}

void fsidx_flush_all(char *rrddir)
{
	xtreePos_t handle;

	if (!fsidx_hosts) return;
	for (handle = xtreeFirst(fsidx_hosts); (handle != xtreeEnd(fsidx_hosts)); handle = xtreeNext(fsidx_hosts, handle)) {
		fsidx_host_t *h = (fsidx_host_t *)xtreeData(fsidx_hosts, handle);
		/* Force: shutdown must not lose timestamp-only changes */
		if (h->dirty_ts) h->dirty_new = 1;
		fsidx_flush(rrddir, (char *)xtreeKey(fsidx_hosts, handle));
	}
}

/* Must-write flush for one host: promotes timestamp-only dirt past the
 * FLUSHIVL throttle. For the moments when the file must be current NOW -
 * a rename is about to move it, and the in-memory tree that holds the
 * newer timestamps is about to be dropped. */
void fsidx_flush_now(char *rrddir, char *hostname)
{
	fsidx_host_t *h;
	xtreePos_t handle;

	if (!fsidx_hosts || !hostname) return;
	handle = xtreeFind(fsidx_hosts, hostname);
	if (handle == xtreeEnd(fsidx_hosts)) return;
	h = (fsidx_host_t *)xtreeData(fsidx_hosts, handle);
	if (h->dirty_ts) h->dirty_new = 1;
	fsidx_flush(rrddir, hostname);
}

void fsidx_drop(char *rrddir, char *hostname)
{
	xtreePos_t handle, fh;
	fsidx_host_t *h;
	char fn[PATH_MAX];

	fsidx_path(fn, sizeof(fn), rrddir, hostname, "");
	unlink(fn);

	if (!fsidx_hosts) return;
	handle = xtreeFind(fsidx_hosts, hostname);
	if (handle == xtreeEnd(fsidx_hosts)) return;
	h = (fsidx_host_t *)xtreeData(fsidx_hosts, handle);

	/* Reset in place: xtree deletion leaves tombstones. The host tree is
	 * reseeded (scan) on its next write, so a re-added host starts from
	 * what is actually on disk. */
	for (fh = xtreeFirst(h->files); (fh != xtreeEnd(h->files)); fh = xtreeNext(h->files, fh)) {
		fsidx_entry_t *e = (fsidx_entry_t *)xtreeData(h->files, fh);
		xfree(e->fn);
		if (e->units) xfree(e->units);
		if (e->heartbeats) xfree(e->heartbeats);
		if (e->dsnames) xfree(e->dsnames);
		if (e->thresholds) xfree(e->thresholds);
		if (e->baseline) xfree(e->baseline);
		xfree(e);
	}
	xtreeDestroy(h->files);
	h->files = xtreeNew(strcmp);
	h->dirty_new = h->dirty_ts = 0;
	h->lastflush = 0;
}

/* Fetch one named field ("u=", "t=") from a file's index entry. */
static char *fsidx_field(char *hostname, char *rrdfn, const char *fieldtag)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[FSIDX_LINEMAX];
	char *result = NULL;
	size_t taglen = strlen(fieldtag);

	if (!hostname || !rrdfn) return NULL;
	snprintf(fn, sizeof(fn), "%s/%s/%s", xgetenv("XYMONRRDS"), hostname, FSIDX_NAME);
	fd = fopen(fn, "r");
	if (!fd) return NULL;

	while (!result && fgets(line, sizeof(line), fd)) {
		char *name, *tok, *sp = NULL;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		if (!name || strcmp(name, rrdfn)) continue;
		while ((tok = strtok_r(NULL, " \t\r\n", &sp)) != NULL) {
			if (strncmp(tok, fieldtag, taglen) == 0) { result = strdup(tok+taglen); break; }
		}
		break;
	}
	fclose(fd);

	return result;
}

char *fsidx_thresholds(char *hostname, char *rrdfn)
{
	return fsidx_field(hostname, rrdfn, "t=");
}

/* The per-DS units recorded for one file: a malloc'd "ds:unit[,...]"
 * spec, or NULL when the host has no index or the file no units. */
char *fsidx_units(char *hostname, char *rrdfn)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[FSIDX_LINEMAX];
	char *result = NULL;

	if (!hostname || !rrdfn) return NULL;
	snprintf(fn, sizeof(fn), "%s/%s/%s", xgetenv("XYMONRRDS"), hostname, FSIDX_NAME);
	fd = fopen(fn, "r");
	if (!fd) return NULL;

	while (!result && fgets(line, sizeof(line), fd)) {
		char *name, *tok, *sp = NULL;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		if (!name || strcmp(name, rrdfn)) continue;
		while ((tok = strtok_r(NULL, " \t\r\n", &sp)) != NULL) {
			if (strncmp(tok, "u=", 2) == 0) { result = strdup(tok+2); break; }
		}
		break;
	}
	fclose(fd);

	return result;
}

int fsidx_count_pattern(char *hostname, void *pattern, time_t maxage)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[FSIDX_LINEMAX];
	int count = 0;
	time_t now = getcurrenttime(NULL);

	if (!hostname || !pattern) return -1;
	snprintf(fn, sizeof(fn), "%s/%s/%s", xgetenv("XYMONRRDS"), hostname, FSIDX_NAME);
	fd = fopen(fn, "r");
	if (!fd) return -1;

	while (fgets(line, sizeof(line), fd)) {
		char *name, *tsstr, *sp = NULL;
		time_t ts;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		tsstr = (name ? strtok_r(NULL, " \t\r\n", &sp) : NULL);
		if (!name || !tsstr) continue;
		if (!matchregex(name, (pcre2_code *)pattern)) continue;
		ts = (time_t)atol(tsstr);
		if (maxage && ((now - ts) > maxage)) continue;
		count++;
	}
	fclose(fd);

	return count;
}

int fsidx_count_prefix(char *hostname, char *prefix, time_t maxage)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[FSIDX_LINEMAX];
	size_t plen;
	int count = 0;
	time_t now = getcurrenttime(NULL);

	if (!hostname || !prefix) return -1;
	snprintf(fn, sizeof(fn), "%s/%s/%s", xgetenv("XYMONRRDS"), hostname, FSIDX_NAME);
	fd = fopen(fn, "r");
	if (!fd) return -1;

	plen = strlen(prefix);
	while (fgets(line, sizeof(line), fd)) {
		char *name, *tsstr, *sp = NULL;
		size_t nlen;
		time_t ts;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		tsstr = (name ? strtok_r(NULL, " \t\r\n", &sp) : NULL);
		if (!name || !tsstr) continue;

		nlen = strlen(name);
		/* '.' is the instance separator; ',' is its legacy spelling
		 * (pre-encode disk/devmon files) - both are real instances of
		 * this prefix, and the gdef-side matchers accept both. */
		if ((nlen <= plen + 5) || (strncmp(name, prefix, plen) != 0) ||
		    ((name[plen] != '.') && (name[plen] != ','))) continue;
		if (strcmp(name + nlen - 4, ".rrd") != 0) continue;
		ts = (time_t)atol(tsstr);
		if (maxage && ((now - ts) > maxage)) continue;
		count++;
	}
	fclose(fd);

	return count;
}
