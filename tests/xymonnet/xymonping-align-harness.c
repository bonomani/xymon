/* SPDX-License-Identifier: GPL-2.0-or-later                                  */
/*
 * tests/xymonnet/xymonping-align-harness.c
 *
 * Sends one ping with xymonping's send_ping() and reads one reply with its
 * get_response(), both from the real xymonnet/xymonping.c (#included, main
 * renamed), over a socketpair. Built by tests/xymonnet/xymonping-align.sh
 * with UBSan's alignment check made fatal, so a payload accessed through a
 * misaligned pointer -- it sits at offset sizeof(struct icmp) -- aborts the
 * run the way a strict-alignment CPU would.
 */

#define main xymonping_main
#include "xymonping.c"
#undef main

int main(void)
{
	int sv[2];
	unsigned char pkt[128];
	struct icmp *icmp = (struct icmp *)pkt;
	struct pingdata_t pd;
	struct hostdata_t host;
	hostdata_t *table[2] = { &host, NULL };

	if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0) { perror("socketpair"); return 2; }
	fcntl(sv[0], F_SETFL, O_NONBLOCK);
	memset(&host, 0, sizeof(host));
	hosts = table;
	hostcount = 1;
	myicmpid = 1234;

	/* Sending: the payload is written at its offset (sendto() on a
	 * socketpair then fails, which send_ping() reports and survives). */
	(void)send_ping(sv[0], 0, 1);

	/* Receiving: a raw-socket reply, IP header included. */
	memset(pkt, 0, sizeof(pkt));
	pkt[0] = 0x45;
	icmp = (struct icmp *)(pkt + 20);
	icmp->icmp_type = ICMP_ECHOREPLY;
	icmp->icmp_id   = htons(myicmpid);
	icmp->icmp_seq  = htons(1);
	memset(&pd, 0, sizeof(pd));
	getntimer(&pd.timesent);
	memcpy(pkt + 20 + sizeof(struct icmp), &pd, sizeof(pd));
	if (send(sv[1], pkt, 20 + sizeof(struct icmp) + sizeof(pd), 0) < 0) { perror("send"); return 2; }
	(void)get_response(sv[0]);
	if (host.received != 1) { printf("FAIL the reply was not counted\n"); return 1; }

	return 0;
}
