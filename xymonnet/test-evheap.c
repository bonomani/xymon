/*
 * test-evheap.c
 *
 * Unit test for xymonnet/evheap.c. Compiles evheap.c into the test
 * binary directly and supplies a stderr-printing errprintf shim so
 * the TU links without libxymon.
 *
 * Build & run (from xymonnet/):
 *   make test-evheap && ./test-evheap
 */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "evheap.h"

/* ---- libxymon shim ---- */
void errprintf(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* ---- test helpers ---- */
static int failures = 0;
#define CHECK(cond, label) do { \
	if (!(cond)) { fprintf(stderr, "FAIL %s\n", label); failures++; } \
	else { printf("ok   %s\n", label); } \
} while (0)
#define CHECK_EQ(a, b, label) CHECK((a) == (b), label)

static pingevent_t mkev(int64_t when, int host, int probe)
{
	pingevent_t e;
	e.when_ns = when;
	e.host_idx = host;
	e.probe_idx = probe;
	e.retries = 0;
	e.kind = EV_SEND;
	e.tries_left = 0;
	return e;
}

static int cmp_i64(const void *a, const void *b)
{
	int64_t aa = *(const int64_t *)a, bb = *(const int64_t *)b;
	return (aa < bb) ? -1 : (aa > bb);
}

