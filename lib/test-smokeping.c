/*
 * test-smokeping.c
 *
 * Unit test for lib/smokeping.c. Compiles smokeping.c into the test
 * binary directly and provides minimal shims (xgetenv -> getenv,
 * setup_template -> identity) so we don't need to link libxymon.a.
 *
 * Build & run (from lib/):
 *   make test-smokeping && ./test-smokeping
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "smokeping.h"

/* ---- libxymon shims ---- */
char *xgetenv(const char *name) { return getenv((char *)name); }
void *setup_template(char **params) { (void)params; return (void *)1; }

/* ---- test helpers ---- */
static int failures = 0;
#define CHECK(cond, label) do { \
	if (!(cond)) { fprintf(stderr, "FAIL %s\n", label); failures++; } \
	else { printf("ok   %s\n", label); } \
} while (0)
#define CHECK_EQ(a, b, label) CHECK((a) == (b), label)
#define CHECK_NEAR(a, b, eps, label) CHECK(fabs((double)(a) - (double)(b)) < (eps), label)
#define CHECK_STR(got, want, label) do { \
	if (strcmp((got), (want)) != 0) { \
		fprintf(stderr, "FAIL %s: got %s want %s\n", label, (got), (want)); \
		failures++; \
	} else printf("ok   %s\n", label); \
} while (0)

int main(void)
{
	setenv("SMOKEPINGSAMPLES", "5", 1);

	CHECK_EQ(smokeping_sample_count(), 5, "count-from-env");

	/* Alive host with samples */
	{
		double s[10];
		int nrecv, lost, total;
		const char *msg = "1.2.3.4 is alive (0.31 ms) samples=0.000310,0.000320,0.000305 loss=0/3";
		int ok = smokeping_parse_message(msg, s, 10, &nrecv, &lost, &total);
		CHECK_EQ(ok, 1, "parse-alive-returns-1");
		CHECK_EQ(nrecv, 3, "parse-alive-nrecv");
		CHECK_EQ(lost, 0, "parse-alive-lost");
		CHECK_EQ(total, 3, "parse-alive-total");
		CHECK_NEAR(s[0], 0.000310, 1e-9, "parse-alive-s0");
		CHECK_NEAR(s[2], 0.000305, 1e-9, "parse-alive-s2");
	}

	/* Unreachable host (no samples=) */
	{
		double s[10] = {0};
		int nrecv, lost, total;
		const char *msg = "1.2.3.5 is unreachable loss=5/5";
		int ok = smokeping_parse_message(msg, s, 10, &nrecv, &lost, &total);
		CHECK_EQ(ok, 1, "parse-unreach-returns-1");
		CHECK_EQ(nrecv, 0, "parse-unreach-nrecv");
		CHECK_EQ(lost, 5, "parse-unreach-lost");
		CHECK_EQ(total, 5, "parse-unreach-total");
	}

	/* Legacy (non-smoke) message: no loss= -> returns 0 */
	{
		double s[10];
		int nrecv, lost, total;
		const char *msg = "1.2.3.4 is alive (0.31 ms)";
		int ok = smokeping_parse_message(msg, s, 10, &nrecv, &lost, &total);
		CHECK_EQ(ok, 0, "parse-legacy-returns-0");
		CHECK_EQ(nrecv, 0, "parse-legacy-nrecv");
		CHECK_EQ(lost, 0, "parse-legacy-lost");
	}

	/* Partial loss: 2 received, loss=3/5 */
	{
		double s[10];
		int nrecv, lost, total;
		const char *msg = "1.2.3.6 is alive (0.40 ms) samples=0.000400,0.000440 loss=3/5";
		int ok = smokeping_parse_message(msg, s, 10, &nrecv, &lost, &total);
		CHECK_EQ(ok, 1, "parse-partial-returns-1");
		CHECK_EQ(nrecv, 2, "parse-partial-nrecv");
		CHECK_EQ(lost, 3, "parse-partial-lost");
		CHECK_EQ(total, 5, "parse-partial-total");
	}

	/* Median */
	{
		double s_odd[] = {0.3, 0.1, 0.5, 0.2, 0.4};
		double s_even[] = {0.1, 0.3, 0.5, 0.2};
		double s_empty[1];
		CHECK_NEAR(smokeping_median(s_odd, 5), 0.3, 1e-9, "median-odd");
		CHECK_NEAR(smokeping_median(s_even, 4), 0.25, 1e-9, "median-even");
		CHECK(isnan(smokeping_median(s_empty, 0)), "median-empty");
	}

	/* rrd_params has the expected shape (N=5 from env) */
	{
		char **p = smokeping_rrd_params();
		CHECK(p != NULL, "params-not-null");
		CHECK_STR(p[0], "DS:median:GAUGE:600:0:U", "params-median");
		CHECK_STR(p[1], "DS:loss:GAUGE:600:0:U",   "params-loss");
		CHECK_STR(p[2], "DS:ping1:GAUGE:600:0:U",  "params-ping1");
		CHECK_STR(p[6], "DS:ping5:GAUGE:600:0:U",  "params-ping5");
		CHECK(p[7] == NULL, "params-terminator");
	}

	/* rrd_template returns the shim'd template handle */
	{
		void *t = smokeping_rrd_template();
		CHECK(t != NULL, "template-not-null");
	}

	/* format with 3 received samples (out of N=5) -> 3 values + 2 U */
	{
		char out[256];
		double sorted[] = {0.000305, 0.000310, 0.000320};
		smokeping_format_rrdvalues(out, sizeof(out), 1234567890,
		                            0.000310, 0.0, sorted, 3);
		CHECK_STR(out,
		          "1234567890:0.000310:0.000000:0.000305:0.000310:0.000320:U:U",
		          "format-3-of-5");
	}

	/* format with zero received (unreachable) -> median is U, lossfrac kept */
	{
		char out[256];
		smokeping_format_rrdvalues(out, sizeof(out), 1234567890, 0, 1.0, NULL, 0);
		CHECK_STR(out,
		          "1234567890:U:1.000000:U:U:U:U:U",
		          "format-0-of-5");
	}

	/* End-to-end: parse -> median -> format for an alive message */
	{
		char out[256];
		double s[10];
		int nrecv, lost, total;
		double med, lossfrac;
		const char *msg = "1.2.3.4 is alive (0.31 ms) samples=0.000310,0.000320,0.000305 loss=0/3";

		smokeping_parse_message(msg, s, 10, &nrecv, &lost, &total);
		lossfrac = (total > 0 ? (double)lost / (double)total : 0.0);
		med = smokeping_median(s, nrecv);
		smokeping_format_rrdvalues(out, sizeof(out), 1234567890, med, lossfrac, s, nrecv);

		CHECK_STR(out,
		          "1234567890:0.000310:0.000000:0.000305:0.000310:0.000320:U:U",
		          "end-to-end-alive");
	}

	if (failures) { fprintf(stderr, "\n%d failure(s)\n", failures); return 1; }
	printf("\nAll tests passed.\n");
	return 0;
}
