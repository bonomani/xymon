/* SPDX-License-Identifier: GPL-2.0-or-later                                  */
/*
 * tests/xymonnet/xymonping-harness.c
 *
 * Drives xymonping's reply parser, get_response(), with crafted packets, and
 * its address loader, load_ips(), with crafted input: it #includes
 * xymonnet/xymonping.c (main renamed) and hands get_response() one end of a
 * socketpair as the ICMP socket, so each rule is checked without root, a
 * network or timing. Run by tests/xymonnet/xymonping-unit.sh.
 *
 * Pins, for a raw socket and for an unprivileged SOCK_DGRAM one:
 *   - the IP header is skipped when present -- always on a raw socket, and on
 *     a SOCK_DGRAM socket only when the packet starts with version 4 (macOS
 *     keeps it, Linux does not);
 *   - a raw socket takes only replies carrying our icmp_id; a SOCK_DGRAM one,
 *     whose icmp_id the kernel sets, only those whose payload carries it;
 *   - a reply too short to hold the payload, a packet that is not an echo
 *     reply, a sequence number outside the host list, and a payload naming
 *     another host are ignored;
 *   - a reply counts only for a try still waiting (PS_SENT): a duplicate, a
 *     try already timed out, and an unknown try are ignored, and so is a reply
 *     whose round-trip time exceeds the timeout, however soon it is read;
 *   - a host leaves hosts_pending when it reaches --responses replies;
 * and for load_ips(): at most 65535 hosts, empty input loads none, and a line
 * that is not an address is dropped; and for the loop without --samples, as
 * seen in the packets it sends: each host is tried --retries+1 times in order,
 * a retry only after the timeout, no two pings closer than --max-pps allows;
 * and with --samples: each reply's rtt is kept in its slot, and the loop sends
 * every host its N pings in order, --per-host-interval apart, still never two
 * closer than --max-pps allows, then expires each one unanswered and counts it
 * lost.
 */

/* What xymonping sends is recorded instead of leaving the box, with the
 * time sendto() was really called; the sockets it opens are socketpair
 * ends. sendto() and socket() are redirected before xymonping.c is
 * included. stall_first makes the first send take 500 ms, so the loop
 * falls behind; refuse_seq makes every send to that icmp_seq fail with
 * EACCES; fail_dgram refuses the unprivileged SOCK_DGRAM socket; echo_fd
 * answers every ping at once, as a host that is up would. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>

#define MAXSENT 256
static unsigned char sent_pkt[MAXSENT][64];
static int64_t sent_call_ns[MAXSENT];
static int nsent = 0;
static int stall_first = 0;
static int refuse_seq = 0;
static int fail_dgram = 0;
static int echo_fd = -1;	/* when set, every ping is answered at once through this socket */
static int (*queue_probe)(void) = 0;	/* when set, sampled on every send */
static int queue_max = 0;		/* the largest value queue_probe returned */

static int64_t harness_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static ssize_t harness_sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l)
{
	const unsigned char *p = (const unsigned char *)b;

	(void)s; (void)f; (void)a; (void)l;
	if (stall_first) { stall_first = 0; usleep(500000); }
	if (queue_probe && (queue_probe() > queue_max)) queue_max = queue_probe();
	if (nsent < MAXSENT) {
		memcpy(sent_pkt[nsent], b, (n < 64) ? n : 64);
		sent_call_ns[nsent] = harness_now_ns();
	}
	nsent++;
	if (refuse_seq && (((p[6] << 8) | p[7]) == refuse_seq)) { errno = EACCES; return -1; }
	if (echo_fd >= 0) {
		unsigned char r[64];
		memcpy(r, b, (n < 64) ? n : 64);
		r[0] = 0;	/* ICMP_ECHOREPLY, the same payload */
		(void)send(echo_fd, r, (n < 64) ? n : 64, 0);
	}
	return (ssize_t)n;
}
#define sendto harness_sendto

static int harness_socket(int domain, int type, int proto)
{
	int p[2];

	(void)domain; (void)proto;
	if (fail_dgram && (type == SOCK_DGRAM)) { errno = EACCES; return -1; }
	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, p) != 0) return -1;
	return p[0];
}
#define socket harness_socket

#define main xymonping_main
#include "xymonping.c"
#undef main

/* How many sends are queued, for queue_probe. */
static int sends_queued(void) { return evheap_size(&sends); }

static int fails = 0;
static int sv[2];

#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); fails++; } } while (0)
/* A timing check that says, when it fails, what it measured. */
#define CHECK_GAP(gap, min, what) do { if ((gap) < (min)) { printf("FAIL %s: %lld ns, at least %lld expected\n", what, (long long)(gap), (long long)(min)); fails++; } } while (0)

