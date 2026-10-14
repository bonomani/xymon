/* SPDX-License-Identifier: GPL-2.0-or-later                                  */
/*
 * tests/xymonnet/xymonping-harness.c
 *
 * Drives xymonping's reply parser, get_response(), with crafted packets: it
 * #includes xymonnet/xymonping.c (main renamed) and hands get_response() one
 * end of a socketpair as the ICMP socket, so each rule is checked without
 * root, a network or timing. Run by tests/xymonnet/xymonping-unit.sh.
 *
 * Pins, for a raw socket and for an unprivileged SOCK_DGRAM one:
 *   - the IP header is skipped when present -- always on a raw socket, and on
 *     a SOCK_DGRAM socket only when the packet starts with version 4 (macOS
 *     keeps it, Linux does not);
 *   - a raw socket takes only replies carrying our icmp_id; a SOCK_DGRAM one,
 *     whose icmp_id the kernel sets, only those whose payload carries it;
 *   - main() takes the unprivileged socket when offered and falls back to the
 *     raw one when it is refused, and every ping it sends carries our id in
 *     its payload;
 *   - a SOCK_DGRAM reply too short to hold the payload, a packet that is not
 *     an echo reply, and a sequence number outside the host list are ignored.
 */

/* What xymonping sends is recorded instead of leaving the box, and the
 * sockets it opens are socketpair ends: sendto() and socket() are
 * redirected before xymonping.c is included. fail_dgram makes the
 * unprivileged SOCK_DGRAM socket fail, so the raw fallback is taken. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>

#define MAXSENT 64
static unsigned char sent_pkt[MAXSENT][64];
static int nsent = 0;
static int fail_dgram = 0;

static ssize_t harness_sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l)
{
	(void)s; (void)f; (void)a; (void)l;
	if (nsent < MAXSENT) memcpy(sent_pkt[nsent], b, (n < 64) ? n : 64);
	nsent++;
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

static int fails = 0;
static int sv[2];

#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); fails++; } } while (0)

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

/* Queue one ICMP packet on the socket get_response() reads. */
static void reply(int iphdr, int type, int hdr_id, int seq, int payload_id, int payload_icmpid, int cut)
{
	unsigned char buf[256];
	int off = (iphdr ? 20 : 0);
	struct icmp *icmp = (struct icmp *)(buf + off);
	struct pingdata_t pd;

	memset(buf, 0, sizeof(buf));
	memset(&pd, 0, sizeof(pd));
	if (iphdr) buf[0] = 0x45;	/* IPv4, 20-byte header */
	icmp->icmp_type = type;
	icmp->icmp_id   = htons(hdr_id);
	icmp->icmp_seq  = htons(seq);
	pd.id     = payload_id;
	pd.icmpid = payload_icmpid;
	getntimer(&pd.timesent);
	memcpy(buf + off + sizeof(struct icmp), &pd, sizeof(pd));
	if (send(sv[1], buf, off + sizeof(struct icmp) + sizeof(struct pingdata_t) - cut, 0) < 0) {
		perror("send"); exit(2);
	}
}

/* Feed one packet to host 0 and return how many replies it was credited. */
static int credited(int dgram, int iphdr, int type, int hdr_id, int seq, int payload_id, int payload_icmpid, int cut)
{
	is_dgram = dgram;
	hosts[0]->received = 0;
	reply(iphdr, type, hdr_id, seq, payload_id, payload_icmpid, cut);
	(void)get_response(sv[0]);
	return hosts[0]->received;
}

/* Run main() in a child with argv and stdin from /dev/null; the child
 * reports, after main() returns, which kind of socket it used and what it
 * sent. Returns the child's exit status, its stdout in out. */
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
	char out[1024];
	char a0[] = "xymonping", a1[] = "--timeout=1", a2[] = "--retries=0", a3[] = "127.0.0.1";
	char *argv1[] = { a0, a1, a2, a3, NULL };

	/* main(): the unprivileged socket first, the raw one when it is
	 * refused, and every ping carrying our id in its payload. Done first,
	 * in fresh children: nextip() keeps its state in statics. */
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
	myicmpid = 1234;
	load("127.0.0.1\n127.0.0.2\n");
	CHECK(hostcount == 2, "two hosts loaded");

	/* Raw socket: header always there, our icmp_id required. */
	CHECK(credited(0, 1, ICMP_ECHOREPLY, 1234, 1, 0, 1234, 0) == 1, "raw: our reply counts");
	CHECK(credited(0, 1, ICMP_ECHOREPLY, 999, 1, 0, 1234, 0) == 0, "raw: another icmp_id is ignored");

	/* SOCK_DGRAM: the kernel's icmp_id, our id in the payload. */
	CHECK(credited(1, 0, ICMP_ECHOREPLY, 77, 1, 0, 1234, 0) == 1, "dgram without IP header: our reply counts");
	CHECK(credited(1, 1, ICMP_ECHOREPLY, 77, 1, 0, 1234, 0) == 1, "dgram with IP header (macOS): our reply counts");
	CHECK(credited(1, 0, ICMP_ECHOREPLY, 77, 1, 0, 999, 0) == 0, "dgram: another run's payload is ignored");
	CHECK(credited(1, 0, ICMP_ECHOREPLY, 77, 1, 0, 1234, 4) == 0, "dgram: a reply too short for the payload is ignored");

	/* Whatever the socket. */
	CHECK(credited(1, 0, ICMP_ECHO, 77, 1, 0, 1234, 0) == 0, "a packet that is not an echo reply is ignored");
	CHECK(credited(1, 0, ICMP_ECHOREPLY, 77, 0, 0, 1234, 0) == 0, "sequence 0, before the host list, is ignored");
	CHECK(credited(0, 1, ICMP_ECHOREPLY, 1234, 3, 0, 1234, 0) == 0 && hosts[1]->received == 0,
	      "a sequence past the host list is ignored");

	return fails ? 1 : 0;
}
