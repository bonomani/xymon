/*----------------------------------------------------------------------------*/
/* Xymon message daemon.                                                      */
/*                                                                            */
/* This Xymon worker module saves the client messages that arrive on the      */
/* CLICHG channel, for use when looking at problems with a host.              */
/*                                                                            */
/* Copyright (C) 2004-2011 Henrik Storner <henrik@hswn.dk>                    */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char rcsid[] = "$Id$";

#include <sys/stat.h>
#include <sys/types.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/time.h>
#include <limits.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <libgen.h>

#include "libxymon.h"
#include "xymond_worker.h"

#include <signal.h>


#define MAX_META 20	/* The maximum number of meta-data items in a message */

#define DEFAULT_RECENTPERIOD 3600	/* --recent-period fallback, in seconds */
#define DEFAULT_RECENTCOUNT  5		/* --recent-count fallback */
#define MAX_RECENTCOUNT      10000	/* --recent-count cap: bounds the per-host history allocation */

typedef struct savetimes_t {
	char *hostname;
	time_t *tstamp;		/* Ring of the 'maxrecentcount' most recent save times */
	int oldest;		/* Oldest slot in tstamp[] - the next one overwritten */
} savetimes_t;
void * savetimes;

static char *clientlogdir = NULL;
int nextfscheck = 0;


void sig_handler(int signum)
{
	/*
	 * Why this? Because we must have our own signal handler installed to call wait()
	 */
	switch (signum) {
	  case SIGCHLD:
		  break;

	  case SIGHUP:
		  nextfscheck = 0;
		  break;
	}
}

/*
 * Parse the value of a numeric "--option=N" argument. strtol (not atoi)
 * so garbage is told apart from a real number and overflow is not
 * undefined behaviour. Garbage and values below 'minval' are rejected
 * in favour of 'dflt'; values above 'maxval' are capped.
 */
static int parse_int_opt(char *arg, int minval, int maxval, int dflt)
{
	char *p = strchr(arg, '=')+1, *ep;
	long v = strtol(p, &ep, 10);

	if ((ep == p) || (*ep) || (v < minval)) {
		errprintf("%s is invalid (must be %d or more), using default %d\n", arg, minval, dflt);
		return dflt;
	}
	if (v > maxval) {
		errprintf("%s is too large, capping at %d\n", arg, maxval);
		return maxval;
	}
	return (int)v;
}

void update_locator_hostdata(char *id)
{
	DIR *fd;
	struct dirent *d;

	fd = opendir(clientlogdir);
	if (fd == NULL) {
		errprintf("Cannot scan directory %s\n", clientlogdir);
		return;
	}

	while ((d = readdir(fd)) != NULL) {
		if (*(d->d_name) == '.') continue;
		locator_register_host(d->d_name, ST_HOSTDATA, id);
	}

	closedir(fd);
}


