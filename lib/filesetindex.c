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
} fsidx_entry_t;

static void *fsidx_hosts = NULL;	/* hostname -> fsidx_host_t */
static char *fsidx_pending_units = NULL;	/* sticky per-block writer state, see fsidx_set_units() */

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

/* Merge the on-disk index (possibly written by the other channel's writer)
 * into the in-memory tree. Unknown trailing fields are ignored - future
 * versions carry units/thresholds/baselines there. */
static void fsidx_load_file(fsidx_host_t *h, const char *fn)
{
	FILE *fd = fopen(fn, "r");
	char line[PATH_MAX + 64];

	if (!fd) return;
	while (fgets(line, sizeof(line), fd)) {
		char *name, *tsstr, *tok, *units, *sp = NULL;
		time_t ts;

		if (line[0] == '#') continue;
		name = strtok_r(line, " \t\r\n", &sp);
		tsstr = (name ? strtok_r(NULL, " \t\r\n", &sp) : NULL);
		if (!name || !tsstr) continue;
		ts = (time_t)atol(tsstr);
		if (ts <= 0) continue;
		units = NULL;
		while ((tok = strtok_r(NULL, " \t\r\n", &sp)) != NULL) {
			if (strncmp(tok, "u=", 2) == 0) units = tok+2;
			/* unknown fields: future record extensions, ignored */
		}
		fsidx_set(h, name, ts, units, 0);
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
		else fsidx_scan_dir(h, rrddir, hostname);
		/* Seeding counts as new content so the file materializes */
		h->dirty_new = 1;
	}

	return h;
}

void fsidx_note_write(char *rrddir, char *hostname, char *rrdfn, time_t ts)
{
	fsidx_host_t *h;

	if (!rrddir || !hostname || !rrdfn || !(*rrdfn)) return;
	h = fsidx_gethost(rrddir, hostname);
	fsidx_set(h, rrdfn, ts, fsidx_pending_units, 1);
}

/* Sticky per-block writer state: the block writer declares the units of
 * the DS specs it is about to create files from; every note_write until
 * the next call carries them. NULL clears (a block without units, another
 * handler's writes). Same pattern as the writer's lazy gate. */
void fsidx_set_units(char *unitspec)
{
	if (fsidx_pending_units) { xfree(fsidx_pending_units); fsidx_pending_units = NULL; }
	if (unitspec && *unitspec) fsidx_pending_units = strdup(unitspec);
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
	fsidx_path(tmpfn, sizeof(tmpfn), rrddir, hostname, ".tmp");

	/* The status- and data-channel writers share this file: serialize the
	 * read-merge-write, or one channel's entries vanish. */
	lockfd = open(fn, O_RDWR | O_CREAT, 0644);
	if (lockfd == -1) {
		/* Host directory may not exist yet (no file ever created) */
		return;
	}
	flock(lockfd, LOCK_EX);

	fsidx_load_file(h, fn);

	fd = fopen(tmpfn, "w");
	if (fd) {
		fprintf(fd, "%s\n", FSIDX_HEADER);
		for (fh = xtreeFirst(h->files); (fh != xtreeEnd(h->files)); fh = xtreeNext(h->files, fh)) {
			fsidx_entry_t *e = (fsidx_entry_t *)xtreeData(h->files, fh);
			if (e->units) fprintf(fd, "%s %ld u=%s\n", e->fn, (long)e->ts, e->units);
			else fprintf(fd, "%s %ld\n", e->fn, (long)e->ts);
		}
		fclose(fd);
		if (rename(tmpfn, fn) != 0) {
			errprintf("fileset index: cannot rename %s: %s\n", tmpfn, strerror(errno));
			unlink(tmpfn);
		}
		h->dirty_new = h->dirty_ts = 0;
		h->lastflush = now;
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
		xfree(e);
	}
	xtreeDestroy(h->files);
	h->files = xtreeNew(strcmp);
	h->dirty_new = h->dirty_ts = 0;
	h->lastflush = 0;
}

/* The per-DS units recorded for one file: a malloc'd "ds:unit[,...]"
 * spec, or NULL when the host has no index or the file no units. */
char *fsidx_units(char *hostname, char *rrdfn)
{
	char fn[PATH_MAX];
	FILE *fd;
	char line[PATH_MAX + 64];
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
	char line[PATH_MAX + 64];
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
	char line[PATH_MAX + 64];
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
		if ((nlen <= plen + 5) || (strncmp(name, prefix, plen) != 0) || (name[plen] != '.')) continue;
		if (strcmp(name + nlen - 4, ".rrd") != 0) continue;

		ts = (time_t)atol(tsstr);
		if (maxage && ((now - ts) > maxage)) continue;
		count++;
	}
	fclose(fd);

	return count;
}
