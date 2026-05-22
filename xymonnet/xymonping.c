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
#include <netdb.h>

#include <stdio.h>

#include "libxymon.h"
#include "evheap.h"

#define PING_PACKET_SIZE 64
#define PING_MINIMUM_SIZE ICMP_MINLEN
#define SENDLIMIT 100

/* Safety caps. xymon is normally run with a few thousand hosts at
 * most; these are several orders of magnitude above realistic and
 * exist only to fail cleanly on a corrupt or hostile hosts.cfg
 * instead of OOM-ing the box. */
/* The 16-bit ICMP echo sequence carries (host_idx + 1), so two hosts
 * with indices that differ by a multiple of 65536 would receive each
 * other's replies. The reply-side cross-check on pingdata->id catches
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
	int received;			/* how many ICMP_ECHO replies we've got */
	int sent;			/* how many ICMP_ECHO requests we've sent (smoke mode) */
	struct timespec rtt_total;
	int64_t  timeout_ns;		/* per-host probe-reply deadline; 0 = use --timeout */
	unsigned long *samples_usec;	/* smoke mode: rtt in usec, indexed by probe_idx; NULL in legacy */
	uint8_t       *probe_state;	/* smoke mode: PS_* per probe_idx; NULL in legacy */
	int64_t       *probe_sent_at;	/* smoke mode: monotonic-ns send time per probe; NULL in legacy */
	struct hostdata_t *next;
} hostdata_t;

hostdata_t *hosthead = NULL;
int hostcount = 0;
hostdata_t **hosts = NULL;	/* Array of pointers to the hostdata records, for fast access via ID */
int myicmpid;
int senddelay = (1000000 / 50);	/* Delay between sending packets, in microseconds */
int samples_count = 0;		/* >0 enables smoke mode: send exactly N pings per host, record each rtt */
int per_host_interval_ms = -1;	/* spacing between probes for one host in smoke mode; -1 = auto */
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