int main(void)
{
	/* Empty heap */
	{
		pingevent_t out;
		int64_t when;
		CHECK_EQ(evheap_size(), 0, "empty-size");
		CHECK_EQ(evheap_pop(&out), -1, "empty-pop-returns-minus1");
		CHECK_EQ(evheap_peek_when(&when), -1, "empty-peek-returns-minus1");
	}

	/* Single push/pop round-trip */
	{
		pingevent_t out;
		int64_t when;
		evheap_push(mkev(42, 7, 3));
		CHECK_EQ(evheap_size(), 1, "size-after-one-push");
		CHECK_EQ(evheap_peek_when(&when), 0, "peek-when-returns-ok");
		CHECK_EQ((int)when, 42, "peek-when-value");
		CHECK_EQ(evheap_pop(&out), 0, "pop-returns-ok");
		CHECK_EQ((int)out.when_ns, 42, "pop-when");
		CHECK_EQ(out.host_idx, 7, "pop-host");
		CHECK_EQ(out.probe_idx, 3, "pop-probe");
		CHECK_EQ(evheap_size(), 0, "size-after-pop");
	}

	/* Min-heap property: out-of-order inserts pop in order */
	{
		pingevent_t out;
		int64_t prev = -1;
		int i;
		int64_t input[] = {500, 100, 300, 200, 50, 700, 50, 400, 600, 250};
		int n = sizeof(input) / sizeof(input[0]);
		for (i = 0; i < n; i++) evheap_push(mkev(input[i], i, 0));
		CHECK_EQ(evheap_size(), n, "min-heap-size");
		for (i = 0; i < n; i++) {
			CHECK_EQ(evheap_pop(&out), 0, "min-heap-pop-ok");
			if (out.when_ns < prev) {
				fprintf(stderr, "FAIL min-heap-order: got %lld after %lld\n",
				        (long long)out.when_ns, (long long)prev);
				failures++;
			}
			prev = out.when_ns;
		}
		CHECK_EQ(evheap_size(), 0, "min-heap-drained");
	}

	/* Equal when_ns: any pop order is acceptable, but heap must drain
	 * cleanly (no infinite loop, no negative size). */
	{
		pingevent_t out;
		int i;
		for (i = 0; i < 8; i++) evheap_push(mkev(1000, i, 0));
		CHECK_EQ(evheap_size(), 8, "equal-when-size");
		for (i = 0; i < 8; i++) {
			CHECK_EQ(evheap_pop(&out), 0, "equal-when-pop-ok");
			CHECK_EQ((int)out.when_ns, 1000, "equal-when-value");
		}
		CHECK_EQ(evheap_size(), 0, "equal-when-drained");
	}

	/* Capacity growth: push more than the initial 64 cap to exercise
	 * the realloc-and-double path. */
	{
		pingevent_t out;
		int64_t prev = -1;
		int i, count = 200;
		for (i = 0; i < count; i++) evheap_push(mkev(count - i, i, 0));
		CHECK_EQ(evheap_size(), count, "growth-size");
		for (i = 0; i < count; i++) {
			evheap_pop(&out);
			if (out.when_ns < prev) {
				fprintf(stderr, "FAIL growth-order at i=%d: got %lld after %lld\n",
				        i, (long long)out.when_ns, (long long)prev);
				failures++;
				break;
			}
			prev = out.when_ns;
		}
		CHECK_EQ(evheap_size(), 0, "growth-drained");
	}

	/* Carries struct payload intact through sift-up and sift-down */
	{
		pingevent_t out;
		evheap_push(mkev(30, 100, 1));
		evheap_push(mkev(10, 200, 2));
		evheap_push(mkev(20, 300, 3));
		evheap_pop(&out);
		CHECK_EQ((int)out.when_ns, 10, "payload-pop1-when");
		CHECK_EQ(out.host_idx, 200, "payload-pop1-host");
		CHECK_EQ(out.probe_idx, 2, "payload-pop1-probe");
		evheap_pop(&out);
		CHECK_EQ((int)out.when_ns, 20, "payload-pop2-when");
		CHECK_EQ(out.host_idx, 300, "payload-pop2-host");
		evheap_pop(&out);
		CHECK_EQ((int)out.when_ns, 30, "payload-pop3-when");
		CHECK_EQ(out.host_idx, 100, "payload-pop3-host");
	}

	/* Cap is exposed and positive */
	CHECK(evheap_max_capacity() > 0, "cap-positive");

	/* evheap_clear releases storage and resets to empty */
	{
		pingevent_t out;
		int i;
		for (i = 0; i < 10; i++) evheap_push(mkev(i, i, 0));
		evheap_clear();
		CHECK_EQ(evheap_size(), 0, "clear-empties");
		CHECK_EQ(evheap_pop(&out), -1, "clear-pop-returns-minus1");
		/* Push after clear still works -- backing storage is reallocated */
		evheap_push(mkev(99, 0, 0));
		evheap_pop(&out);
		CHECK_EQ((int)out.when_ns, 99, "clear-then-push-roundtrip");
	}

	/* Randomized fuzz: push N events with mixed-range random when_ns,
	 * pop all, verify (a) every pop succeeds, (b) pop order is
	 * ascending, (c) the multiset of popped when_ns values equals
	 * the input (no element lost, no element invented). Order-only
	 * assertions would let a buggy heap that silently dropped
	 * duplicates still pass. */
	{
		enum { N = 1000 };
		static int64_t in_arr[N];
		static int64_t out_arr[N];
		int i, all_pop_ok = 1, sorted_ok = 1, multiset_ok = 1;
		pingevent_t out;

		evheap_clear();
		srand(0x5EED5EED);
		for (i = 0; i < N; i++) {
			int64_t v;
			switch (rand() % 4) {
			case 0:  v = rand() % 100;                 break;  /* small + duplicates */
			case 1:  v = (int64_t)rand() * 1000;       break;  /* spread out */
			case 2:  v = INT64_MAX - (rand() % 1000);  break;  /* near-max boundary */
			default: v = rand();                       break;
			}
			in_arr[i] = v;
			evheap_push(mkev(v, i, 0));
		}
		CHECK_EQ(evheap_size(), N, "fuzz-size-after-push");
		for (i = 0; i < N; i++) {
			if (evheap_pop(&out) != 0) { all_pop_ok = 0; break; }
			out_arr[i] = out.when_ns;
		}
		CHECK(all_pop_ok, "fuzz-pop-all-ok");
		CHECK_EQ(evheap_size(), 0, "fuzz-size-after-pop");
		for (i = 1; i < N; i++) {
			if (out_arr[i] < out_arr[i-1]) { sorted_ok = 0; break; }
		}
		CHECK(sorted_ok, "fuzz-pop-ascending");
		qsort(in_arr, N, sizeof(int64_t), cmp_i64);
		for (i = 0; i < N; i++) {
			if (in_arr[i] != out_arr[i]) { multiset_ok = 0; break; }
		}
		CHECK(multiset_ok, "fuzz-multiset-equality");
	}

	if (failures) { fprintf(stderr, "\n%d failure(s)\n", failures); return 1; }
	printf("\nAll tests passed.\n");
	return 0;
}