/* Load a newline-separated address list through load_ips(). */
static void load(const char *list)
{
	char *argv[] = { "xymonping", NULL };
	FILE *fd = tmpfile();

	fputs(list, fd);
	rewind(fd);
	hosthead = NULL; hosts = NULL; hostcount = 0;
	load_ips(1, argv, fd);
	fclose(fd);
}
/* Load n distinct addresses through load_ips(). */
static void load_many(int n)
{
	char *argv[] = { "xymonping", NULL };
	FILE *fd = tmpfile();
	int i;

	for (i = 0; i < n; i++) fprintf(fd, "10.%d.%d.1\n", i / 256, i % 256);
	rewind(fd);
	hosthead = NULL; hosts = NULL; hostcount = 0;
	load_ips(1, argv, fd);
	fclose(fd);
}


/* What one crafted reply looks like; defaults are a good reply for host 0,
 * try 0, sent just now. */
typedef struct pkt_t {
	int iphdr, type, hdr_id, seq, payload_id, probe_idx, payload_icmpid, cut;
	int64_t age_ns;		/* how long ago the payload says it was sent */
} pkt_t;

static pkt_t good(void)
{
	pkt_t p;
	p.iphdr = 0; p.type = ICMP_ECHOREPLY; p.hdr_id = myicmpid; p.seq = 1;
	p.payload_id = 0; p.probe_idx = 0; p.payload_icmpid = myicmpid; p.cut = 0;
	p.age_ns = 0;
	return p;
}

/* Queue the packet, let get_response() read it, and return how many replies
 * host 0 has been credited. */
static int feed(pkt_t p)
{
	unsigned char buf[256];
	int off = (p.iphdr ? 20 : 0);
	struct icmp *icmp = (struct icmp *)(buf + off);
	struct pingdata_t pd;
	int64_t sent;

	memset(buf, 0, sizeof(buf));
	memset(&pd, 0, sizeof(pd));
	if (p.iphdr) buf[0] = 0x45;	/* IPv4, 20-byte header */
	icmp->icmp_type = p.type;
	icmp->icmp_id   = htons(p.hdr_id);
	icmp->icmp_seq  = htons(p.seq);
	pd.id        = p.payload_id;
	pd.probe_idx = p.probe_idx;
	pd.icmpid    = p.payload_icmpid;
	sent = mono_ns() - p.age_ns;
	pd.timesent.tv_sec  = sent / 1000000000LL;
	pd.timesent.tv_nsec = sent % 1000000000LL;
	memcpy(buf + off + sizeof(struct icmp), &pd, sizeof(pd));
	if (send(sv[1], buf, off + sizeof(struct icmp) + sizeof(struct pingdata_t) - p.cut, 0) < 0) {
		perror("send"); exit(2);
	}
	(void)get_response();
	return hosts[0]->received;
}

/* Host 0 with one try sent and waiting, nothing received. */
static void waiting(void)
{
	hosts[0]->received = 0;
	hosts[0]->probe_state[0] = PS_SENT;
	hosts_pending = hostcount;
}

/* Decode recorded send i: the host its sequence names, its try, and when
 * sendto() was called for it. */
static void sent(int i, int *host, int *probe, int64_t *when)
{
	struct icmp *icmp = (struct icmp *)sent_pkt[i];
	struct pingdata_t pd;

	memcpy(&pd, sent_pkt[i] + sizeof(struct icmp), sizeof(pd));
	*host  = ntohs(icmp->icmp_seq) - 1;
	*probe = pd.probe_idx;
	*when  = sent_call_ns[i];
}

/* Run main() in a child with argv and stdin from /dev/null; the child
 * reports, after main() returns, which kind of socket it used and whether
 * every ping it sent carried our id. Returns the child's exit status, its
 * stdout in out. Done in fresh children: nextip() keeps state in statics. */
