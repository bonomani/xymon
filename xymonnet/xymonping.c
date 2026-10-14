/*----------------------------------------------------------------------------*/
/* Xymon monitor network test tool.                                           */
/*                                                                            */
/* This is an implementation of a fast "ping" program, for use with Xymon.    */
/*                                                                            */
/* Copyright (C) 2006-2011 Henrik Storner <henrik@hswn.dk>                    */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*                                                                            */
/*----------------------------------------------------------------------------*/

static char rcsid[] = "$Id$";

#include "config.h"

#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#include <sys/socket.h>
#ifdef HAVE_SYS_SELECT_H
#include <sys/select.h>
#endif
#include <time.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>

#include <netinet/in_systm.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <arpa/inet.h>
#include <netdb.h>

#include <stdio.h>

#include "libxymon.h"
#include "evheap.h"

#define PING_PACKET_SIZE 64
#define PING_MINIMUM_SIZE ICMP_MINLEN

/* The 16-bit ICMP echo sequence carries (host_idx + 1), so two hosts
 * whose indices differ by a multiple of 65536 would receive each
 * other's replies. Refuse hosts beyond that rather than let the
 * reply-side cross-check on pingdata.id silently drop them. */
#define MAX_HOSTS            65535

/* Per-probe state, indexed by the probe_idx a reply carries back. */
#define PS_SCHED   0	/* not yet sent */
#define PS_SENT    1	/* sent, awaiting reply */
#define PS_REPLIED 2	/* reply received */
#define PS_TIMEOUT 4	/* in-flight deadline elapsed; counted as lost */

typedef struct hostdata_t {
	int id;
	struct sockaddr_in addr;
	int received;			/* how many ICMP_ECHO replies we've got */
	struct timespec rtt_total;
	uint8_t       *probe_state;	/* PS_* per try, so a late reply is rejected after PS_TIMEOUT */
	int probe_slots;		/* length of probe_state (tries) */
	struct hostdata_t *next;
} hostdata_t;

hostdata_t *hosthead = NULL;
int hostcount = 0;
hostdata_t **hosts = NULL;	/* Array of pointers to the hostdata records, for fast access via ID */
int myicmpid;
int senddelay = (1000000 / 50);	/* Delay between sending packets, in microseconds */
int minresponses = 1;		/* --responses: replies a host needs before it is done */
int hosts_pending = 0;		/* hosts still short of minresponses replies */
int64_t probe_timeout_ns = 0;	/* a reply later than this after its ping does not count */
int64_t next_send_ns = 0;	/* earliest time the next ping may leave, for --max-pps */
int is_dgram = 0;		/* 1 if the socket is SOCK_DGRAM (kernel-managed icmp_id, no IP header on RX) */
int pingsocket = -1;

/* This routine more or less taken from the "fping" source. Apparently by W. Stevens (public domain) */
int calc_icmp_checksum(unsigned short *pkt, int pktlen)
{
	unsigned short result;
	long sum = 0;
	unsigned short extrabyte = 0;

	while (pktlen > 1) {
		sum += *pkt++;
		pktlen -= 2;
	}

	if (pktlen == 1) {
		*(unsigned char *)(&extrabyte) = *(unsigned char *)pkt;
		sum += extrabyte;
	}

	sum = ( sum >> 16 ) + ( sum & 0xffff ); /* add hi 16 to low 16 */
	sum += ( sum >> 16 );			/* add carry */
	result = ~sum;				/* ones-complement, truncate*/

	return result;
}


char *nextip(int argc, char *argv[], FILE *fd)
{
	static int argi = 0;
	static int cmdmode = 0;
	static char buf[4096];

	if (argi == 0) {
		/* Check if there are any command-line IP's */
		struct sockaddr_in ina;

		for (argi=1; ((argi < argc) && (inet_aton(argv[argi], &ina.sin_addr) == 0)); argi++) ;
		cmdmode = (argi < argc);
	}

	if (cmdmode) {
		/* Skip any options in-between the IP's */
		while ((argi < argc) && (*(argv[argi]) == '-')) argi++;
		if (argi < argc) {
			argi++;
			return argv[argi-1];
		}
	}
	else {
		if (fgets(buf, sizeof(buf), fd)) {
			char *p;
			p = strchr(buf, '\n'); if (p) *p = '\0';
			return buf;
		}
	}

	return NULL;
}

