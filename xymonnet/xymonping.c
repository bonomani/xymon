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
#include <netinet/icmp6.h>
#include <arpa/inet.h>
#include <net/if.h>		/* if_nametoindex() for IPv6 link-local %iface */
#include <netdb.h>

#include <stdio.h>

#include "libxymon.h"
#include "evheap.h"

#define PING_PACKET_SIZE 64
#define PING_MINIMUM_SIZE ICMP_MINLEN

/* Safety caps. xymon is normally run with a few thousand hosts at
 * most; these are several orders of magnitude above realistic and
 * exist only to fail cleanly on a corrupt or hostile hosts.cfg
 * instead of OOM-ing the box. */
/* The 16-bit ICMP echo sequence carries (host_idx + 1), so two hosts
 * with indices that differ by a multiple of 65536 would receive each
 * other's replies. The reply-side cross-check on pingdata.id catches
 * the alias, but advertising a 1M cap when only the first ~65535 can
 * ever match is misleading. MAX_TOTAL_PROBES still bounds the total. */
#define MAX_HOSTS            65535
#define MAX_SAMPLES_PER_HOST 1000
#define MAX_TOTAL_PROBES     10000000

/* Per-probe state machine for smoke mode. Indexed by probe_idx so
 * samples_usec[k] is always the RTT for the kth scheduled probe to
 * that host, regardless of arrival order. */
#define PS_SCHED   0	/* not yet sent */
#define PS_SENT    1	/* sent, awaiting reply */
#define PS_REPLIED 2	/* reply received */
#define PS_ERROR   3	/* send hard-failed; no reply possible */
#define PS_TIMEOUT 4	/* in-flight deadline elapsed; counted as lost */

typedef struct hostdata_t {
	int id;
	int family;			/* AF_INET or AF_INET6 */
	struct sockaddr_storage addr;	/* sized for either family; cast on use */
	socklen_t addrlen;
	char *name;			/* the address as given; an IPv6 result is printed with it */
	int received;			/* how many ICMP_ECHO replies we've got */
	int sent;			/* how many ICMP_ECHO requests we've sent (smoke mode) */
	struct timespec rtt_total;
	unsigned long *samples_usec;	/* --samples: rtt in usec per probe_idx; NULL otherwise */
	uint8_t       *probe_state;	/* PS_* per probe_idx; legacy allocates [tries] so late replies are rejected after PS_TIMEOUT */
	int probe_slots;		/* length of probe_state (and samples_usec): samples_count with --samples, else tries */
	struct hostdata_t *next;
} hostdata_t;

hostdata_t *hosthead = NULL;
int hostcount = 0;
hostdata_t **hosts = NULL;	/* Array of pointers to the hostdata records, for fast access via ID */
int myicmpid;
int senddelay = (1000000 / 100);	/* Delay between sending packets, in microseconds: fping's -i default, 10 ms */
int minresponses = 1;		/* --responses: replies a host needs before it is done */
int hosts_pending = 0;		/* hosts still short of minresponses replies */
int64_t probe_timeout_ns = 0;	/* the first try's timeout; a reply later than its try's timeout does not count */
double backoff = 1.0;		/* each retry's timeout is the previous one times this */
int64_t next_send_ns = 0;	/* earliest time the next ping may leave, for --max-pps */
int samples_count = 0;		/* >0 enables smoke mode: send exactly N pings per host, record each rtt */
int inflight = 0;		/* --samples: pings sent and still awaiting a reply or their deadline */
int per_host_interval_ms = -1;	/* spacing between probes for one host in smoke mode; -1 = 1000 ms */
int is_dgram_v4 = 0;		/* 1 if v4 socket is SOCK_DGRAM (kernel-managed icmp_id, no IP header on RX) */
int is_dgram_v6 = 0;		/* 1 if v6 socket is SOCK_DGRAM */
int pingsocket_v4 = -1;
int pingsocket_v6 = -1;

/* Lookup a printable form of any sockaddr_storage (v4 or v6). Returns a
 * pointer to a static per-call buffer; not reentrant. */