static int run_main(char **argv, char *out, size_t outlen)
{
	int p[2], status, argc = 0;
	pid_t pid;
	ssize_t n, got = 0;

	while (argv[argc]) argc++;
	if (pipe(p) != 0) return -1;
	pid = fork();
	if (pid == 0) {
		int devnull = open("/dev/null", O_RDONLY), i, ours = 1;

		dup2(devnull, 0);
		dup2(p[1], 1);
		close(p[0]);
		status = xymonping_main(argc, argv);
		for (i = 0; (i < nsent) && (i < MAXSENT); i++) {
			struct icmp *icmp = (struct icmp *)sent_pkt[i];
			struct pingdata_t pd;
			memcpy(&pd, sent_pkt[i] + sizeof(struct icmp), sizeof(pd));
			if (pd.icmpid != ntohs(icmp->icmp_id)) ours = 0;
		}
		printf("is_dgram=%d sent=%d payload_carries_id=%d\n", is_dgram, nsent, ours);
		fflush(stdout);
		_exit(status);
	}
	close(p[1]);
	while ((got < (ssize_t)outlen - 1) && ((n = read(p[0], out + got, outlen - 1 - got)) > 0)) got += n;
	out[got] = '\0';
	close(p[0]);
	waitpid(pid, &status, 0);
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(void)
{
	pkt_t p;
	int i;

	char out[1024];
	char a0[] = "xymonping", a1[] = "--timeout=1", a2[] = "--retries=0", a3[] = "127.0.0.1";
	char *argv1[] = { a0, a1, a2, a3, NULL };
	pingevent_t ev;

	/* main(): the unprivileged socket first, the raw one when it is
	 * refused, and every ping carrying our id in its payload. */
	fail_dgram = 0;
	CHECK(run_main(argv1, out, sizeof(out)) == 0, "main() runs with the unprivileged socket");
	CHECK(strstr(out, "is_dgram=1 sent=1 payload_carries_id=1") != NULL,
	      "the unprivileged socket is used when offered, and the ping carries our id");
	fail_dgram = 1;
	CHECK(run_main(argv1, out, sizeof(out)) == 0, "main() runs when the unprivileged socket is refused");
	CHECK(strstr(out, "is_dgram=0 sent=1 payload_carries_id=1") != NULL,
	      "the raw socket is used when the unprivileged one is refused");
	fail_dgram = 0;

	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0) { perror("socketpair"); return 2; }
	fcntl(sv[0], F_SETFL, O_NONBLOCK);
	pingsocket = sv[0];
	myicmpid = 1234;
	probe_timeout_ns = 1000000000LL;
	minresponses = 1;

	load("127.0.0.1\nnot-an-address\n127.0.0.2\n");
	CHECK(hostcount == 2, "two hosts loaded, the line that is not an address dropped");
	for (i = 0; i < hostcount; i++) {
		hosts[i]->probe_state = (uint8_t *)calloc(2, sizeof(uint8_t));
		hosts[i]->probe_slots = 2;
	}

	/* Raw socket: header always there, our icmp_id required. */
	is_dgram = 0;
	waiting(); p = good(); p.iphdr = 1;
	CHECK(feed(p) == 1, "raw: our reply counts");
	CHECK(hosts[0]->probe_state[0] == PS_REPLIED, "raw: the try is marked replied");
	CHECK(hosts_pending == 1, "raw: the host leaves hosts_pending");
	waiting(); p = good(); p.iphdr = 1; p.hdr_id = 999;
	CHECK(feed(p) == 0, "raw: another icmp_id is ignored");

	/* SOCK_DGRAM: the kernel's icmp_id, our id in the payload. */
	is_dgram = 1;
	waiting(); p = good(); p.hdr_id = 77;
	CHECK(feed(p) == 1, "dgram without IP header: our reply counts");
	waiting(); p = good(); p.hdr_id = 77; p.iphdr = 1;
	CHECK(feed(p) == 1, "dgram with IP header (macOS): our reply counts");
	waiting(); p = good(); p.payload_icmpid = 999;
	CHECK(feed(p) == 0, "dgram: another run's payload is ignored");

	/* Whatever the socket. */
	waiting(); p = good(); p.cut = 4;
	CHECK(feed(p) == 0, "a reply too short for the payload is ignored");
	waiting(); p = good(); p.type = ICMP_ECHO;
	CHECK(feed(p) == 0, "a packet that is not an echo reply is ignored");
	waiting(); p = good(); p.seq = 0;
	CHECK(feed(p) == 0, "sequence 0, before the host list, is ignored");
	waiting(); p = good(); p.seq = 3;
	CHECK(feed(p) == 0 && hosts[1]->received == 0, "a sequence past the host list is ignored");
	waiting(); p = good(); p.payload_id = 1;
	CHECK(feed(p) == 0 && hosts[1]->received == 0, "a payload naming another host is ignored");

	/* Per-try state and the timeout. */
	waiting(); p = good();
	CHECK(feed(p) == 1 && feed(p) == 1, "a duplicate reply is not counted twice");
	waiting(); hosts[0]->probe_state[0] = PS_TIMEOUT; p = good();
	CHECK(feed(p) == 0, "a reply for a try already timed out is ignored");
	waiting(); p = good(); p.probe_idx = 2;
	CHECK(feed(p) == 0, "a reply for an unknown try is ignored");
	waiting(); p = good(); p.age_ns = 2000000000LL;
	CHECK(feed(p) == 0, "a reply later than the timeout is ignored, though read before the try expired");
	CHECK(hosts[0]->probe_state[0] == PS_SENT, "a late reply leaves the try for its expiry to settle");

	/* --samples: the reply's rtt is kept in the slot of its ping. */
	hosts[0]->samples_usec = (unsigned long *)calloc(2, sizeof(unsigned long));
	inflight = 1;
	waiting(); p = good(); p.probe_idx = 1; hosts[0]->probe_state[1] = PS_SENT; p.age_ns = 3000000LL;
	CHECK(feed(p) == 1, "--samples: the reply counts");
	CHECK((hosts[0]->samples_usec[1] >= 3000) && (hosts[0]->samples_usec[1] < 1000000), "--samples: its rtt is kept in its ping's slot");
	CHECK(inflight == 0, "--samples: the ping is no longer in flight");
	xfree(hosts[0]->samples_usec);

	/* --responses: the host stays pending until it has enough replies. */
	minresponses = 2;
	waiting(); hosts[0]->probe_state[1] = PS_SENT; p = good();
	CHECK(feed(p) == 1 && hosts_pending == 2, "one of two replies leaves the host pending");
	p.probe_idx = 1;
	CHECK(feed(p) == 2 && hosts_pending == 1, "the second reply settles the host");
	minresponses = 1;

	/* load_ips(): empty input, and the host cap. */
	load("");
	CHECK(hostcount == 0, "empty input loads no host");
	load_many(65536);
	CHECK(hostcount == 65535, "at most 65535 hosts are loaded");


	/* The loop without --samples: three hosts nobody answers, two tries
	 * each, a 1 s timeout, at most 5 pings a second. The first send stalls
	 * for 500 ms, so the next two are overdue when it returns: they must
	 * still leave 200 ms apart. */
	load("127.0.0.1\n127.0.0.2\n127.0.0.3\n");
	nsent = 0;
	senddelay = 200000;
	stall_first = 1;
	CHECK(retry_main_loop(1, 2) == 0, "the loop runs to the end");
	CHECK(nsent == 6, "each of three hosts is tried twice");
	for (i = 0; (i < nsent) && (i < MAXSENT); i++) {
		int host, probe, j;
		int64_t when;

		sent(i, &host, &probe, &when);
		if (i > 0) {
			int h0, p0;
			int64_t w0;
			sent(i - 1, &h0, &p0, &w0);
			CHECK_GAP(when - w0, 195000000LL, "no two pings closer than --max-pps allows");
		}
		for (j = 0; j < i; j++) {
			int h0, p0;
			int64_t w0;
			sent(j, &h0, &p0, &w0);
			if ((h0 == host) && (probe == 1)) {
				CHECK(p0 == 0, "a host's first try goes before its retry");
				CHECK_GAP(when - w0, 995000000LL, "a retry waits for the timeout");
			}
		}
	}
	for (i = 0; i < hostcount; i++) CHECK(hosts[i]->received == 0, "a host nobody answers has no reply");
	CHECK(evheap_size(&sends) == 0 && evheap_size(&expiries) == 0, "the loop leaves no event behind");
	{
		int h0, h1, h2, pr;
		int64_t w;
		sent(0, &h0, &pr, &w); sent(1, &h1, &pr, &w); sent(2, &h2, &pr, &w);
		CHECK(h0 == 0 && h1 == 1 && h2 == 2, "the first pings go out in host order");
	}

	/* A send that fails outright is retried like a lost ping: after the
	 * timeout, --retries times. */
	load("127.0.0.1\n");
	nsent = 0;
	senddelay = 10000;
	refuse_seq = 1;
	CHECK(retry_main_loop(1, 3) == 0 && nsent == 3, "a refused host is tried three times");
	refuse_seq = 0;
	if (nsent == 3) {
		int h, pr;
		int64_t w0, w1, w2;
		sent(0, &h, &pr, &w0); sent(1, &h, &pr, &w1); sent(2, &h, &pr, &w2);
		CHECK_GAP(w1 - w0, 995000000LL, "the first retry of a refused send waits for the timeout");
		CHECK_GAP(w2 - w1, 995000000LL, "the second retry of a refused send waits for the timeout");
	}

	/* next_event(): an expiry due before the next --max-pps slot is not
	 * held behind a send waiting for that slot. */
	ev.host_idx = 0; ev.probe_idx = 0; ev.retries = 0; ev.tries_left = 0;
	next_send_ns = mono_ns() + 400000000LL;
	ev.kind = EV_SEND;   ev.when_ns = mono_ns();             schedule(&sends, ev);
	ev.kind = EV_EXPIRE; ev.when_ns = mono_ns() + 50000000LL; schedule(&expiries, ev);
	{
		int64_t t0 = mono_ns();
		CHECK(next_event(&ev) == 1 && ev.kind == EV_EXPIRE && mono_ns() - t0 < 300000000LL,
		      "an expiry is not held behind a send waiting for its --max-pps slot");
		CHECK(next_event(&ev) == 1 && ev.kind == EV_SEND && mono_ns() >= next_send_ns,
		      "the send then waits for its slot");
		CHECK(next_event(&ev) == 0, "with both queues empty there is no next event");
	}

	/* Hosts that answer: each gets one ping, and the loop stops as soon as
	 * they all have, leaving no expiry behind. */
	load("127.0.0.1\n127.0.0.2\n");
	nsent = 0;
	senddelay = 10000;
	is_dgram = 1;
	echo_fd = sv[1];
	CHECK(retry_main_loop(5, 3) == 0, "the loop with answering hosts runs to the end");
	echo_fd = -1;
	CHECK(nsent == 2, "a host that answers is not pinged again");
	CHECK(hosts[0]->received == 1 && hosts[1]->received == 1, "each answer is counted");
	CHECK(evheap_size(&sends) == 0 && evheap_size(&expiries) == 0,
	      "the loop leaves no expiry behind when it stops early");

	/* The --samples loop: three hosts nobody answers, three pings each,
	 * 300 ms apart, at most 20 a second, a 1 s timeout. The first send
	 * stalls for 500 ms: the next ping to that host must still leave
	 * 300 ms after it, not at its place in the original schedule. */
	samples_count = 3;
	per_host_interval_ms = 300;
	load("127.0.0.1\n127.0.0.2\n127.0.0.3\n");
	nsent = 0;
	senddelay = 50000;
	inflight = 0;
	stall_first = 1;
	queue_probe = sends_queued;
	queue_max = 0;
	CHECK(smoke_main_loop(1) == 0, "--samples: the loop runs to the end");
	CHECK(nsent == 9, "--samples: three pings to each of three hosts");
	for (i = 0; (i < nsent) && (i < MAXSENT); i++) {
		int host, probe, j;
		int64_t when;

		sent(i, &host, &probe, &when);
		for (j = 0; j < i; j++) {
			int h0, p0;
			int64_t w0;
			sent(j, &h0, &p0, &w0);
			CHECK_GAP(when - w0, 45000000LL, "--samples: no two pings closer than --max-pps allows");
			if (h0 == host) {
				CHECK(p0 < probe, "--samples: a host's pings go in order");
				CHECK_GAP(when - w0, 295000000LL, "--samples: a host's pings are --per-host-interval apart");
			}
		}
	}
	CHECK(inflight == 0, "--samples: no ping is left in flight");
	queue_probe = 0;
	CHECK(queue_max <= hostcount, "--samples: only each host's next ping is queued, not all N");
	CHECK(hosts_pending >= 0, "--samples: the pending-host count stays consistent");
	CHECK(evheap_size(&sends) == 0 && evheap_size(&expiries) == 0, "--samples: the loop leaves no event behind");
	for (i = 0; i < hostcount; i++) {
		CHECK(hosts[i]->sent == 3 && hosts[i]->received == 0, "--samples: three pings sent, none answered");
		CHECK(hosts[i]->probe_state[0] == PS_TIMEOUT && hosts[i]->probe_state[2] == PS_TIMEOUT,
		      "--samples: each unanswered ping expires");
	}

	/* With no spacing at all, --max-pps still holds, also when the loop
	 * falls behind. */
	per_host_interval_ms = 0;
	load("127.0.0.1\n127.0.0.2\n");
	nsent = 0;
	senddelay = 100000;
	stall_first = 1;
	CHECK(smoke_main_loop(1) == 0 && nsent == 6, "--samples with no spacing: every ping is sent");
	for (i = 1; (i < nsent) && (i < MAXSENT); i++) {
		int h0, p0, h1, p1;
		int64_t w0, w1;
		sent(i - 1, &h0, &p0, &w0);
		sent(i, &h1, &p1, &w1);
		CHECK_GAP(w1 - w0, 95000000LL, "--samples with no spacing: no two pings closer than --max-pps allows");
	}
	samples_count = 0;
	return fails ? 1 : 0;
}
