/*----------------------------------------------------------------------------*/
/* Xymon xymonping event heap -- implementation                               */
/* See evheap.h for the API contract.                                         */
/*----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>

#include "evheap.h"
#include "../lib/memory.h"	/* xfree() */

#define EVHEAP_MAX_CAPACITY 10000000

/* errprintf is provided by libxymon in the xymonping build. The test
 * binary supplies its own shim so this TU links standalone. */
extern void errprintf(const char *fmt, ...);

int evheap_max_capacity(void) { return EVHEAP_MAX_CAPACITY; }

int evheap_size(const evheap_t *h) { return h->n; }

void evheap_clear(evheap_t *h)
{
	if (h->ev) xfree(h->ev);
	h->n = 0;
	h->cap = 0;
}

int evheap_push(evheap_t *h, pingevent_t e)
{
	int i;
	if (h->n == h->cap) {
		int new_cap = h->cap ? h->cap * 2 : 64;
		pingevent_t *p;
		if (new_cap > EVHEAP_MAX_CAPACITY) new_cap = EVHEAP_MAX_CAPACITY;
		if (new_cap <= h->cap) {
			errprintf("evheap cap %d reached; event not stored\n", EVHEAP_MAX_CAPACITY);
			return -1;
		}
		p = (pingevent_t *)realloc(h->ev, (size_t)new_cap * sizeof(pingevent_t));
		if (!p) {
			errprintf("evheap realloc failed; event not stored\n");
			return -1;
		}
		h->ev = p;
		h->cap = new_cap;
	}
	i = h->n++;
	h->ev[i] = e;
	while (i > 0) {
		int parent = (i - 1) >> 1;
		if (h->ev[parent].when_ns <= h->ev[i].when_ns) break;
		{ pingevent_t t = h->ev[parent]; h->ev[parent] = h->ev[i]; h->ev[i] = t; }
		i = parent;
	}
	return 0;
}

int evheap_pop(evheap_t *h, pingevent_t *out)
{
	int i, last;
	if (h->n == 0) return -1;
	*out = h->ev[0];
	last = --h->n;
	if (last == 0) return 0;
	h->ev[0] = h->ev[last];
	i = 0;
	for (;;) {
		int l = 2 * i + 1, r = 2 * i + 2, m = i;
		if (l < h->n && h->ev[l].when_ns < h->ev[m].when_ns) m = l;
		if (r < h->n && h->ev[r].when_ns < h->ev[m].when_ns) m = r;
		if (m == i) break;
		{ pingevent_t t = h->ev[i]; h->ev[i] = h->ev[m]; h->ev[m] = t; }
		i = m;
	}
	return 0;
}

int evheap_peek(evheap_t *h, pingevent_t *out)
{
	if (h->n == 0) return -1;
	*out = h->ev[0];
	return 0;
}
