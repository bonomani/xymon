/*----------------------------------------------------------------------------*/
/* Xymon on-demand overview CGI.                                              */
/*                                                                            */
/* This CGI serves the xymongen-generated overview page, regenerating it      */
/* on demand when it is older than a configurable TTL. At most one           */
/* regeneration runs at a time; while one is in progress, other requests      */
/* are served the existing (stale) page immediately. This gives on-demand    */
/* freshness without the fixed xymongen timer, while keeping the             */
/* many-viewers robustness of pre-rendered pages: under load the render      */
/* cost stays bounded at one xymongen run per TTL regardless of the          */
/* number of viewers.                                                        */
/*                                                                            */
/* No CGI input (query string, cookies) is ever used; all behavior comes     */
/* from command-line options and the server environment.                     */
/*                                                                            */
/* Copyright (C) 2026 Bruno Manzoni                                          */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),      */
/* version 2. See the file "COPYING" for details.                            */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#include <sys/types.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

#include "libxymon.h"
#include "version.h"

char *reqenv[] = {
	"XYMONHOME",
	NULL
};

int main(int argc, char *argv[])
{
	int ttl = 60;			/* Serve cached page if younger than this (seconds) */
	int lockexpire = 300;		/* Consider a render-lock stale after this (seconds) */
	char *pagename = "xymon.html";	/* Page to serve, relative to XYMONWWWDIR */
	char *envarea = NULL;
	char pagefn[PATH_MAX];
	char lockfn[PATH_MAX];
	struct stat st;
	int argi, needrender, gotlock;
	time_t now;
	FILE *pagefd;
	char buf[8192];
	size_t n;

	for (argi = 1; (argi < argc); argi++) {
		if (argnmatch(argv[argi], "--env=")) {
			char *p = strchr(argv[argi], '=');
			loadenv(p+1, envarea);
		}
		else if (argnmatch(argv[argi], "--area=")) {
			char *p = strchr(argv[argi], '=');
			envarea = strdup(p+1);
		}
		else if (argnmatch(argv[argi], "--ttl=")) {
			ttl = atoi(strchr(argv[argi], '=')+1);
		}
		else if (argnmatch(argv[argi], "--lock-expire=")) {
			lockexpire = atoi(strchr(argv[argi], '=')+1);
		}
		else if (argnmatch(argv[argi], "--page=")) {
			pagename = strchr(argv[argi], '=')+1;
		}
		else if (argnmatch(argv[argi], "--debug")) {
			debug = 1;
		}
	}

	redirect_cgilog("dashboard");
	envcheck(reqenv);

	snprintf(pagefn, sizeof(pagefn), "%s/%s", xgetenv("XYMONWWWDIR"), pagename);
	snprintf(lockfn, sizeof(lockfn), "%s/dashboard-render.lck", xgetenv("XYMONTMP"));

	now = getcurrenttime(NULL);
	needrender = ((stat(pagefn, &st) != 0) || ((now - st.st_mtime) > ttl));

	if (needrender) {
		gotlock = (mkdir(lockfn, 0755) == 0);
		if (!gotlock && (errno == EEXIST)) {
			/* A render is already running - or a dead one left its lock behind */
			if ((stat(lockfn, &st) == 0) && ((now - st.st_mtime) > lockexpire)) {
				rmdir(lockfn);
				gotlock = (mkdir(lockfn, 0755) == 0);
			}
		}

		if (gotlock) {
			char cmd[PATH_MAX + 1024];
			char *genopts = getenv("XYMONGENOPTS");

			snprintf(cmd, sizeof(cmd), "%s/bin/xymongen %s >/dev/null 2>&1",
				 xgetenv("XYMONHOME"), (genopts ? genopts : ""));
			if (system(cmd) == -1) {
				errprintf("Could not run xymongen: %s\n", strerror(errno));
			}
			rmdir(lockfn);
		}
		/* Without the lock: someone else is rendering - serve the stale page below */
	}

	pagefd = fopen(pagefn, "r");
	if (pagefd == NULL) {
		printf("Status: 503\nContent-type: %s\n\n", xgetenv("HTMLCONTENTTYPE"));
		printf("<html><body><h1>Overview page not available</h1><p>xymongen has not produced %s yet.</p></body></html>\n", htmlquoted(pagename));
		return 1;
	}

	printf("Content-type: %s\n\n", xgetenv("HTMLCONTENTTYPE"));
	fflush(stdout);
	while ((n = fread(buf, 1, sizeof(buf), pagefd)) > 0) fwrite(buf, 1, n, stdout);
	fclose(pagefd);

	return 0;
}