void load_ips(int argc, char *argv[], FILE *fd)
{
	char *l;
	hostdata_t *tail = NULL;
	hostdata_t *walk;
	int i;

	while ((l = nextip(argc, argv, fd)) != NULL) {
		hostdata_t *newitem;

		if (strlen(l) == 0) continue;

		if (hostcount >= MAX_HOSTS) {
			errprintf("Host cap %d reached, refusing additional entries\n", MAX_HOSTS);
			break;
		}

		newitem = (hostdata_t *)calloc(1, sizeof(hostdata_t));
		if (!newitem) {
			errprintf("calloc(hostdata_t) failed for %s; skipping\n", l);
			continue;
		}

		newitem->addr.sin_family = AF_INET;
		newitem->addr.sin_port = 0;
		if (inet_aton(l, &newitem->addr.sin_addr) == 0) {
			errprintf("Dropping %s - not an IP\n", l);
			xfree(newitem);
			continue;
		}

		if (tail) {
			tail->next = newitem;
		}
		else {
			hosthead = newitem;
		}
		hostcount++;
		tail = newitem;
	}

	/* Setup the table of hostdata records */
	hosts = (hostdata_t **)malloc((hostcount+1) * sizeof(hostdata_t *));
	if (!hosts) {
		errprintf("malloc(host table, %d entries) failed; aborting\n", hostcount + 1);
		exit(1);
	}
	for (i=0, walk=hosthead; (walk); walk=walk->next, i++) hosts[i] = walk;
	hosts[hostcount] = NULL;
}


/* This is the data we send with each ping packet: the host index and the
 * try it belongs to, so a reply can be matched back to the
 * ping that sent it, our id, and the send time. icmp_seq encodes the host
 * index too. It sits after the ICMP header, which need not suit its
 * alignment (it holds a struct timespec), so it is copied in and out with
 * memcpy() rather than read through a cast pointer: a strict-alignment
 * CPU faults on that. */
typedef struct pingdata_t {
	int id;				/* ID for the host this belongs to */
	int probe_idx;			/* which try: 0 for the first, +1 per retry */
	int icmpid;			/* our myicmpid, checked where the header id is the kernel's */
	struct timespec timesent;	/* time we sent this ping */
} pingdata_t;