int main(int argc, char *argv[])
{
	char *msg;
	int running;
	int argi, seq;
	int recentperiod = DEFAULT_RECENTPERIOD;
	int maxrecentcount = DEFAULT_RECENTCOUNT;
	int logdirfull = 0;
	int minlogspace = 5;
	struct sigaction sa;

	/* Handle program options. */
	for (argi = 1; (argi < argc); argi++) {
                if (argnmatch(argv[argi], "--logdir=")) {
			clientlogdir = strchr(argv[argi], '=')+1;
		}
		else if (argnmatch(argv[argi], "--recent-period=")) {
			/* Minutes. 0 disables the throttle: the cutoff lands at
			 * "now", so no earlier save is ever inside the window. */
			recentperiod = 60*parse_int_opt(argv[argi], 0, INT_MAX/60, DEFAULT_RECENTPERIOD/60);
		}
		else if (argnmatch(argv[argi], "--recent-count=")) {
			/* 0 keeps its historical meaning: never save anything. The
			 * cap keeps the per-host save-time history (8 bytes per
			 * slot) at a sane size. */
			maxrecentcount = parse_int_opt(argv[argi], 0, MAX_RECENTCOUNT, DEFAULT_RECENTCOUNT);
		}
		else if (argnmatch(argv[argi], "--minimum-free=")) {
			minlogspace = atoi(strchr(argv[argi], '=')+1);
		}
		else if (strcmp(argv[argi], "--debug") == 0) {
			/*
			 * A global "debug" variable is available. If
			 * it is set, then "dbgprintf()" outputs debug messages.
			 */
			debug = 1;
		}
		else if (net_worker_option(argv[argi])) {
			/* Handled in the subroutine */
		}
	}

	if (clientlogdir == NULL) clientlogdir = xgetenv("CLIENTLOGS");
	if (clientlogdir == NULL) {
		clientlogdir = (char *)malloc(strlen(xgetenv("XYMONVAR")) + 10);
		sprintf(clientlogdir, "%s/hostdata", xgetenv("XYMONVAR"));
	}

	save_errbuf = 0;

	/* Do the network stuff if needed */
	net_worker_run(ST_HOSTDATA, LOC_STICKY, update_locator_hostdata);

	setup_signalhandler("xymond_hostdata");
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = sig_handler;
	signal(SIGCHLD, SIG_IGN);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_DFL);

	savetimes = xtreeNew(strcasecmp);

	running = 1;
	while (running) {
		char *eoln, *restofmsg, *p;
		char *metadata[MAX_META+1];
		int metacount;

		msg = get_xymond_message(C_CLICHG, "xymond_hostdata", &seq, NULL);
		if (msg == NULL) {
			/*
			 * get_xymond_message will return NULL if xymond_channel closes
			 * the input pipe. We should shutdown when that happens.
			 */
			running = 0;
			continue;
		}

		if (nextfscheck < gettimer()) {
			logdirfull = (chkfreespace(clientlogdir, minlogspace, minlogspace) != 0);
			if (logdirfull) errprintf("Hostdata directory %s has less than %d%% free space - disabling save of data for 5 minutes\n", clientlogdir, minlogspace);
			nextfscheck = gettimer() + 300;
		}

		/* Split the message in the first line (with meta-data), and the rest */
 		eoln = strchr(msg, '\n');
		if (eoln) {
			*eoln = '\0';
			restofmsg = eoln+1;
		}
		else {
			restofmsg = "";
		}

		metacount = 0; 
		memset(&metadata, 0, sizeof(metadata));
		p = gettok(msg, "|");
		while (p && (metacount < MAX_META)) {
			metadata[metacount++] = p;
			p = gettok(NULL, "|");
		}
		metadata[metacount] = NULL;

		/* @@clichg|timestamp|sender|hostname|testname|... */
		if ((metacount > 4) && (strncmp(metadata[0], "@@clichg", 8) == 0)) {
			xtreePos_t handle;
			savetimes_t *itm;
			time_t now = gettimer();
			time_t cutoff;
			char hostdir[PATH_MAX];
			char fn[PATH_MAX];
			FILE *fd;

			/* --recent-count=0: never save anything */
			if (maxrecentcount == 0) continue;

			/* metadata[3] is the hostname */
			handle = xtreeFind(savetimes, metadata[3]);
			if (handle != xtreeEnd(savetimes)) {
				itm = (savetimes_t *)xtreeData(savetimes, handle);
			}
			else {
				itm = (savetimes_t *)calloc(1, sizeof(savetimes_t));
				if (itm) {
					itm->hostname = strdup(metadata[3]);
					/* Sized from --recent-count: deciding "N or more saves in the
					 * window" only ever needs the N most recent save times. */
					itm->tstamp = (time_t *)calloc(maxrecentcount, sizeof(time_t));
				}
				if (!itm || !itm->hostname || !itm->tstamp) {
					errprintf("Out of memory tracking saves for host %s, dropping message\n", metadata[3]);
					if (itm) { free(itm->hostname); free(itm->tstamp); free(itm); }
					continue;
				}
				xtreeAdd(savetimes, itm->hostname, itm);
			}

			/*
			 * Save unless the host already had its --recent-count saves
			 * in the past 'recentperiod' seconds. tstamp[] is a ring of
			 * the most recent save times, with 'oldest' indexing the
			 * oldest slot, so the limit is reached exactly when that
			 * slot is still inside the window.
			 *
			 * Floor the cutoff at 0: gettimer() is monotonic (seconds
			 * since boot), so a never-used slot's calloc'ed zero is not
			 * "long ago" - without the floor it would land inside the
			 * window whenever uptime is below 'recentperiod', and all
			 * client data would be dropped unlogged until the machine
			 * has been up that long.
			 */
			cutoff = (now > recentperiod) ? (now - recentperiod) : 0;
			if (!logdirfull && (itm->tstamp[itm->oldest] <= cutoff)) {
				int written, closestatus, ok = 1;

				itm->tstamp[itm->oldest] = now;
				itm->oldest = (itm->oldest + 1) % maxrecentcount;

				snprintf(hostdir, sizeof(hostdir), "%s/%s", clientlogdir, metadata[3]);
				mkdir(hostdir, S_IRWXU|S_IRGRP|S_IXGRP|S_IROTH|S_IXOTH);
				if (snprintf(fn, sizeof(fn), "%s/%s", hostdir, metadata[4]) >= (int)sizeof(fn)) {
					errprintf("Hostdata filename too long for host %s, dropping message\n", metadata[3]);
					continue;
				}
				fd = fopen(fn, "w");
				if (fd == NULL) {
					errprintf("Cannot create file %s: %s\n", fn, strerror(errno));
					continue;
				}
				written = fwrite(restofmsg, 1, strlen(restofmsg), fd);
				if (written != strlen(restofmsg)) {
					errprintf("Cannot write hostdata file %s: %s\n", fn, strerror(errno));
					closestatus = fclose(fd);	/* Ignore any close errors */
					ok = 0;
				}
				else {
					closestatus = fclose(fd);
					if (closestatus != 0) {
						errprintf("Cannot write hostdata file %s: %s\n", fn, strerror(errno));
						ok = 0;
					}
				}

				if (!ok) remove(fn);
			}
		}

		/*
		 * A "shutdown" message is sent when the master daemon
		 * terminates. The child workers should shutdown also.
		 */
		else if (strncmp(metadata[0], "@@shutdown", 10) == 0) {
			running = 0;
			continue;
		}
		else if (strncmp(metadata[0], "@@idle", 6) == 0) {
			/* Ignored */
			continue;
		}

		/*
		 * A "logrotate" message is sent when the Xymon logs are
		 * rotated. The child workers must re-open their logfiles,
		 * typically stdin and stderr - the filename is always
		 * provided in the XYMONCHANNEL_LOGFILENAME environment.
		 */
		else if (strncmp(metadata[0], "@@logrotate", 11) == 0) {
			char *fn = xgetenv("XYMONCHANNEL_LOGFILENAME");
			if (fn && strlen(fn)) {
				reopen_file(fn, "a", stdout);
				reopen_file(fn, "a", stderr);
			}
			continue;
		}

		else if ((metacount > 3) && (strncmp(metadata[0], "@@drophost", 10) == 0)) {
			/* @@drophost|timestamp|sender|hostname */
			char hostdir[PATH_MAX];
			snprintf(hostdir, sizeof(hostdir), "%s/%s", clientlogdir, basename(metadata[3]));
			dropdirectory(hostdir, 1);
		}

		else if ((metacount > 4) && (strncmp(metadata[0], "@@renamehost", 12) == 0)) {
			/* @@renamehost|timestamp|sender|hostname|newhostname */
			char oldhostdir[PATH_MAX], newhostdir[PATH_MAX];
			snprintf(oldhostdir, sizeof(oldhostdir), "%s/%s", clientlogdir, basename(metadata[3]));
			snprintf(newhostdir, sizeof(newhostdir), "%s/%s", clientlogdir, basename(metadata[4]));
			rename(oldhostdir, newhostdir);

			if (net_worker_locatorbased()) locator_rename_host(metadata[3], metadata[4], ST_HOSTDATA);
		}
		else if (strncmp(metadata[0], "@@reload", 8) == 0) {
			/* Do nothing */
		}
	}

	return 0;
}

