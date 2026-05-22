/*----------------------------------------------------------------------------*/
/* Xymon xymonping event heap                                                 */
/*                                                                            */
/* Tiny binary min-heap of pending probe sends, keyed by when_ns. Used by     */
/* xymonping's smoke loop to schedule each (host_idx, probe_idx) probe at a   */
/* specific future time and pop them off in time order. Kept as a separate   */
/* TU so it can be exercised without raw sockets via test-evheap(1).          */
/*                                                                            */
/* The heap holds one entry per scheduled (host, probe) pair. Entries are     */
/* compared by when_ns; ties may pop in either order (binary-heap stability   */
/* is not preserved, callers should not rely on it).                          */
/*----------------------------------------------------------------------------*/
#ifndef _XYMONPING_EVHEAP_H_
#define _XYMONPING_EVHEAP_H_

#include <stdint.h>

/* Event kinds: EV_SEND fires send_probe; EV_EXPIRE checks the host's
 * reply state and either re-schedules another EV_SEND (legacy retry)
 * or marks the host as timed out. Smoke mode only pushes EV_SEND --
 * the late-reply drain phase handles deadlines directly without
 * pushing EV_EXPIRE events. */
#define EV_SEND   0
#define EV_EXPIRE 1

typedef struct pingevent_t {
	int64_t when_ns;
	int     host_idx;
	int     probe_idx;
	int     retries;	/* EWOULDBLOCK retry count */
	int     kind;		/* EV_SEND or EV_EXPIRE */
	int     tries_left;	/* legacy retry budget remaining on EV_SEND */
} pingevent_t;

/* Insert e into the heap. Reallocates up to evheap_max_capacity()
 * entries; events beyond the cap are dropped and an errprintf is
 * emitted. Caller copies the struct in. */
void evheap_push(pingevent_t e);

/* Pop the earliest-when event into *out. Returns 0 on success, -1 if
 * the heap is empty. */
int evheap_pop(pingevent_t *out);

/* Read the when_ns of the earliest event without popping. Returns 0 on
 * success, -1 if empty. */
int evheap_peek_when(int64_t *out);

/* Number of events currently queued. */
int evheap_size(void);

/* Drop all queued events and free the backing storage. Idempotent. */
void evheap_clear(void);

/* Maximum number of in-flight events the heap will hold. Bound is
 * intentionally generous; exists only to fail cleanly on a corrupt
 * input rather than OOM. */
int evheap_max_capacity(void);

#endif
