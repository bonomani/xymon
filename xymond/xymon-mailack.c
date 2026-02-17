/*----------------------------------------------------------------------------*/
/* Xymon mail-acknowledgment filter.                                          */
/*                                                                            */
/* This program runs from the Xymon users' .procmailrc file, and processes    */
/* incoming e-mails that are responses to alert mails that Xymon has sent     */
/* out.                                                                       */
/*                                                                            */
/* Copyright (C) 2004-2011 Henrik Storner <henrik@hswn.dk>                    */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char rcsid[] = "$Id$";

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include "libxymon.h"

int main(int argc, char *argv[])
{
	strbuffer_t *inbuf;
	char *ackbuf = NULL;
	char *subjectline = NULL;
	char *returnpathline = NULL;
	char *fromline = NULL;
	char *firsttxtline = NULL;
	int firsttxtline_alloc = 0;
	int inheaders = 1;
	char *p;
	pcre2_code *subjexp = NULL;
	int err, result;
	PCRE2_SIZE errofs;
	pcre2_match_data *ovector = NULL;
	char cookie[10];
	PCRE2_SIZE l = sizeof(cookie);
	int duration = 0;
	int argi;
	char *envarea = NULL;
	int rc = 0;

	for (argi=1; (argi < argc); argi++) {
		if (strcmp(argv[argi], "--debug") == 0) {
			debug = 1;
		}
		else if (argnmatch(argv[argi], "--env=")) {
			char *p = strchr(argv[argi], '=');
			loadenv(p+1, envarea);
		}
		else if (argnmatch(argv[argi], "--area=")) {
			char *p = strchr(argv[argi], '=');
			if (envarea) free(envarea);
			envarea = strdup(p+1);
		}
	}

	initfgets(stdin);
	inbuf = newstrbuffer(0);
	while (unlimfgets(inbuf, stdin)) {
		sanitize_input(inbuf, 0, 0);

		if (!inheaders) {
			/* We're in the message body. Look for a "delay=N" line here. */
			if ((strncasecmp(STRBUF(inbuf), "delay=", 6) == 0) || (strncasecmp(STRBUF(inbuf), "delay ", 6) == 0)) {
				duration = durationvalue(STRBUF(inbuf)+6);
				continue;
			}
			else if ((strncasecmp(STRBUF(inbuf), "ack=", 4) == 0) || (strncasecmp(STRBUF(inbuf), "ack ", 4) == 0)) {
				/* Some systems cannot generate a subject. Allow them to ack
				 * via text in the message body. */
				if (subjectline) free(subjectline);
				subjectline = (char *)malloc(STRBUFLEN(inbuf) + 1024);
				sprintf(subjectline, "Subject: Xymon [%s]", STRBUF(inbuf)+4);
			}
			else if (*STRBUF(inbuf) && !firsttxtline) {
				/* Save the first line of the message body, but ignore blank lines */
				firsttxtline = strdup(STRBUF(inbuf));
				firsttxtline_alloc = 1;
			}

			continue;	/* We don't care about the rest of the message body */
		}

		/* See if we're at the end of the mail headers */
		if (inheaders && (STRBUFLEN(inbuf) == 0)) { inheaders = 0; continue; }

		/* Is it one of those we want to keep ? */
		if (strncasecmp(STRBUF(inbuf), "return-path:", 12) == 0) {
			if (returnpathline) free(returnpathline);
			returnpathline = strdup(skipwhitespace(STRBUF(inbuf)+12));
		}
		else if (strncasecmp(STRBUF(inbuf), "from:", 5) == 0) {
			if (fromline && (fromline != returnpathline)) free(fromline);
			fromline = strdup(skipwhitespace(STRBUF(inbuf)+5));
		}
		else if (strncasecmp(STRBUF(inbuf), "subject:", 8) == 0) {
			if (subjectline) free(subjectline);
			subjectline = strdup(skipwhitespace(STRBUF(inbuf)+8));
		}
	}
	freestrbuffer(inbuf);

	/* No subject ? No deal */
	if (subjectline == NULL) {
		dbgprintf("Subject-line not found\n");
		rc = 1;
		goto cleanup;
	}

	/* Get the alert cookie */
	subjexp = pcre2_compile(".*(Xymon|Hobbit|BB)[ -]* \\[*(-*[0-9]+)[\\]!]*", PCRE2_ZERO_TERMINATED, PCRE2_CASELESS, &err, &errofs, NULL);
	if (subjexp == NULL) {
		dbgprintf("pcre compile failed - 1\n");
		rc = 2;
		goto cleanup;
	}
	ovector = pcre2_match_data_create(30, NULL);
	if (!ovector) {
		dbgprintf("pcre match data create failed\n");
		rc = 2;
		goto cleanup;
	}
	result = pcre2_match(subjexp, subjectline, strlen(subjectline), 0, 0, ovector, NULL);
	if (result < 0) {
		dbgprintf("Subject line did not match pattern\n");
		rc = 3; /* Subject did not match what we expected */
		goto cleanup;
	}
	if (pcre2_substring_copy_bynumber(ovector, 2, cookie, &l) < 0) {
		dbgprintf("Could not find cookie value\n");
		rc = 4; /* No cookie */
		goto cleanup;
	}
	pcre2_code_free(subjexp);
	subjexp = NULL;

	/* See if there's a "DELAY=" delay-value also */
	subjexp = pcre2_compile(".*DELAY[ =]+([0-9]+[mhdw]*)", PCRE2_ZERO_TERMINATED, PCRE2_CASELESS, &err, &errofs, NULL);
	if (subjexp == NULL) {
		dbgprintf("pcre compile failed - 2\n");
		rc = 2;
		goto cleanup;
	}
	result = pcre2_match(subjexp, subjectline, strlen(subjectline), 0, 0, ovector, NULL);
	if (result >= 0) {
		char delaytxt[4096];
		l = sizeof(delaytxt);
		if (pcre2_substring_copy_bynumber(ovector, 1, delaytxt, &l) == 0) {
			duration = durationvalue(delaytxt);
		}
	}
	pcre2_code_free(subjexp);
	subjexp = NULL;

	/* See if there's a "msg" text also */
	subjexp = pcre2_compile(".*MSG[ =]+(.*)", PCRE2_ZERO_TERMINATED, PCRE2_CASELESS, &err, &errofs, NULL);
	if (subjexp == NULL) {
		dbgprintf("pcre compile failed - 3\n");
		rc = 2;
		goto cleanup;
	}
	result = pcre2_match(subjexp, subjectline, strlen(subjectline), 0, 0, ovector, NULL);
	if (result >= 0) {
		char msgtxt[4096];
		l = sizeof(msgtxt);
		if (pcre2_substring_copy_bynumber(ovector, 1, msgtxt, &l) == 0) {
			if (firsttxtline && firsttxtline_alloc) free(firsttxtline);
			firsttxtline = strdup(msgtxt);
			firsttxtline_alloc = 1;
		}
	}
	pcre2_code_free(subjexp);
	subjexp = NULL;

	/* Use the "return-path:" header if we didn't see a From: line */
	if ((fromline == NULL) && returnpathline) fromline = returnpathline;
	if (fromline) {
		/* Remove '<' and '>' from the fromline - they mess up HTML */
		while ((p = strchr(fromline, '<')) != NULL) *p = ' ';
		while ((p = strchr(fromline, '>')) != NULL) *p = ' ';
	}

	/* Setup the acknowledge message */
	if (duration == 0) duration = 60;	/* Default: Ack for 60 minutes */
	if (firsttxtline == NULL) {
		firsttxtline = "<No cause specified>";
		firsttxtline_alloc = 0;
	}
	ackbuf = (char *)malloc(4096 + strlen(firsttxtline) + (fromline ? strlen(fromline) : 0));
	if (ackbuf == NULL) {
		rc = 2;
		goto cleanup;
	}
	p = ackbuf;
	p += sprintf(p, "xymondack %s %d %s", cookie, duration, firsttxtline);
	if (fromline) {
		p += sprintf(p, "\nAcked by: %s", fromline);
	}

	if (debug) {
		printf("%s\n", ackbuf);
		rc = 0;
		goto cleanup;
	}

	sendmessage(ackbuf, NULL, XYMON_TIMEOUT, NULL);
	rc = 0;

cleanup:
	if (subjexp) pcre2_code_free(subjexp);
	if (ovector) pcre2_match_data_free(ovector);
	if (ackbuf) free(ackbuf);
	if (subjectline) free(subjectline);
	if (fromline && (fromline != returnpathline)) free(fromline);
	if (returnpathline) free(returnpathline);
	if (firsttxtline && firsttxtline_alloc) free(firsttxtline);
	if (envarea) free(envarea);

	return rc;
}
