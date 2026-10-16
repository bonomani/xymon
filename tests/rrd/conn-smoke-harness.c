/* SPDX-License-Identifier: GPL-2.0-or-later                                  */
/*
 * tests/rrd/conn-smoke-harness.c
 *
 * Drives the REAL conn recording path - do_net.c with lib/smokeping.c - the
 * way xymond/do_rrd.c #includes it, with the RRD plumbing stubbed so every
 * file that WOULD be updated is captured with its update string.
 *
 * Pins that a conn status carrying xymonping's "samples=... loss=K/N" fields
 * updates, beside the usual tcp.conn.rrd, tcp.conn-smoke.rrd with the N
 * samples sorted ("U" for each lost one, half below and half above) and
 * tcp.conn-smoke-summary.rrd with the median, the loss fraction and the
 * verdict, each under the archive key of its kind; that a plain conn
 * status updates tcp.conn.rrd alone; and that do_net_rrd returns what the
 * tcp.conn.rrd update returned, smoke data or not.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* --- stub the RRD plumbing (real versions live in do_rrd.c) --- */
char rrdvalues[8192];
static char rrdfn[256];
static char written_fn[4][256], written_val[4][8192], written_key[4][64];
static int  writes;
static int  update_rc;		/* what the stubbed update returns */

static void  setupfn(char *f, char *p) { snprintf(rrdfn, sizeof(rrdfn), f, p); }
static void  setupfn2(char *f, char *a, char *b) { snprintf(rrdfn, sizeof(rrdfn), f, a, b); }
static void  setupfn3(char *f, char *a, char *b, char *c) { snprintf(rrdfn, sizeof(rrdfn), f, a, b, c); }
static void *setup_template(char *p[]) { (void)p; return (void *)1; }
static int   create_and_update_rrd(char *h, char *t, char *c, char *pp, char *cp[], void *tpl)
{
	(void)h; (void)c; (void)pp; (void)cp; (void)tpl;
	if (writes < 4) {
		snprintf(written_key[writes], sizeof(written_key[writes]), "%s", t);
		snprintf(written_fn[writes], sizeof(written_fn[writes]), "%s", rrdfn);
		snprintf(written_val[writes], sizeof(written_val[writes]), "%s", rrdvalues);
	}
	writes++;
	return update_rc;
}
static char *xgetenv(const char *n) { return (strcmp(n, "PINGCOLUMN") == 0) ? "conn" : ""; }
static char *xstrdup(const char *s) { return strdup(s); }
static void errprintf(const char *fmt, ...) { (void)fmt; }
#define xfree free

#include "../../lib/smokeping.c"
#include "../../xymond/rrd/do_ntpstat.c"
#include "../../xymond/rrd/do_net.c"

static int fails;

static void expect_write(int i, const char *fn, const char *val, const char *what)
{
	if ((writes <= i) || strcmp(written_fn[i], fn) || strcmp(written_val[i], val)) {
		printf("FAIL %s: expected %s <- '%s', got %s <- '%s'\n", what, fn, val,
		       (writes > i) ? written_fn[i] : "(no write)", (writes > i) ? written_val[i] : "");
		fails++;
	}
}

static int record(const char *msg, int rc)
{
	char buf[1024];

	snprintf(buf, sizeof(buf), "%s", msg);
	writes = 0; update_rc = rc;
	return do_net_rrd("host", "conn", "", "", buf, (time_t)1000);
}

int main(void)
{
	int rc;

	/* 3 of 4 replies, out of order: sorted, median of the three, loss 1/4. */
	rc = record("green <!-- [flags:OrdAstLe] --> conn ok\n\n"
		    "&green 127.0.0.1 is alive (1.00 ms) samples=0.001000,0.003000,0.002000 loss=1/4\n", 0);
	expect_write(0, "tcp.conn.rrd", "1000:0.001000", "smoke status, usual RRD");
	expect_write(1, "tcp.conn-smoke.rrd", "1000:0.001000:0.002000:0.003000:U",
		     "smoke status, samples RRD");
	expect_write(2, "tcp.conn-smoke-summary.rrd", "1000:0.002000:0.250000:U:U:U:U",
		     "smoke status, summary RRD");
	if (writes != 3) { printf("FAIL smoke status: %d updates, expected 3\n", writes); fails++; }
	/* Each file takes its archives from the rrddefinitions.cfg section of
	 * its kind; the usual one keeps [conn]'s. */
	if ((writes >= 3) && (strcmp(written_key[0], "conn") || strcmp(written_key[1], "conn-smoke") ||
			      strcmp(written_key[2], "conn-smoke-summary"))) {
		printf("FAIL archive keys: '%s', '%s' and '%s', expected 'conn', 'conn-smoke' and 'conn-smoke-summary'\n",
		       written_key[0], written_key[1], written_key[2]);
		fails++;
	}
	if (rc != 0) { printf("FAIL smoke status: returned %d, expected 0\n", rc); fails++; }

	/* The verdict xymonnet adds after the loss is stored after the samples. */
	rc = record("green conn ok\n\n&green 127.0.0.1 is alive (1.00 ms) samples=0.001000,0.002000 loss=0/2"
		    " losshour=0.033333 lossstate=1 losswarn=0.030000 losscrit=0.100000\n", 0);
	expect_write(1, "tcp.conn-smoke.rrd", "1000:0.001000:0.002000", "smoke status with its verdict, samples");
	expect_write(2, "tcp.conn-smoke-summary.rrd", "1000:0.001500:0.000000:0.033333:1.000000:0.030000:0.100000",
		     "smoke status with its verdict, summary");

	/* No samples= or loss=: only the usual RRD. */
	rc = record("green <!-- [flags:OrdAstLe] --> conn ok\n\n&green 127.0.0.1 is alive (1.00 ms)\n", 0);
	expect_write(0, "tcp.conn.rrd", "1000:0.001000", "plain status");
	if (writes != 1) { printf("FAIL plain status: %d updates, expected 1\n", writes); fails++; }

	/* The usual update's result is what do_net_rrd returns, with or without smoke data. */
	rc = record("green conn ok\n\n&green 127.0.0.1 is alive (1.00 ms) samples=0.001000 loss=0/1\n", 3);
	if (rc != 3) { printf("FAIL smoke status: returned %d, expected the update's 3\n", rc); fails++; }
	rc = record("green conn ok\n\n&green 127.0.0.1 is alive (1.00 ms)\n", 3);
	if (rc != 3) { printf("FAIL plain status: returned %d, expected the update's 3\n", rc); fails++; }

	return fails ? 1 : 0;
}