static int64_t mono_ns(void)
{
	struct timespec ts;

	/* getntimer() is the build's guarded clock: monotonic where the
	 * platform has it, the wall clock otherwise. */
	getntimer(&ts);
	return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static evheap_t sends, expiries;	/* pending sends, and pending reply deadlines */

/* Queue an event. One the heap cannot hold would leave a try with no
 * send or no deadline, and the result would quietly be wrong, so end
 * the run instead. */
static void schedule(evheap_t *h, pingevent_t e)
{
	if (evheap_push(h, e) != 0) {
		errprintf("Cannot schedule probe %d for host %d; aborting\n", e.probe_idx, e.host_idx);
		exit(1);
	}
}

/* Sends a single probe identified by (host_idx, probe_idx). Returns
 *   0  on successful send,
 *  -1  on EWOULDBLOCK (caller should reschedule shortly),
 *  -2  on hard send error (caller should mark probe as ERROR). */
#define EWOULDBLOCK_MAX_RETRIES 5

static int send_probe(int host_idx, int probe_idx)
{
	static unsigned char buffer[PING_PACKET_SIZE];
	struct icmp *icmphdr = (struct icmp *)buffer;
	struct pingdata_t pingdata;
	size_t pd_off;			/* where the payload goes: after the ICMP header */
	int sentbytes;

	memset(buffer, 0, PING_PACKET_SIZE);

	icmphdr->icmp_type  = ICMP_ECHO;
	icmphdr->icmp_code  = 0;
	icmphdr->icmp_cksum = 0;
	icmphdr->icmp_seq   = htons(host_idx + 1);
	icmphdr->icmp_id    = htons(myicmpid);
	/* RAW needs us to compute the checksum; DGRAM accepts a zero and
	 * the kernel fills it in. Filling it unconditionally is safe --
	 * the kernel doesn't second-guess a correct one. */
	memset(&pingdata, 0, sizeof(pingdata));	/* no stack bytes in the padding on the wire */
	pd_off = sizeof(struct icmp);
	pingdata.id        = host_idx;
	pingdata.probe_idx = probe_idx;
	pingdata.icmpid    = myicmpid;
	getntimer(&pingdata.timesent);
	memcpy(buffer + pd_off, &pingdata, sizeof(pingdata));
	icmphdr->icmp_cksum = calc_icmp_checksum((unsigned short *)buffer, PING_PACKET_SIZE);

	sentbytes = sendto(pingsocket, buffer, PING_PACKET_SIZE, 0,
	                   (struct sockaddr *)&hosts[host_idx]->addr,
	                   sizeof(struct sockaddr_in));

	if (sentbytes == -1) {
		if ((errno == EWOULDBLOCK) || (errno == EAGAIN)) return -1;
		errprintf("Failed to send ICMP packet (host=%d probe=%d): %s\n",
		          host_idx, probe_idx, strerror(errno));
		return -2;
	}

	if (debug) {
		dbgprintf("Sent probe %d to %s: index=%d, id=%d\n",
		          probe_idx, inet_ntoa(hosts[host_idx]->addr.sin_addr),
		          host_idx, myicmpid);
	}
	return 0;
}


int get_response(void)
{
	static unsigned char buffer[4096];
	struct sockaddr_in addr;
	int n, pktcount;
	unsigned int addrlen;
	struct ip *iphdr;
	int iphdrlen;
	struct icmp *icmphdr;
	int reply_type, reply_id, reply_seq;
	struct pingdata_t pingdata;
	int hostidx;
	struct timespec rtt;

	/*
	 * Read responses from the network.
	 * We know (because select() told us) that there is some data
	 * to read. To avoid losing packets, read as much as we can.
	 */
	pktcount = 0;
	do {
		addrlen = sizeof(addr);
		n = recvfrom(pingsocket, buffer, sizeof(buffer), 0, (struct sockaddr *)&addr, &addrlen);
		if (n < 0) {
			/* EWOULDBLOCK and EAGAIN differ on some systems (HP-UX); either
			 * means nothing is left to read. */
			if ((errno != EWOULDBLOCK) && (errno != EAGAIN)) errprintf("Failed to receive packet: %s\n", strerror(errno));
			continue;
		}

		getntimer(&rtt);

		/* A raw socket always delivers the IP header. A SOCK_DGRAM socket
		 * leaves it out on Linux but not on every system (macOS keeps
		 * it), so look: an IPv4 header starts with version 4, while the
		 * echo reply we are after starts with type 0. */
		if (!is_dgram || ((n > 0) && ((buffer[0] >> 4) == 4))) {
			iphdr = (struct ip *)buffer;
			iphdrlen = (iphdr->ip_hl << 2);
		}
		else {
			iphdrlen = 0;
		}
		if (n < (iphdrlen + PING_MINIMUM_SIZE)) {
			errprintf("Short packet ignored\n");
			continue;
		}

		icmphdr    = (struct icmp *)(buffer + iphdrlen);
		reply_type = icmphdr->icmp_type;
		reply_id   = ntohs(icmphdr->icmp_id);
		reply_seq  = ntohs(icmphdr->icmp_seq);
		hostidx = reply_seq - 1;

		if (debug) {
			dbgprintf("Got packet from %s: type=%d, index=%d, id=%d\n",
				inet_ntoa(addr.sin_addr), reply_type, reply_id, hostidx);
		}

		/* Non-reply types (our own echoes when pinging ourselves,
		 * UNREACH/REDIRECT, etc.) are skipped silently. We only care
		 * about ECHO_REPLY for our packets. */
		if (reply_type != ICMP_ECHOREPLY) continue;
		if (!is_dgram && reply_id != myicmpid) {
			/* SOCK_RAW: not one of our packets (someone else is
			 * also pinging). SOCK_DGRAM: kernel already matched. */
			continue;
		}
		if (hostidx < 0 || hostidx >= hostcount) continue;

		/* Make sure the reply is large enough to actually contain
		 * the pingdata_t payload before we dereference it. A short
		 * but well-formed ECHOREPLY would otherwise read past the
		 * received bytes into stale static-buffer contents. */
		if (n < (int)(iphdrlen + sizeof(struct icmp) + sizeof(struct pingdata_t))) continue;
		memcpy(&pingdata, buffer + iphdrlen + sizeof(struct icmp), sizeof(pingdata));

		/* icmp_seq carries only 16 bits of host index; the payload
		 * carries the full 32-bit id. Cross-check so seq-aliased
		 * hosts (when hostcount > 65535) and spoofed replies whose
		 * seq happens to land on a live host can't cross-attribute. */
		if (pingdata.id != hostidx) continue;

		/* A SOCK_DGRAM socket sets icmp_id itself, so the header check
		 * above was skipped; where the kernel does not keep each
		 * socket's replies apart, the payload still tells ours from
		 * another run's. */
		if (is_dgram && (pingdata.icmpid != myicmpid)) continue;

		/* Calculate the round-trip time. */
		rtt.tv_sec -= pingdata.timesent.tv_sec;
		rtt.tv_nsec -= pingdata.timesent.tv_nsec;
		if (rtt.tv_nsec < 0) {
			rtt.tv_sec--;
			rtt.tv_nsec += 1000000000;
		}

		/* As fping does: a reply later than the timeout does not count,
		 * whenever it is read. */
		if (((int64_t)rtt.tv_sec * 1000000000LL + rtt.tv_nsec) > probe_timeout_ns) continue;

		if (hosts[hostidx]->probe_state) {
			/* Only a try still PS_SENT may count: PS_REPLIED rejects
			 * duplicates, and PS_TIMEOUT rejects a late reply whose
			 * deadline has passed (otherwise it would revive a host
			 * the loop already gave up on for that try). */
			int pidx = pingdata.probe_idx;
			if (pidx < 0 || pidx >= hosts[hostidx]->probe_slots) continue;
			if (hosts[hostidx]->probe_state[pidx] != PS_SENT) continue;
			hosts[hostidx]->probe_state[pidx] = PS_REPLIED;
		}

		pktcount++;
		hosts[hostidx]->received += 1;
		if (hosts[hostidx]->received == minresponses) hosts_pending--;

		/* Add RTT to the total time */
		hosts[hostidx]->rtt_total.tv_sec += rtt.tv_sec;
		hosts[hostidx]->rtt_total.tv_nsec += rtt.tv_nsec;
		if (hosts[hostidx]->rtt_total.tv_nsec >= 1000000000) {
			hosts[hostidx]->rtt_total.tv_sec++;
			hosts[hostidx]->rtt_total.tv_nsec -= 1000000000;
		}
	} while (n > 0);

	return pktcount;
}


/* Build readfds for the ping socket and return the nfds argument to
 * select(). */
static int select_set(fd_set *readfds)
{
	FD_ZERO(readfds);
	FD_SET(pingsocket, readfds);
	return pingsocket + 1;
}

/* Read the replies waiting on the ping socket, if any. */
static void drain_replies(fd_set *readfds)
{
	if (FD_ISSET(pingsocket, readfds)) (void)get_response();
}

/* Read whatever replies are already waiting, without blocking: done
 * before a deadline is acted on, so a reply that arrived in time is
 * counted even when select() was interrupted or the loop was busy
 * sending. */
static void drain_now(void)
{
	(void)get_response();
}

/* Wait for the next event due and pop it into *ev: the earliest expiry, or
 * the earliest send once its --max-pps slot has come, whichever is first --
 * so a send held back by the rate limit never delays an expiry. Replies that
 * arrive meanwhile are read. Returns 1, 0 when both queues are empty, or -1
 * when select() fails. */
static int next_event(pingevent_t *ev)
{
	for (;;) {
		pingevent_t s, x;
		int have_s = (evheap_peek(&sends, &s) == 0);
		int have_x = (evheap_peek(&expiries, &x) == 0);
		int64_t due_s = 0, due, wait_ns;
		struct timeval tv;
		fd_set readfds;
		int n, nfds;

		if (!have_s && !have_x) return 0;
		if (have_s) due_s = (s.when_ns < next_send_ns) ? next_send_ns : s.when_ns;
		if (have_x && (!have_s || (x.when_ns <= due_s))) due = x.when_ns;
		else { due = due_s; have_x = 0; }

		wait_ns = due - mono_ns();
		if (wait_ns <= 0) {
			evheap_pop(have_x ? &expiries : &sends, ev);
			return 1;
		}

		tv.tv_sec  = wait_ns / 1000000000LL;
		tv.tv_usec = (wait_ns % 1000000000LL) / 1000;
		nfds = select_set(&readfds);
		n = select(nfds, &readfds, NULL, NULL, &tv);
		if (n < 0) {
			if (errno == EINTR) continue;
			errprintf("select failed: %s\n", strerror(errno));
			return -1;
		}
		if (n > 0) drain_replies(&readfds);
	}
}

/* Main loop without --samples. Each host gets one EV_SEND, in host order
 * one --max-pps slot apart, with a retry budget; a send queues an EV_EXPIRE
 * at t+timeout. On EV_EXPIRE without a reply the host either re-arms
 * (tries_left > 0) or is given up on. The run ends when every host has its
 * --responses replies or nothing is left to do. */
static int retry_main_loop(int timeout, int tries)
{
	int i;
	int64_t senddelay_ns = (int64_t)senddelay * 1000LL;	/* senddelay is in us; honor --max-pps / -i */
	int64_t start_ns = mono_ns();

	if (tries <= 0) tries = 1;
	probe_timeout_ns = (int64_t)timeout * 1000000000LL;
	hosts_pending = hostcount;

	/* Per-try probe_state so a late reply from a timed-out attempt
	 * cannot revive the host during a later retry window. Each retry
	 * fires with probe_idx = previous + 1; EV_EXPIRE marks the slot
	 * PS_TIMEOUT, and get_response rejects replies whose slot is no
	 * longer PS_SENT. Allocation failure falls back to the prior
	 * behaviour (no rejection) for that host -- still better than
	 * aborting the run. */
	for (i = 0; i < hostcount; i++) {
		hosts[i]->probe_state = (uint8_t *)calloc(tries, sizeof(uint8_t));
		if (!hosts[i]->probe_state) {
			errprintf("calloc(retry state, %d tries) failed for host idx %d; late-reply guard disabled for this host\n",
			          tries, i);
		}
		else {
			hosts[i]->probe_slots = tries;
		}
	}

	for (i = 0; i < hostcount; i++) {
		pingevent_t e;
		e.when_ns    = start_ns + (int64_t)i * senddelay_ns;
		e.host_idx   = i;
		e.probe_idx  = 0;
		e.retries    = 0;
		e.kind       = EV_SEND;
		e.tries_left = tries - 1;	/* this is the first try */
		schedule(&sends, e);
	}

	myicmpid = (getpid() & 0x7FFF);
	next_send_ns = start_ns;

	while (hosts_pending > 0) {
		pingevent_t ev;
		hostdata_t *h;
		int r = next_event(&ev);

		if (r < 0) return 4;
		if (r == 0) break;
		h = hosts[ev.host_idx];

		if (ev.kind == EV_SEND) {
			/* Skip if the host has already met the response
			 * threshold -- no need to keep retrying. */
			if (h->received >= minresponses) continue;

			r = send_probe(ev.host_idx, ev.probe_idx);
			if (r != -1) next_send_ns = mono_ns() + senddelay_ns;
			if (r == 0) {
				if (h->probe_state) h->probe_state[ev.probe_idx] = PS_SENT;
				/* Arm an EV_EXPIRE that carries forward the
				 * remaining retry budget. */
				ev.when_ns = mono_ns() + probe_timeout_ns;
				ev.kind    = EV_EXPIRE;
				schedule(&expiries, ev);
			}
			else if ((r == -1) && (ev.retries < EWOULDBLOCK_MAX_RETRIES)) {
				/* EWOULDBLOCK: reschedule shortly, same try
				 * (don't decrement tries_left for a transient
				 * socket-buffer condition). */
				ev.retries++;
				ev.when_ns = mono_ns() + 1000000LL;
				schedule(&sends, ev);
			}
			else {
				/* Hard send error or EWOULDBLOCK exhausted: no
				 * reply will arrive for this try. Expire it after
				 * the timeout like a lost ping, so the remaining
				 * retries still run. */
				ev.when_ns = mono_ns() + probe_timeout_ns;
				ev.kind    = EV_EXPIRE;
				schedule(&expiries, ev);
			}
		}
		else {
			/* EV_EXPIRE: the timeout elapsed for this send. Read
			 * what is already waiting first, then mark the slot
			 * PS_TIMEOUT so a later reply for this try is
			 * rejected. Only overwrite PS_SENT -- PS_REPLIED is a
			 * reply that came in time. */
			drain_now();
			if (h->probe_state && (h->probe_state[ev.probe_idx] == PS_SENT)) {
				h->probe_state[ev.probe_idx] = PS_TIMEOUT;
			}
			if (h->received >= minresponses) continue;
			if (ev.tries_left > 0) {
				/* Retry: a fresh EV_SEND with one less retry
				 * available. probe_idx advances so the next try
				 * gets its own PS_SENT slot. */
				pingevent_t next = ev;
				next.when_ns    = mono_ns();
				next.kind       = EV_SEND;
				next.retries    = 0;
				next.tries_left = ev.tries_left - 1;
				next.probe_idx  = ev.probe_idx + 1;
				schedule(&sends, next);
			}
			/* else: no more tries; show_results reports the
			 * host unreachable. */
		}
	}

	evheap_clear(&sends);
	evheap_clear(&expiries);
	return 0;
}

void show_results(void)
{
	int idx;
	unsigned long rtt_usecs; /* Big enough for 2147 seconds - larger than we will ever see */

	/*
	 * Print out the results. Format is identical to "fping -Ae" so we can use
	 * it directly in Xymon without changing the xymonnet code.
	 */
	for (idx = 0; (idx < hostcount); idx++) {
		if (hosts[idx]->received > 0) {
			printf("%s is alive", inet_ntoa(hosts[idx]->addr.sin_addr));
			rtt_usecs = (hosts[idx]->rtt_total.tv_sec*1000000 + (hosts[idx]->rtt_total.tv_nsec / 1000)) / hosts[idx]->received;
			if (rtt_usecs >= 3000) {
				printf(" (%.1f ms)\n", rtt_usecs / 1000.0);
			}
			else {
				printf(" (%lu usec)\n", rtt_usecs);
			}
		}
		else {
			printf("%s is unreachable\n", inet_ntoa(hosts[idx]->addr.sin_addr));
		}
	}
}

/* Try an unprivileged SOCK_DGRAM ICMP socket first: Linux grants one to a
 * user whose group is inside net.ipv4.ping_group_range, with no suid-root
 * needed. The kernel then manages icmp_id and strips the IP header on
 * receive (get_response handles both forms). Fall back to SOCK_RAW, the
 * historical path, if that is refused. */
static int open_icmp_socket(int *err_out)
{
	int s;

	s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
	if (s >= 0) { is_dgram = 1; return s; }

	get_root();
	s = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
	*err_out = errno;
	drop_root();
	is_dgram = 0;
	return s;
}

int main(int argc, char *argv[])
{
	int sockerr = 0, binderr = 0;
	int argi, tries = 3, timeout = 5;
	char *srcip = NULL;
	struct sockaddr_in src_addr;

	/* Immediately drop all root privileges. */
	drop_root();

	for (argi = 1; (argi < argc); argi++) {
		if (strncmp(argv[argi], "--retries=", 10) == 0) {
			char *delim = strchr(argv[argi], '=');
			tries = 1 + atoi(delim+1);
		}
		else if (strncmp(argv[argi], "--timeout=", 10) == 0) {
			char *delim = strchr(argv[argi], '=');
			int t = atoi(delim+1);
			/* 0 would refuse every reply: a reply always takes some time. */
			if (t > 0) timeout = t;
			else errprintf("Ignoring --timeout=%s: it must be at least 1\n", delim+1);
		}
		else if (strncmp(argv[argi], "--responses=", 11) == 0) {
			char *delim = strchr(argv[argi], '=');
			minresponses = atoi(delim+1);
		}
		else if (strncmp(argv[argi], "--source=", 9) == 0) {
			char *delim = strchr(argv[argi], '=');
			srcip = strdup(delim+1);
		}
		else if (strncmp(argv[argi], "--max-pps=", 10) == 0) {
			char *delim = strchr(argv[argi], '=');
			senddelay = (1000000 / atoi(delim+1));
		}
		else if (strncmp(argv[argi], "--debug", 7) == 0) {
			char *delim = strchr(argv[argi], '=');
			debug = 1;
			if (delim) set_debugfile(delim+1, 0);
		}
		else if (strcmp(argv[argi], "--help") == 0) {
			fprintf(stderr, "%s [--retries=N] [--timeout=N] [--responses=N] [--max-pps=N] [--source=IP]\n", argv[0]);
			return 0;
		}

		/* fping compatibility options */
		else if (strncmp(argv[argi], "-i", 2) == 0) {
			char *val = argv[argi] + 2;
			if (isdigit((int) *val)) senddelay = atoi(val);
		}
		else if (strncmp(argv[argi], "-r", 2) == 0) {
			char *val = argv[argi] + 2;
			if (isdigit((int) *val)) tries = atoi(val);
		}
		else if (strncmp(argv[argi], "-S", 2) == 0) {
			char *val = argv[argi] + 2;
			srcip = strdup(val);
		}
		else if (*(argv[argi]) == '-') {
			/* Ignore everything else - for fping compatibility */
		}
	}

	if (srcip != NULL) {
		/* Setup the source address */
		src_addr.sin_family = AF_INET;
		src_addr.sin_addr.s_addr = inet_addr(srcip);
		src_addr.sin_port = htons(0);
	}

	load_ips(argc, argv, stdin);
	if (hostcount == 0) return 0;	/* nothing to ping: no output, as before */

	pingsocket = open_icmp_socket(&sockerr);
	if (pingsocket == -1) {
		errprintf("Cannot open ICMP socket: %s\n", strerror(sockerr));
		if (sockerr == EPERM || sockerr == EACCES) {
			errprintf("Either run as a user whose group is in net.ipv4.ping_group_range,\n");
			errprintf("or install the binary suid-root or with cap_net_raw.\n");
		}
		return 3;
	}
	if (srcip != NULL && bind(pingsocket, (struct sockaddr *)&src_addr, sizeof(src_addr)) == -1) {
		binderr = errno;
		errprintf("Cannot bind to source address %s: %s\nUsing default address\n",
		          srcip, strerror(binderr));
	}
	fcntl(pingsocket, F_SETFL, O_NONBLOCK);

	{
		int rc = retry_main_loop(timeout, tries);
		close(pingsocket);
		if (rc == 0) show_results();
		return rc;
	}
}
