/* SPDX-License-Identifier: GPL-2.0-or-later                                  */
/*
 * tests/libxymon/get-root-harness.c
 *
 * Calls lib/suid.c's drop_root() then get_root() and checks the process is
 * still there with the privileges it should have: for a user who cannot
 * become root, get_root() returns with the effective uid unchanged instead
 * of aborting; for root it gives root back. Run by tests/libxymon/get-root.sh.
 */

#include <stdio.h>
#include <unistd.h>

#include "libxymon.h"

int main(void)
{
	uid_t uid = getuid();

	drop_root();
	get_root();
	if (geteuid() != uid) {
		printf("FAIL get_root() as uid %d left euid %d\n", (int)uid, (int)geteuid());
		return 1;
	}
	drop_root();
	if (geteuid() != uid) {
		printf("FAIL drop_root() as uid %d left euid %d\n", (int)uid, (int)geteuid());
		return 1;
	}
	return 0;
}
