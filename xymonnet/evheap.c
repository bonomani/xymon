/*----------------------------------------------------------------------------*/
/* Xymon xymonping event heap -- implementation                               */
/* See evheap.h for the API contract.                                         */
/*----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>

#include "evheap.h"

#define EVHEAP_MAX_CAPACITY 10000000

/* errprintf is provided by libxymon in the xymonping build. The test
 * binary supplies its own shim so this TU links standalone. */
extern void errprintf(const char *fmt, ...);

static pingevent_t *evheap = NULL;
static int evheap_n   = 0;
static int evheap_cap = 0;

int evheap_max_capacity(void) { return EVHEAP_MAX_CAPACITY; }

int evheap_size(void) { return evheap_n; }

void evheap_clear(void)
{
	free(evheap);
	evheap = NULL;
	evheap_n = 0;
	evheap_cap = 0;
}

void evheap_push(pingevent_t e)
{
	int i;
	if (evheap_n == evheap_cap) {
		int new_cap = evheap_cap ? evheap_cap * 2 : 64;
		pingevent_t *p;
		if (new_cap > EVHEAP_MAX_CAPACITY) new_cap = EVHEAP_MAX_CAPACITY;
		if (new_cap <= evheap_cap) {
			errprintf("evheap cap %d reached; dropping event\n", EVHEAP_MAX_CAPACITY);
			return;
		}
		p = (pingevent_t *)realloc(evheap, (size_t)new_cap * sizeof(pingevent_t));
		if (!p) {
			errprintf("evheap realloc failed; dropping event\n");
			return;
		}
		evheap = p;
		evheap_cap = new_cap;
	}
	i = evheap_n++;
	evheap[i] = e;
	while (i > 0) {
		int parent = (i - 1) >> 1;
		if (evheap[parent].when_ns <= evheap[i].when_ns) break;
		{ pingevent_t t = evheap[parent]; evheap[parent] = evheap[i]; evheap[i] = t; }
		i = parent;
	}
}

int evheap_pop(pingevent_t *out)
{
	int i, last;
	if (evheap_n == 0) return -1;
	*out = evheap[0];
	last = --evheap_n;
	if (last == 0) return 0;
	evheap[0] = evheap[last];
	i = 0;
	for (;;) {
		int l = 2 * i + 1, r = 2 * i + 2, m = i;
		if (l < evheap_n && evheap[l].when_ns < evheap[m].when_ns) m = l;
		if (r < evheap_n && evheap[r].when_ns < evheap[m].when_ns) m = r;
		if (m == i) break;
		{ pingevent_t t = evheap[i]; evheap[i] = evheap[m]; evheap[m] = t; }
		i = m;
	}
	return 0;
}

int evheap_peek_when(int64_t *out)
{
	if (evheap_n == 0) return -1;
	*out = evheap[0].when_ns;
	return 0;
}
