/*----------------------------------------------------------------------------*/
/* Xymon xymonping event heap                                                 */
/*                                                                            */
/* Tiny binary min-heap of xymonping's pending events, keyed by when_ns:      */
/* each event is pushed with the time it is due and popped off in time       */
/* order. xymonping keeps two, one for sends and one for expiries, so that a  */
/* send held back by --max-pps never delays an expiry behind it. Kept as a    */
/* separate TU so it can be tested without raw sockets                        */
/* (tests/xymonnet/evheap.sh).                                                */
/*                                                                            */
/* Entries are compared by when_ns; ties may pop in either order (binary-heap */
/* stability is not preserved, callers should not rely on it).                */
/*----------------------------------------------------------------------------*/
#ifndef _XYMONPING_EVHEAP_H_
#define _XYMONPING_EVHEAP_H_

#include <stdint.h>

/* Event kinds: EV_SEND fires send_probe; EV_EXPIRE is a try's reply
 * deadline, after which a reply no longer counts. */
#define EV_SEND   0
#define EV_EXPIRE 1

typedef struct pingevent_t {
	int64_t when_ns;
	int     host_idx;
	int     probe_idx;
	int     retries;	/* EWOULDBLOCK retry count */
	int     kind;		/* EV_SEND or EV_EXPIRE */
	int     tries_left;	/* retries remaining after this try */
} pingevent_t;

/* One heap; zero-initialise it ("evheap_t h = { 0 };") before use. */
typedef struct evheap_t {
	pingevent_t *ev;
	int n, cap;
} evheap_t;

/* Insert e, reallocating up to evheap_max_capacity() entries. Returns 0,
 * or -1 with an errprintf when the event could not be stored (cap reached,
 * or out of memory). Caller copies the struct in. */
int evheap_push(evheap_t *h, pingevent_t e);

/* Pop the earliest-when event into *out. Returns 0, or -1 if empty. */
int evheap_pop(evheap_t *h, pingevent_t *out);

/* Copy the earliest event into *out without popping it. Returns 0, or -1
 * if empty. */
int evheap_peek(evheap_t *h, pingevent_t *out);

int evheap_size(const evheap_t *h);

/* Release the storage and empty the heap. */
void evheap_clear(evheap_t *h);

/* Upper bound on entries in one heap. */
int evheap_max_capacity(void);

#endif