char *nextip(int argc, char *argv[], FILE *fd)
{
	static int argi = 0;
	static int cmdmode = 0;
	static char buf[4096];

	if (argi == 0) {
		/* Check if there are any command-line IP's. Must accept the
		 * same families as load_ips() below -- otherwise an IPv6
		 * argument falls through to stdin and we report "No hosts
		 * to ping" for a documented-supported invocation. */
		struct in_addr  a4;
		struct in6_addr a6;

		for (argi=1; argi < argc; argi++) {
			if (inet_pton(AF_INET,  argv[argi], &a4) == 1) break;
			if (inet_pton(AF_INET6, argv[argi], &a6) == 1) break;
		}
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
		int per_host_timeout_ms = 0;	/* 0 = inherit --timeout */
		char *sp;

		if (strlen(l) == 0) continue;

		if (hostcount >= MAX_HOSTS) {
			errprintf("Host cap %d reached, refusing additional entries\n", MAX_HOSTS);
			break;
		}

		/* Optional whitespace-separated second token: per-host probe-
		 * reply deadline in milliseconds. Lets the orchestrator pass
		 * fast/slow hosts on the same stdin pipe without forcing one
		 * global --timeout. cmdmode args don't have a second token. */
		sp = strchr(l, ' ');
		if (!sp) sp = strchr(l, '\t');
		if (sp) {
			*sp = '\0';
			while (*++sp == ' ' || *sp == '\t') {}
			if (*sp) per_host_timeout_ms = atoi(sp);
			if (per_host_timeout_ms < 0) per_host_timeout_ms = 0;
		}

		newitem = (hostdata_t *)calloc(1, sizeof(hostdata_t));

		/* Try v6 first because a v4 address is also a syntactically
		 * acceptable string to inet_pton(AF_INET6) only in mapped
		 * form (::ffff:1.2.3.4); a bare "1.2.3.4" parses as v4 only. */
		{
			struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&newitem->addr;
			struct sockaddr_in  *sin4 = (struct sockaddr_in  *)&newitem->addr;
			if (inet_pton(AF_INET6, l, &sin6->sin6_addr) == 1) {
				newitem->family  = AF_INET6;
				sin6->sin6_family = AF_INET6;
				sin6->sin6_port   = 0;
				newitem->addrlen  = sizeof(struct sockaddr_in6);
			}
			else if (inet_pton(AF_INET, l, &sin4->sin_addr) == 1) {
				newitem->family  = AF_INET;
				sin4->sin_family = AF_INET;
				sin4->sin_port   = 0;
				newitem->addrlen = sizeof(struct sockaddr_in);
			}
			else {
				errprintf("Dropping %s - not an IP\n", l);
				free(newitem);
				continue;
			}
		}

		/* The legacy ping path (send_ping) doesn't know about v6; if
		 * a smoke run wasn't requested, drop v6 hosts at load time so
		 * we don't try to call send_ping on them later. */
		if (samples_count <= 0 && newitem->family == AF_INET6) {
			errprintf("Dropping %s - IPv6 requires --samples=N (smoke mode)\n", l);
			free(newitem);
			continue;
		}

		newitem->timeout_ns = (int64_t)per_host_timeout_ms * 1000000LL;

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
	for (i=0, walk=hosthead; (walk); walk=walk->next, i++) hosts[i] = walk;
	hosts[hostcount] = NULL;

	/* In smoke mode, each host gets a per-sample rtt array, a per-probe
	 * state machine, and a per-probe monotonic send timestamp. All
	 * three are indexed by probe_idx. */
	if (samples_count > 0) {
		for (i = 0; i < hostcount; i++) {
			hosts[i]->samples_usec  = (unsigned long *)calloc(samples_count, sizeof(unsigned long));
			hosts[i]->probe_state   = (uint8_t *)calloc(samples_count, sizeof(uint8_t));
			hosts[i]->probe_sent_at = (int64_t *)calloc(samples_count, sizeof(int64_t));
		}
	}
}


/* This is the data we send with each ping packet. The payload carries
 * both the host index and the probe ordinal so replies can be matched
 * back to a specific scheduled probe (needed for smoke mode where each
 * host has multiple in-flight pings). icmp_seq still encodes host_idx
 * for compatibility with the existing legacy receive path. */
typedef struct pingdata_t {
	int id;				/* ID for the host this belongs to */
	int probe_idx;			/* smoke mode: 0..samples_count-1; 0 in legacy */
	struct timespec timesent;	/* time we sent this ping */
} pingdata_t;

static int64_t mono_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

/* Sends a single probe identified by (host_idx, probe_idx). Returns
 *   0  on successful send,
 *  -1  on EWOULDBLOCK (caller should reschedule shortly),
 *  -2  on hard send error (caller should mark probe as ERROR). */
#define EWOULDBLOCK_MAX_RETRIES 5

static int send_probe(int host_idx, int probe_idx)
{
	static unsigned char buffer[PING_PACKET_SIZE];
	struct pingdata_t *pingdata;
	int sentbytes, sock;
	int family = hosts[host_idx]->family;
	int hdr_size;

	if (family == AF_INET) {
		sock = pingsocket_v4;
		hdr_size = sizeof(struct icmp);
	}
	else {
		sock = pingsocket_v6;
		hdr_size = sizeof(struct icmp6_hdr);
	}
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
		pingdata = (struct pingdata_t *)(buffer + sizeof(struct icmp));
		pingdata->id        = host_idx;
		pingdata->probe_idx = probe_idx;
		getntimer(&pingdata->timesent);
		icmphdr->icmp_cksum = calc_icmp_checksum((unsigned short *)buffer, PING_PACKET_SIZE);
	}
	else {
		struct icmp6_hdr *icmp6hdr = (struct icmp6_hdr *)buffer;
		icmp6hdr->icmp6_type  = ICMP6_ECHO_REQUEST;
		icmp6hdr->icmp6_code  = 0;
		icmp6hdr->icmp6_cksum = 0;	/* kernel computes for ICMPv6 */
		icmp6hdr->icmp6_seq   = htons(host_idx + 1);
		icmp6hdr->icmp6_id    = htons(myicmpid);
		pingdata = (struct pingdata_t *)(buffer + sizeof(struct icmp6_hdr));
		pingdata->id        = host_idx;
		pingdata->probe_idx = probe_idx;
		getntimer(&pingdata->timesent);
	}

	(void)hdr_size;

	sentbytes = sendto(sock, buffer, PING_PACKET_SIZE, 0,
	                   (struct sockaddr *)&hosts[host_idx]->addr,
	                   hosts[host_idx]->addrlen);

	if (sentbytes == -1) {
		if (errno == EWOULDBLOCK) return -1;
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


int send_ping(int sock, int startidx, int minresponses)
{
	static unsigned char buffer[PING_PACKET_SIZE];
	struct icmp *icmphdr;
	struct pingdata_t *pingdata;
	int sentbytes;
	int idx = startidx;

	/*
	 * Sends one ICMP "echo-request" packet.
	 *
	 * Note: A first attempt at this kept sending packets until
	 * we got an EWOULDBLOCK or a send error. This causes incoming
	 * responses to be dropped.
	 */

	/* Skip the hosts that have already delivered a ping response. */
	while ((idx < hostcount) && (hosts[idx]->received >= minresponses)) idx++;
	if (idx >= hostcount) return hostcount;

	/* 
	 * Don't flood the net.
	 * By enforcing a brief sleep here, we force a delay
	 * between sending packets. It is easiest to do before sending
	 * a packet, because if done after the send completes, then
	 * it affects the RTT measurements.
	 */
	if (senddelay) usleep(senddelay);

	/* Build the packet and send it */
	memset(buffer, 0, PING_PACKET_SIZE);

	icmphdr = (struct icmp *)buffer;
	icmphdr->icmp_type = ICMP_ECHO;
	icmphdr->icmp_code = 0;
	icmphdr->icmp_cksum = 0;
	icmphdr->icmp_seq = htons(idx+1);	/* So we can map response to our hosts */
	icmphdr->icmp_id = htons(myicmpid);

	pingdata = (struct pingdata_t *)(buffer + sizeof(struct icmp));
	pingdata->id = idx;
	getntimer(&pingdata->timesent);

	icmphdr->icmp_cksum = calc_icmp_checksum((unsigned short *)buffer, PING_PACKET_SIZE);

	sentbytes = sendto(sock, buffer, PING_PACKET_SIZE, 0,
	                   (struct sockaddr *)&hosts[idx]->addr, hosts[idx]->addrlen);

	if (sentbytes == -1) {
		if (errno != EWOULDBLOCK) {
			errprintf("Failed to send ICMP packet: %s\n", strerror(errno));
			idx++; /* To avoid looping indefinitely trying to send to this host */
		}
	}
	else if (sentbytes == PING_PACKET_SIZE) {
		/* We managed to send a ping! */
		if (debug) {
			dbgprintf("Sent a ping to %s: index=%d, id=%d\n",
				sockaddr_str(&hosts[idx]->addr), idx, myicmpid);
		}
		hosts[idx]->sent++;
		idx++;
	}

	return idx;
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
	struct pingdata_t *pingdata;
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
			if (errno != EWOULDBLOCK) errprintf("Failed to receive packet: %s\n", strerror(errno));
			continue;
		}

		getntimer(&rtt);

		/* IPv4 RAW prepends the IP header; IPv4 DGRAM and all IPv6
		 * variants do not. Compute the offset of the ICMP/ICMPv6
		 * header and validate length. */
		if (family == AF_INET && !is_dgram) {
			iphdr = (struct ip *)buffer;
			iphdrlen = (iphdr->ip_hl << 2);
			if (n < (iphdrlen + PING_MINIMUM_SIZE)) {
				errprintf("Short packet ignored\n");
				continue;
			}
		}
		else {
			iphdrlen = 0;
			if (n < PING_MINIMUM_SIZE) {
				errprintf("Short packet ignored\n");
				continue;
			}
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
		pingdata = (struct pingdata_t *)(buffer + iphdrlen + hdr_size);

		/* icmp_seq carries only 16 bits of host index; the payload
		 * carries the full 32-bit id. Cross-check so seq-aliased
		 * hosts (when hostcount > 65535) and spoofed replies whose
		 * seq happens to land on a live host can't cross-attribute. */
		if (pingdata->id != hostidx) continue;

		/* Calculate the round-trip time. */
		rtt.tv_sec -= pingdata->timesent.tv_sec;
		rtt.tv_nsec -= pingdata->timesent.tv_nsec;
		if (rtt.tv_nsec < 0) {
			rtt.tv_sec--;
			rtt.tv_nsec += 1000000000;
		}

		if (hosts[hostidx]->probe_state) {
			/* Smoke mode: store rtt at the probe_idx slot the
			 * payload carries. Only PS_SENT probes are eligible:
			 * PS_REPLIED rejects duplicates, and PS_TIMEOUT
			 * rejects late replies whose per-probe deadline has
			 * already elapsed (otherwise they would silently
			 * cancel the loss we already counted). */
			int pidx = pingdata->probe_idx;
			if (pidx < 0 || pidx >= samples_count) continue;
			if (hosts[hostidx]->probe_state[pidx] != PS_SENT) continue;
			hosts[hostidx]->samples_usec[pidx] =
				(unsigned long)(rtt.tv_sec) * 1000000UL +
				(unsigned long)(rtt.tv_nsec / 1000);
			hosts[hostidx]->probe_state[pidx] = PS_REPLIED;
		}

		pktcount++;
		hosts[hostidx]->received += 1;

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

int count_pending(int minresponses)
{
	int result = 0;
	int idx;

	/* Counts how many hosts we haven't seen a reply from yet. */
	for (idx = 0; (idx < hostcount); idx++)
		if (hosts[idx]->received < minresponses) result++;

	return result;
}

/* Returns the earliest per-probe deadline (probe_sent_at + host.timeout_ns)
 * across all PS_SENT probes, or INT64_MAX if no probe is still in flight.
 * The drain loop sleeps to that point, then re-checks. Probes whose
 * deadline has already passed are implicitly given up on. */
static int64_t smoke_earliest_inflight_deadline(void)
{
	int i, k;
	int64_t best = INT64_MAX;

	for (i = 0; i < hostcount; i++) {
		for (k = 0; k < samples_count; k++) {
			int64_t d;
			if (hosts[i]->probe_state[k] != PS_SENT) continue;
			d = hosts[i]->probe_sent_at[k] + hosts[i]->timeout_ns;
			if (d < best) best = d;
		}
	}
	return best;
}

/* Smoke-mode driver. Schedules samples_count probes per host on a shared
 * min-heap, dispatches sends in time order, and processes replies as
 * they arrive. After the heap drains, waits up to `timeout` seconds for
 * late replies. Hosts are staggered within one per-host interval so the
 * first round interleaves them across the wire instead of bursting one
 * host's probes back-to-back. */
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

static int smoke_main_loop(int timeout)
{
	int i, k;
	int64_t start_ns;
	int64_t per_host_step_ns;
	int64_t host_stagger_ns;

	if ((int64_t)hostcount * (int64_t)samples_count > (int64_t)MAX_TOTAL_PROBES) {
		errprintf("Refusing to schedule %d hosts x %d samples = %lld probes (cap %d)\n",
		          hostcount, samples_count,
		          (long long)hostcount * samples_count, MAX_TOTAL_PROBES);
		return 5;
	}

	start_ns = mono_ns();
	per_host_step_ns = (int64_t)per_host_interval_ms * 1000000LL;
	host_stagger_ns = (hostcount > 0) ? per_host_step_ns / hostcount : 0;

	/* Hosts that didn't bring their own timeout from the stdin line
	 * inherit --timeout. Done here, not in load_ips, because --timeout
	 * is parsed after load_ips runs. */
	for (i = 0; i < hostcount; i++) {
		if (hosts[i]->timeout_ns <= 0) {
			hosts[i]->timeout_ns = (int64_t)timeout * 1000000000LL;
		}
	}

	for (i = 0; i < hostcount; i++) {
		for (k = 0; k < samples_count; k++) {
			pingevent_t e;
			e.when_ns   = start_ns + (int64_t)k * per_host_step_ns
			                       + (int64_t)i * host_stagger_ns;
			e.host_idx  = i;
			e.probe_idx = k;
			e.retries   = 0;
			evheap_push(e);
		}
	}

	myicmpid = (getpid() & 0x7FFF);

	while (evheap_size() > 0) {
		int64_t next_when, now, wait_ns;
		struct timeval tv;
		fd_set readfds;
		int n;

		evheap_peek_when(&next_when);
		now = mono_ns();
		wait_ns = next_when - now;

		if (wait_ns <= 0) {
			/* Fire the next-due send. */
			pingevent_t ev;
			int r;
			evheap_pop(&ev);
			r = send_probe(ev.host_idx, ev.probe_idx);
			if (r == 0) {
				hosts[ev.host_idx]->sent++;
				hosts[ev.host_idx]->probe_state[ev.probe_idx] = PS_SENT;
				hosts[ev.host_idx]->probe_sent_at[ev.probe_idx] = mono_ns();
			}
			else if (r == -1) {
				/* EWOULDBLOCK: socket buffer momentarily full.
				 * Reschedule 1 ms later, bounded retries. */
				if (ev.retries < EWOULDBLOCK_MAX_RETRIES) {
					ev.retries++;
					ev.when_ns = mono_ns() + 1000000LL;
					evheap_push(ev);
				}
				else {
					hosts[ev.host_idx]->sent++;
					hosts[ev.host_idx]->probe_state[ev.probe_idx] = PS_ERROR;
				}
			}
			else {
				/* Hard send error: counts as sent for loss
				 * accounting; no reply will ever arrive. */
				hosts[ev.host_idx]->sent++;
				hosts[ev.host_idx]->probe_state[ev.probe_idx] = PS_ERROR;
			}
			continue;
		}

		/* Sleep until next send, processing any reply that wakes us. */
		tv.tv_sec  = wait_ns / 1000000000LL;
		tv.tv_usec = (wait_ns % 1000000000LL) / 1000;
		{
			int nfds = select_set(&readfds);
			n = select(nfds, &readfds, NULL, NULL, &tv);
		}
		if (n < 0) {
			if (errno == EINTR) continue;
			errprintf("select failed: %s\n", strerror(errno));
			return 4;
		}
		if (n > 0) drain_replies(&readfds);
	}

	/* Drain phase: heap is empty; wait for late replies until either
	 * every probe has a verdict or its per-host deadline has elapsed.
	 * smoke_earliest_inflight_deadline() returns INT64_MAX when no
	 * probe is still in flight, which breaks the loop. */
	for (;;) {
		int64_t earliest, now, wait_ns;
		struct timeval tv;
		fd_set readfds;
		int n, nfds;

		earliest = smoke_earliest_inflight_deadline();
		if (earliest == INT64_MAX) break;

		now = mono_ns();
		wait_ns = earliest - now;
		if (wait_ns <= 0) {
			/* Earliest deadline has passed. Mark every probe whose
			 * own deadline is now in the past as PS_TIMEOUT so the
			 * next iteration picks up the next earliest still in
			 * flight (later-scheduled probes may still be within
			 * their per-host timeout). */
			int i, k;
			for (i = 0; i < hostcount; i++) {
				if (!hosts[i]->probe_state) continue;
				for (k = 0; k < samples_count; k++) {
					int64_t d;
					if (hosts[i]->probe_state[k] != PS_SENT) continue;
					d = hosts[i]->probe_sent_at[k] + hosts[i]->timeout_ns;
					if (d <= now) hosts[i]->probe_state[k] = PS_TIMEOUT;
				}
			}
			continue;
		}
		tv.tv_sec  = wait_ns / 1000000000LL;
		tv.tv_usec = (wait_ns % 1000000000LL) / 1000;
		nfds = select_set(&readfds);
		n = select(nfds, &readfds, NULL, NULL, &tv);
		if (n < 0) {
			if (errno == EINTR) continue;
			errprintf("select failed: %s\n", strerror(errno));
			return 4;
		}
		if (n > 0) drain_replies(&readfds);
	}

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
			printf("%s is alive", sockaddr_str(&hosts[idx]->addr));
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
				       sockaddr_str(&hosts[idx]->addr),
				       hosts[idx]->sent, hosts[idx]->sent);
			}
			else {
				printf("%s is unreachable\n", sockaddr_str(&hosts[idx]->addr));
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
	int argi, sendidx, pending, minresponses = 1, tries = 3, timeout = 5;
	int need_v4 = 0, need_v6 = 0;
	int i;
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
			timeout = atoi(delim+1);
		}
		else if (strncmp(argv[argi], "--responses=", 12) == 0) {
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
			fprintf(stderr, "  Optional second column on each line: per-host probe-reply deadline (ms).\n");
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

	/* Smoke mode is driven by smoke_main_loop() further down; the
	 * legacy retry/pending loop is not entered. Default the per-host
	 * probe spacing to (timeout / samples_count) seconds so the cycle
	 * naturally fits within the configured timeout budget. */
	if (samples_count > 0) {
		if (per_host_interval_ms < 0) {
			per_host_interval_ms = (timeout * 1000) / samples_count;
			if (per_host_interval_ms <= 0) per_host_interval_ms = 1;
		}
	}

	if (srcip != NULL) {
		/* Setup the source address (v4 only -- legacy --source). */
		src_addr.sin_family = AF_INET;
		src_addr.sin_addr.s_addr = inet_addr(srcip);
		src_addr.sin_port = htons(0);
	}

	load_ips(argc, argv, stdin);

	/* Decide which sockets we actually need based on the host list. */
	for (i = 0; i < hostcount; i++) {
		if (hosts[i]->family == AF_INET6) need_v6 = 1;
		else                              need_v4 = 1;
	}
	if (!need_v4 && !need_v6) {
		errprintf("No hosts to ping\n");
		return 2;
	}

	if (need_v4) {
		pingsocket_v4 = open_icmp_socket(AF_INET, &is_dgram_v4, &sockerr);
		if (pingsocket_v4 == -1) {
			errprintf("Cannot open IPv4 ICMP socket: %s\n", strerror(sockerr));
			if (sockerr == EPERM || sockerr == EACCES) {
				errprintf("Either run as a user whose GID is in net.ipv4.ping_group_range,\n");
				errprintf("or install the binary suid-root / with cap_net_raw.\n");
			}
			return 3;
		}
		if (srcip != NULL && bind(pingsocket_v4, (struct sockaddr *)&src_addr, sizeof(src_addr)) == -1) {
			binderr = errno;
			errprintf("Cannot bind to source address %s: %s\nUsing default address\n",
			          srcip, strerror(binderr));
		}
		fcntl(pingsocket_v4, F_SETFL, O_NONBLOCK);
	}

	if (need_v6) {
		pingsocket_v6 = open_icmp_socket(AF_INET6, &is_dgram_v6, &sockerr);
		if (pingsocket_v6 == -1) {
			errprintf("Cannot open IPv6 ICMP socket: %s\n", strerror(sockerr));
			return 3;
		}
		fcntl(pingsocket_v6, F_SETFL, O_NONBLOCK);
	}

	if (samples_count > 0) {
		/* Smoke mode: every probe is a scheduled event on a shared
		 * min-heap. Termination is structural (heap empty + drain). */
		int rc = smoke_main_loop(timeout);
		if (pingsocket_v4 != -1) close(pingsocket_v4);
		if (pingsocket_v6 != -1) close(pingsocket_v6);
		if (rc == 0) show_results();
		return rc;
	}

	pending = count_pending(minresponses);

	while (tries) {
		int sendnow = SENDLIMIT;
		time_t cutoff = getcurrenttime(NULL) + timeout + 1;
		sendidx = 0;

		/* Change this on each iteration, so we don't mix packets from each round of pings */
		myicmpid = ((getpid()+tries) & 0x7FFF);

		/* Do one loop over the hosts we havent had responses from yet.
		 * Legacy mode is v4-only; v6 hosts were filtered out at load. */
		while (pending > 0) {
			fd_set readfds, writefds;
			struct timeval selecttmo;
			int n;

			FD_ZERO(&readfds);
			FD_ZERO(&writefds);
			FD_SET(pingsocket_v4, &readfds);

			if (sendnow && (sendidx < hostcount)) FD_SET(pingsocket_v4, &writefds);

			selecttmo.tv_sec = 0;
			selecttmo.tv_usec = 100000;
			n = select(pingsocket_v4+1, &readfds, &writefds, NULL, &selecttmo);

			if (n < 0) {
				if (errno == EINTR) continue;
				errprintf("select failed: %s\n", strerror(errno));
				return 4;
			}
			else if (n == 0) {
				/* Time out */
				sendnow = SENDLIMIT;
			}
			else {
				if (sendnow && FD_ISSET(pingsocket_v4, &writefds)) {
					/* OK to send */
					sendidx = send_ping(pingsocket_v4, sendidx, minresponses);
					sendnow--;

					/* Adjust the cutoff time, so we wait TIMEOUT seconds for a response */
					cutoff = getcurrenttime(NULL) + timeout + 1;
				}

				if (FD_ISSET(pingsocket_v4, &readfds)) {
					/* Grab the replies */
					int count = get_response(pingsocket_v4, AF_INET, is_dgram_v4);
					pending -= count;
					sendnow += count; if (sendnow > SENDLIMIT) sendnow = SENDLIMIT;
				}
			}

			/* See if we have hit the timeout */
			if ((getcurrenttime(NULL) >= cutoff) && (sendidx >= hostcount)) {
				pending = 0;
			}
		}

		tries--;
		pending = count_pending(minresponses);
		if (pending == 0) {
			/* Have got responses for all hosts - we're done */
			tries = 0;
		}
	}

	if (pingsocket_v4 != -1) close(pingsocket_v4);
	if (pingsocket_v6 != -1) close(pingsocket_v6);

	show_results();

	return 0;
}