static const char *sockaddr_str(const struct sockaddr_storage *ss)
{
	static char buf[INET6_ADDRSTRLEN];
	if (ss->ss_family == AF_INET) {
		const struct sockaddr_in *sin = (const struct sockaddr_in *)ss;
		inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
	}
	else {
		const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ss;
		inet_ntop(AF_INET6, &sin6->sin6_addr, buf, sizeof(buf));
	}
	return buf;
}

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


/* Is s an address load_ips() will take: IPv4, or IPv6 with an optional
 * %iface suffix? */
static int is_ip_arg(const char *s)
{
	struct in_addr a4;
	struct in6_addr a6;
	char addr[INET6_ADDRSTRLEN];
	size_t n = strcspn(s, "%");

	if (inet_aton(s, &a4) != 0) return 1;
	if (n >= sizeof(addr)) return 0;
	memcpy(addr, s, n);
	addr[n] = '\0';
	return (inet_pton(AF_INET6, addr, &a6) == 1);
}

char *nextip(int argc, char *argv[], FILE *fd)
{
	static int argi = 0;
	static int cmdmode = 0;
	static char buf[4096];

	if (argi == 0) {
		/* Check if there are any command-line IP's: either family,
		 * an IPv6 one possibly with a %iface suffix, as load_ips()
		 * accepts on stdin. */
		for (argi=1; ((argi < argc) && !is_ip_arg(argv[argi])); argi++) ;
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

		/* An address ends at the first blank: inet_pton() refuses
		 * trailing text. */
		l[strcspn(l, " \t\r")] = '\0';
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
		newitem->name = strdup(l);

		/* IPv4 is read with inet_aton(), as it always was, so the
		 * short forms it accepts ("10.1") keep working; anything else
		 * is tried as IPv6. A link-local IPv6 address (fe80::...)
		 * needs its interface, given the standard way as "addr%iface":
		 * the suffix is resolved with if_nametoindex(). */
		{
			struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&newitem->addr;
			struct sockaddr_in  *sin4 = (struct sockaddr_in  *)&newitem->addr;
			char *pct = strchr(l, '%');
			unsigned int scope_id = 0;

			if (!pct && (inet_aton(l, &sin4->sin_addr) != 0)) {
				newitem->family  = AF_INET;
				sin4->sin_family = AF_INET;
				sin4->sin_port   = 0;
				newitem->addrlen = sizeof(struct sockaddr_in);
			}
			else {
				if (pct) {
					*pct = '\0';
					scope_id = if_nametoindex(pct + 1);
					if (scope_id == 0) {
						errprintf("Dropping %s%%%s - unknown interface for scope_id\n", l, pct + 1);
						xfree(newitem->name);
						xfree(newitem);
						continue;
					}
				}
				if (inet_pton(AF_INET6, l, &sin6->sin6_addr) != 1) {
					if (pct) *pct = '%';	/* restore for the diagnostic */
					errprintf("Dropping %s - not an IP\n", l);
					xfree(newitem->name);
					xfree(newitem);
					continue;
				}
				newitem->family     = AF_INET6;
				sin6->sin6_family   = AF_INET6;
				sin6->sin6_port     = 0;
				sin6->sin6_scope_id = scope_id;
				newitem->addrlen    = sizeof(struct sockaddr_in6);
			}
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

	/* With --samples, each host gets a per-sample rtt array and a
	 * per-probe state, both indexed by probe_idx. The loop relies on
	 * them, so a failed allocation ends the run like the host table
	 * above. */
	if (samples_count > 0) {
		for (i = 0; i < hostcount; i++) {
			hosts[i]->samples_usec  = (unsigned long *)calloc(samples_count, sizeof(unsigned long));
			hosts[i]->probe_state   = (uint8_t *)calloc(samples_count, sizeof(uint8_t));
			if (!hosts[i]->samples_usec || !hosts[i]->probe_state) {
				errprintf("calloc(%d samples) failed for host idx %d; aborting\n", samples_count, i);
				exit(1);
			}
			hosts[i]->probe_slots = samples_count;
		}
	}
}


/* This is the data we send with each ping packet: the host index and the
 * try (or sample) it belongs to, so a reply can be matched back to the
 * ping that sent it, our id, and the send time. icmp_seq encodes the host
 * index too. It sits after the ICMP header, which need not suit its
 * alignment (it holds a struct timespec), so it is copied in and out with
 * memcpy() rather than read through a cast pointer: a strict-alignment
 * CPU faults on that. */
typedef struct pingdata_t {
	int id;				/* ID for the host this belongs to */
	int probe_idx;			/* the try, or with --samples the sample: 0, 1, ... */
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

/* The timeout of try probe_idx: the first try's, times backoff for each
 * retry before it, as fping's -t and -B work. Capped at an hour, so a
 * forged probe_idx cannot overflow it or keep the loop going. */
static int64_t try_timeout_ns(int probe_idx)
{
	int64_t t = probe_timeout_ns;
	int i;

	if ((backoff <= 1.0) || (t <= 0)) return t;
	for (i = 0; (i < probe_idx) && (t < 3600000000000LL); i++) t = (int64_t)(t * backoff);
	return t;
}

/* The --samples timeout when --timeout is not given, as fping's count mode
 * picks it: the spacing between pings to a host, but never more than 2 s
 * (and 500 ms, fping's -t default, when the pings are not spaced at all). */
static int samples_timeout_ms(void)
{
	if (per_host_interval_ms <= 0) return 500;
	return (per_host_interval_ms < 2000) ? per_host_interval_ms : 2000;
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
	struct pingdata_t pingdata;
	size_t pd_off;			/* where the payload goes: after the ICMP header */
	int sentbytes, sock;
	int family = hosts[host_idx]->family;

	sock = (family == AF_INET) ? pingsocket_v4 : pingsocket_v6;
	if (sock < 0) return -2;	/* family not configured; treat as hard error */

	memset(buffer, 0, PING_PACKET_SIZE);

	if (family == AF_INET) {
		struct icmp *icmphdr = (struct icmp *)buffer;
		icmphdr->icmp_type  = ICMP_ECHO;
		icmphdr->icmp_code  = 0;
		icmphdr->icmp_cksum = 0;
		icmphdr->icmp_seq   = htons(host_idx + 1);
		icmphdr->icmp_id    = htons(myicmpid);
		/* IPv4 RAW needs us to compute the checksum; IPv4 DGRAM
		 * accepts a zero and the kernel fills it in. Filling it
		 * unconditionally is safe -- the kernel doesn't second-
		 * guess a correct one. */
		memset(&pingdata, 0, sizeof(pingdata));	/* no stack bytes in the padding on the wire */
		pd_off = sizeof(struct icmp);
		pingdata.id        = host_idx;
		pingdata.probe_idx = probe_idx;
		pingdata.icmpid    = myicmpid;
		getntimer(&pingdata.timesent);
		memcpy(buffer + pd_off, &pingdata, sizeof(pingdata));
		icmphdr->icmp_cksum = calc_icmp_checksum((unsigned short *)buffer, PING_PACKET_SIZE);
	}
	else {
		struct icmp6_hdr *icmp6hdr = (struct icmp6_hdr *)buffer;
		icmp6hdr->icmp6_type  = ICMP6_ECHO_REQUEST;
		icmp6hdr->icmp6_code  = 0;
		icmp6hdr->icmp6_cksum = 0;	/* kernel computes for ICMPv6 */
		icmp6hdr->icmp6_seq   = htons(host_idx + 1);
		icmp6hdr->icmp6_id    = htons(myicmpid);
		memset(&pingdata, 0, sizeof(pingdata));	/* no stack bytes in the padding on the wire */
		pd_off = sizeof(struct icmp6_hdr);
		pingdata.id        = host_idx;
		pingdata.probe_idx = probe_idx;
		pingdata.icmpid    = myicmpid;
		getntimer(&pingdata.timesent);
		memcpy(buffer + pd_off, &pingdata, sizeof(pingdata));
	}


	sentbytes = sendto(sock, buffer, PING_PACKET_SIZE, 0,
	                   (struct sockaddr *)&hosts[host_idx]->addr,
	                   hosts[host_idx]->addrlen);

	if (sentbytes == -1) {
		if ((errno == EWOULDBLOCK) || (errno == EAGAIN)) return -1;
		errprintf("Failed to send ICMP packet (host=%d probe=%d): %s\n",
		          host_idx, probe_idx, strerror(errno));
		return -2;
	}

	if (debug) {
		dbgprintf("Sent probe %d to %s: index=%d, id=%d\n",
		          probe_idx, sockaddr_str(&hosts[host_idx]->addr),
		          host_idx, myicmpid);
	}
	return 0;
}


int get_response(int sock, int family, int is_dgram)
{
	static unsigned char buffer[4096];
	struct sockaddr_storage addr;
	int n, pktcount;
	unsigned int addrlen;
	struct ip *iphdr;
	int iphdrlen;
	int reply_type, reply_id, reply_seq;
	int hdr_size;	/* size of the ICMP/ICMPv6 header in the buffer */
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
		n = recvfrom(sock, buffer, sizeof(buffer), 0, (struct sockaddr *)&addr, &addrlen);
		if (n < 0) {
			/* EWOULDBLOCK and EAGAIN differ on some systems (HP-UX); either
			 * means nothing is left to read. */
			if ((errno != EWOULDBLOCK) && (errno != EAGAIN)) errprintf("Failed to receive packet: %s\n", strerror(errno));
			continue;
		}

		getntimer(&rtt);

		/* An IPv4 raw socket always delivers the IP header; ICMPv6
		 * sockets never do. An IPv4 SOCK_DGRAM socket leaves it out on
		 * Linux but not on every system (macOS keeps it), so look: an
		 * IPv4 header starts with version 4, while the echo reply we are
		 * after starts with type 0. */
		if ((family == AF_INET) && (!is_dgram || ((n > 0) && ((buffer[0] >> 4) == 4)))) {
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

		/* Parse the ICMP/ICMPv6 header into family-neutral locals. */
		if (family == AF_INET) {
			struct icmp *icmphdr = (struct icmp *)(buffer + iphdrlen);
			reply_type = icmphdr->icmp_type;
			reply_id   = ntohs(icmphdr->icmp_id);
			reply_seq  = ntohs(icmphdr->icmp_seq);
			hdr_size   = sizeof(struct icmp);
		}
		else {
			struct icmp6_hdr *icmp6hdr = (struct icmp6_hdr *)(buffer + iphdrlen);
			reply_type = icmp6hdr->icmp6_type;
			reply_id   = ntohs(icmp6hdr->icmp6_id);
			reply_seq  = ntohs(icmp6hdr->icmp6_seq);
			hdr_size   = sizeof(struct icmp6_hdr);
		}
		hostidx = reply_seq - 1;

		if (debug) {
			dbgprintf("Got packet from %s: type=%d, index=%d, id=%d\n",
				sockaddr_str(&addr), reply_type, reply_id, hostidx);
		}

		/* Non-reply types (our own echoes when pinging ourselves,
		 * UNREACH/REDIRECT, link-local v6 chatter, etc.) are skipped
		 * silently. We only care about ECHO_REPLY for our packets. */
		if (reply_type != ((family == AF_INET) ? ICMP_ECHOREPLY : ICMP6_ECHO_REPLY)) {
			continue;
		}
		if (!is_dgram && reply_id != myicmpid) {
			/* SOCK_RAW: not one of our packets (someone else is
			 * also pinging). SOCK_DGRAM: kernel already matched. */
			continue;
		}
		if (hostidx < 0 || hostidx >= hostcount) continue;
		if (hosts[hostidx]->family != family) continue;

		/* Make sure the reply is large enough to actually contain
		 * the pingdata_t payload before we dereference it. A short
		 * but well-formed ECHOREPLY would otherwise read past the
		 * received bytes into stale static-buffer contents. */
		if (n < (int)(iphdrlen + hdr_size + sizeof(struct pingdata_t))) continue;
		memcpy(&pingdata, buffer + iphdrlen + hdr_size, sizeof(pingdata));

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
		if (((int64_t)rtt.tv_sec * 1000000000LL + rtt.tv_nsec) > try_timeout_ns(pingdata.probe_idx)) continue;

		if (hosts[hostidx]->probe_state) {
			/* Only a ping still PS_SENT may count: PS_REPLIED rejects
			 * duplicates, and PS_TIMEOUT rejects a late reply whose
			 * deadline has passed (otherwise it would revive a ping
			 * the loop already gave up on). With --samples the rtt
			 * is kept at the slot the payload carries. */
			int pidx = pingdata.probe_idx;
			if (pidx < 0 || pidx >= hosts[hostidx]->probe_slots) continue;
			if (hosts[hostidx]->probe_state[pidx] != PS_SENT) continue;
			if (hosts[hostidx]->samples_usec) {
				hosts[hostidx]->samples_usec[pidx] =
					(unsigned long)(rtt.tv_sec) * 1000000UL +
					(unsigned long)(rtt.tv_nsec / 1000);
				inflight--;
			}
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


/* Build readfds covering both family sockets we actually opened, and
 * return the max fd + 1 (the nfds argument to select). Used by the
 * smoke loop and its drain phase. */
static int select_set(fd_set *readfds)
{
	int maxfd = -1;
	FD_ZERO(readfds);
	if (pingsocket_v4 >= 0) { FD_SET(pingsocket_v4, readfds); if (pingsocket_v4 > maxfd) maxfd = pingsocket_v4; }
	if (pingsocket_v6 >= 0) { FD_SET(pingsocket_v6, readfds); if (pingsocket_v6 > maxfd) maxfd = pingsocket_v6; }
	return maxfd + 1;
}

/* Drain whichever family socket has data ready. */
static void drain_replies(fd_set *readfds)
{
	if (pingsocket_v4 >= 0 && FD_ISSET(pingsocket_v4, readfds))
		(void)get_response(pingsocket_v4, AF_INET, is_dgram_v4);
	if (pingsocket_v6 >= 0 && FD_ISSET(pingsocket_v6, readfds))
		(void)get_response(pingsocket_v6, AF_INET6, is_dgram_v6);
}

/* Read whatever replies are already waiting, without blocking: done
 * before a deadline is acted on, so a reply that arrived in time is
 * counted even when select() was interrupted or the loop was busy
 * sending. */
static void drain_now(void)
{
	if (pingsocket_v4 >= 0) (void)get_response(pingsocket_v4, AF_INET, is_dgram_v4);
	if (pingsocket_v6 >= 0) (void)get_response(pingsocket_v6, AF_INET6, is_dgram_v6);
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

/* --samples driver. Each host's samples_count pings go out
 * per_host_interval_ms apart, the hosts staggered within that interval so
 * they interleave on the wire, and no two pings closer than --max-pps
 * allows. Only each host's next ping is queued, so the queue holds one send
 * per host, not N. A send queues its own EV_EXPIRE at --timeout, after
 * which a reply for that ping no longer counts. The run ends once every
 * ping is sent and none is still waiting. */
static int smoke_main_loop(int timeout_ms)
{
	int i, unsent;
	int64_t start_ns, step_ns, stagger_ns, sent_ns;
	int64_t senddelay_ns = (int64_t)senddelay * 1000LL;	/* senddelay is in us; honor --max-pps / -i */

	if ((int64_t)hostcount * (int64_t)samples_count > (int64_t)MAX_TOTAL_PROBES) {
		errprintf("Refusing to schedule %d hosts x %d samples = %lld probes (cap %d)\n",
		          hostcount, samples_count,
		          (long long)hostcount * samples_count, MAX_TOTAL_PROBES);
		return 5;
	}

	if (timeout_ms < 0) timeout_ms = samples_timeout_ms();
	probe_timeout_ns = (int64_t)timeout_ms * 1000000LL;
	backoff = 1.0;
	hosts_pending = hostcount;
	start_ns = mono_ns();
	step_ns = (int64_t)per_host_interval_ms * 1000000LL;
	stagger_ns = (hostcount > 0) ? step_ns / hostcount : 0;

	for (i = 0; i < hostcount; i++) {
		pingevent_t e;
		e.when_ns    = start_ns + (int64_t)i * stagger_ns;
		e.host_idx   = i;
		e.probe_idx  = 0;
		e.retries    = 0;
		e.kind       = EV_SEND;
		e.tries_left = 0;	/* --samples doesn't retry */
		schedule(&sends, e);
	}
	unsent = hostcount * samples_count;

	myicmpid = (getpid() & 0x7FFF);
	next_send_ns = start_ns;

	while ((unsent > 0) || (inflight > 0)) {
		pingevent_t ev;
		hostdata_t *h;
		int r = next_event(&ev);

		if (r < 0) return 4;
		if (r == 0) break;
		h = hosts[ev.host_idx];

		if (ev.kind == EV_SEND) {
			r = send_probe(ev.host_idx, ev.probe_idx);
			sent_ns = mono_ns();	/* when the ping left: send_probe() has returned */
			if (r != -1) next_send_ns = mono_ns() + senddelay_ns;
			if ((r == -1) && (ev.retries < EWOULDBLOCK_MAX_RETRIES)) {
				/* EWOULDBLOCK: socket buffer momentarily full.
				 * Reschedule 1 ms later, bounded retries. */
				ev.retries++;
				ev.when_ns = mono_ns() + 1000000LL;
				schedule(&sends, ev);
				continue;
			}

			unsent--;
			h->sent++;
			if (r == 0) {
				pingevent_t x = ev;
				h->probe_state[ev.probe_idx] = PS_SENT;
				inflight++;
				x.kind    = EV_EXPIRE;
				x.when_ns = mono_ns() + try_timeout_ns(x.probe_idx);
				schedule(&expiries, x);
			}
			else {
				/* Hard send error, or EWOULDBLOCK exhausted: it
				 * counts as sent for loss accounting, and no reply
				 * will arrive. */
				h->probe_state[ev.probe_idx] = PS_ERROR;
			}

			/* Queue this host's next ping one --per-host-interval after
			 * this one actually left, as fping does: a ping that went out
			 * late does not shorten the gap to the next. */
			if (ev.probe_idx + 1 < samples_count) {
				ev.probe_idx++;
				ev.retries = 0;
				ev.when_ns = sent_ns + step_ns;
				schedule(&sends, ev);
			}
		}
		else {
			/* EV_EXPIRE: this ping's reply deadline. Read what is
			 * already waiting first, so a reply that arrived in
			 * time still counts. */
			drain_now();
			if (h->probe_state[ev.probe_idx] == PS_SENT) {
				h->probe_state[ev.probe_idx] = PS_TIMEOUT;
				inflight--;
			}
		}
	}

	evheap_clear(&sends);
	evheap_clear(&expiries);
	return 0;
}

/* Main loop without --samples. Each host gets one EV_SEND, in host order
 * one --max-pps slot apart, with a retry budget; a send queues an EV_EXPIRE
 * at t+timeout. On EV_EXPIRE without a reply the host either re-arms
 * (tries_left > 0) or is given up on. The run ends when every host has its
 * --responses replies or nothing is left to do. */
static int retry_main_loop(int timeout_ms, int tries)
{
	int i;
	int64_t senddelay_ns = (int64_t)senddelay * 1000LL;	/* senddelay is in us; honor --max-pps / -i */
	int64_t start_ns = mono_ns();

	if (tries <= 0) tries = 1;
	/* As fping: the first try waits 500 ms (or --timeout), each retry
	 * 1.5 times longer than the one before. */
	probe_timeout_ns = (int64_t)((timeout_ms < 0) ? 500 : timeout_ms) * 1000000LL;
	backoff = 1.5;
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
				ev.when_ns = mono_ns() + try_timeout_ns(ev.probe_idx);
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
				ev.when_ns = mono_ns() + try_timeout_ns(ev.probe_idx);
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

/* How a result names its host: an IPv4 address in dotted form, as it always
 * was; an IPv6 one as it was given, so its text and any %iface scope match
 * the caller's (inet_ntop() would rewrite the one and drop the other). */
static const char *host_label(hostdata_t *h)
{
	return (h->family == AF_INET6) ? h->name : sockaddr_str(&h->addr);
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
			printf("%s is alive", host_label(hosts[idx]));
			rtt_usecs = (hosts[idx]->rtt_total.tv_sec*1000000 + (hosts[idx]->rtt_total.tv_nsec / 1000)) / hosts[idx]->received;
			if (rtt_usecs >= 3000) {
				printf(" (%.1f ms)", rtt_usecs / 1000.0);
			}
			else {
				printf(" (%lu usec)", rtt_usecs);
			}
			if (samples_count > 0) {
				/* Walk probe_state[] in send order so consumers see
				 * samples in the order they were issued, not the
				 * order replies arrived. Median consumers don't care
				 * about ordering; humans reading the line do. */
				int k, emitted = 0;
				printf(" samples=");
				for (k = 0; k < samples_count; k++) {
					if (hosts[idx]->probe_state[k] != PS_REPLIED) continue;
					printf("%s%.6f", (emitted > 0 ? "," : ""),
					       hosts[idx]->samples_usec[k] / 1000000.0);
					emitted++;
				}
				printf(" loss=%d/%d\n",
				       hosts[idx]->sent - hosts[idx]->received,
				       hosts[idx]->sent);
			}
			else {
				printf("\n");
			}
		}
		else {
			if (samples_count > 0) {
				printf("%s is unreachable loss=%d/%d\n",
				       host_label(hosts[idx]),
				       hosts[idx]->sent, hosts[idx]->sent);
			}
			else {
				printf("%s is unreachable\n", host_label(hosts[idx]));
			}
		}
	}
}

/* Try SOCK_DGRAM + IPPROTO_ICMP{,V6} first -- on Linux this works for
 * unprivileged users whose GID is in net.ipv4.ping_group_range, with no
 * setcap / suid-root needed. The kernel manages icmp_id and strips any
 * IP header on RX (get_response handles both forms). Fall back to
 * SOCK_RAW (the historical path) if dgram is denied. */
static int open_icmp_socket(int family, int *is_dgram_out, int *err_out)
{
	int proto = (family == AF_INET) ? IPPROTO_ICMP : IPPROTO_ICMPV6;
	int s;

	s = socket(family, SOCK_DGRAM, proto);
	if (s >= 0) { *is_dgram_out = 1; return s; }

	get_root();
	s = socket(family, SOCK_RAW, proto);
	*err_out = errno;
	drop_root();
	*is_dgram_out = 0;
	return s;
}

int main(int argc, char *argv[])
{
	int sockerr = 0, binderr = 0;
	int argi, tries = 4, timeout_ms = -1;	/* fping's defaults: -r 3, -t 500 ms (set in the loops) */
	int need_v4 = 0, need_v6 = 0;
	int i;
	char *srcip = NULL;
	struct sockaddr_in src_addr;
	struct sockaddr_in6 src_addr6;
	int src_family = 0;

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
			if (t > 0) timeout_ms = 1000 * t;
			else errprintf("Ignoring --timeout=%s: it must be at least 1\n", delim+1);
		}
		else if (strncmp(argv[argi], "--responses=", 11) == 0) {
			char *delim = strchr(argv[argi], '=');
			minresponses = atoi(delim+1);
		}
		else if (strncmp(argv[argi], "--samples=", 10) == 0) {
			char *delim = strchr(argv[argi], '=');
			samples_count = atoi(delim+1);
			if (samples_count < 0) samples_count = 0;
			if (samples_count > MAX_SAMPLES_PER_HOST) {
				errprintf("Clamping --samples=%d to the per-host cap of %d\n",
				          samples_count, MAX_SAMPLES_PER_HOST);
				samples_count = MAX_SAMPLES_PER_HOST;
			}
		}
		else if (strncmp(argv[argi], "--per-host-interval=", 20) == 0) {
			char *delim = strchr(argv[argi], '=');
			per_host_interval_ms = atoi(delim+1);
			if (per_host_interval_ms < 0) per_host_interval_ms = -1;
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
			fprintf(stderr, "%s [--retries=N] [--timeout=N] [--responses=N] [--samples=N] [--per-host-interval=MS] [--max-pps=N] [--source=IP]\n", argv[0]);
			fprintf(stderr, "  Reads IPv4/IPv6 addresses from stdin, one per line.\n");
			return 0;
		}

		/* fping compatibility options, meaning what fping's do: -iMS the
		 * least time between two pings, -rN the retries, -tMS the first
		 * try's timeout. */
		else if (strncmp(argv[argi], "-i", 2) == 0) {
			char *val = argv[argi] + 2;
			if (isdigit((int) *val)) senddelay = 1000 * atoi(val);
		}
		else if (strncmp(argv[argi], "-r", 2) == 0) {
			char *val = argv[argi] + 2;
			if (isdigit((int) *val)) tries = 1 + atoi(val);
		}
		else if (strncmp(argv[argi], "-t", 2) == 0) {
			char *val = argv[argi] + 2;
			if (isdigit((int) *val) && (atoi(val) > 0)) timeout_ms = atoi(val);
		}
		else if (strncmp(argv[argi], "-S", 2) == 0) {
			char *val = argv[argi] + 2;
			srcip = strdup(val);
		}
		else if (*(argv[argi]) == '-') {
			/* Ignore everything else - for fping compatibility */
		}
	}

	/* Smoke mode is driven by smoke_main_loop() further down; the
	 * legacy retry/pending loop is not entered. Probes to one host go
	 * out 1000 ms apart by default, fping's -p default and so what
	 * SmokePing measures with: one train per cycle, a snapshot of the
	 * link, rather than N probes squeezed into the reply timeout. */
	if ((samples_count > 0) && (per_host_interval_ms < 0)) per_host_interval_ms = 1000;

	/* --source: an IPv6 address binds the IPv6 socket, an IPv4 one the
	 * IPv4 socket; each family's pings leave from their own source. */
	memset(&src_addr, 0, sizeof(src_addr));
	memset(&src_addr6, 0, sizeof(src_addr6));
	if (srcip != NULL) {
		if (inet_pton(AF_INET6, srcip, &src_addr6.sin6_addr) == 1) {
			src_family = AF_INET6;
			src_addr6.sin6_family = AF_INET6;
		}
		else {
			src_family = AF_INET;
			src_addr.sin_family = AF_INET;
			src_addr.sin_addr.s_addr = inet_addr(srcip);
			src_addr.sin_port = htons(0);
		}
	}


	load_ips(argc, argv, stdin);

	/* Decide which sockets we actually need based on the host list. */
	for (i = 0; i < hostcount; i++) {
		if (hosts[i]->family == AF_INET6) need_v6 = 1;
		else                              need_v4 = 1;
	}
	if (!need_v4 && !need_v6) return 0;	/* nothing to ping: no output, as before */

	/* A family whose socket cannot be opened is reported, and its hosts
	 * come out unreachable (send_probe() fails for them); the other
	 * family is still pinged. Only when no socket at all can be had
	 * does the run end, with exit status 3. */
	if (need_v4) {
		pingsocket_v4 = open_icmp_socket(AF_INET, &is_dgram_v4, &sockerr);
		if (pingsocket_v4 == -1) {
			errprintf("Cannot open IPv4 ICMP socket: %s\n", strerror(sockerr));
			if (sockerr == EPERM || sockerr == EACCES) {
				errprintf("Either run as a user whose group is in net.ipv4.ping_group_range,\n");
				errprintf("or install the binary suid-root or with cap_net_raw.\n");
			}
		}
		else {
			if ((src_family == AF_INET) && (bind(pingsocket_v4, (struct sockaddr *)&src_addr, sizeof(src_addr)) == -1)) {
				binderr = errno;
				errprintf("Cannot bind to source address %s: %s\nUsing default address\n",
				          srcip, strerror(binderr));
			}
			fcntl(pingsocket_v4, F_SETFL, O_NONBLOCK);
		}
	}

	if (need_v6) {
		pingsocket_v6 = open_icmp_socket(AF_INET6, &is_dgram_v6, &sockerr);
		if (pingsocket_v6 == -1) errprintf("Cannot open IPv6 ICMP socket: %s\n", strerror(sockerr));
		else {
			if ((src_family == AF_INET6) && (bind(pingsocket_v6, (struct sockaddr *)&src_addr6, sizeof(src_addr6)) == -1)) {
				errprintf("Cannot bind to source address %s: %s\nUsing default address\n",
				          srcip, strerror(errno));
			}
			fcntl(pingsocket_v6, F_SETFL, O_NONBLOCK);
		}
	}

	if ((pingsocket_v4 == -1) && (pingsocket_v6 == -1)) return 3;

	{
		/* Both modes drive sends from the shared event heap. Smoke
		 * fans out N samples per host with no retries; legacy
		 * schedules one EV_SEND per host with EV_EXPIRE-driven
		 * retries up to --retries=N. */
		int rc = (samples_count > 0) ? smoke_main_loop(timeout_ms)
		                             : retry_main_loop(timeout_ms, tries);
		if (pingsocket_v4 != -1) close(pingsocket_v4);
		if (pingsocket_v6 != -1) close(pingsocket_v6);
		if (rc == 0) show_results();
		return rc;
	}
}
