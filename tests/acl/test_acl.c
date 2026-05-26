/* Standalone unit test for the unified capability ACL engine (lib/acl.c).
 * Self-contained -- no libxymon dependency. Build & run:
 *   gcc -Wall -Wextra -D_DEFAULT_SOURCE -Ilib tests/acl/test_acl.c lib/acl.c -o /tmp/test_acl && /tmp/test_acl
 */
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <arpa/inet.h>

#include "acl.h"

static int oks = 0, fails = 0;

static void check(const char *label, int got, int want)
{
	if (got == want) { oks++;  printf("  ok   - %s\n", label); }
	else             { fails++; printf("  FAIL - %s (got %d, want %d)\n", label, got, want); }
}

static acl_request_t req(const char *ip, int encrypted, int cert_verified, const char *cert_id)
{
	acl_request_t r;
	memset(&r, 0, sizeof(r));
	if      (inet_pton(AF_INET,  ip, r.addr) == 1) r.family = AF_INET;
	else if (inet_pton(AF_INET6, ip, r.addr) == 1) r.family = AF_INET6;
	r.encrypted = encrypted; r.cert_verified = cert_verified; r.cert_id = cert_id;
	return r;
}

static acl_rule_t *add(acl_rule_t *list, const char *line)
{
	char err[128];
	acl_rule_t *r = acl_parse_line(line, err, sizeof(err));
	if (!r && err[0]) { printf("  PARSE-FAIL '%s': %s\n", line, err); fails++; }
	return r ? acl_append(list, r) : list;
}

int main(void)
{
	acl_rule_t *acl = NULL, *acl2 = NULL;
	acl_request_t r;
	char err[128];
	acl_rule_t *bad;

	printf("== model: localhost-full, intranet-plaintext-ok, remote-must-TLS+cert ==\n");
	acl = add(acl, "# this is a comment - ignored");
	acl = add(acl, "local           any   all");
	acl = add(acl, "10.0.0.0/8      any   status,www,maint");
	acl = add(acl, "2001:db8::/32   any   status,www,maint");
	acl = add(acl, "cert:ops-admin  tls   all");          /* specific before general */
	acl = add(acl, "cert:*          tls   status,www");

	r = req("127.0.0.1", 0, 0, NULL);
	check("v4 loopback plaintext -> admin",      acl_check(acl, &r, ACL_CAP_ADMIN),  1);
	r = req("::1", 0, 0, NULL);
	check("v6 loopback (::1) plaintext -> admin", acl_check(acl, &r, ACL_CAP_ADMIN), 1);

	r = req("10.7.7.7", 0, 0, NULL);
	check("intranet v4 plaintext -> status",      acl_check(acl, &r, ACL_CAP_STATUS), 1);
	check("intranet v4 plaintext -> admin DENIED", acl_check(acl, &r, ACL_CAP_ADMIN), 0);
	r = req("2001:db8::99", 0, 0, NULL);
	check("intranet v6 plaintext -> www",         acl_check(acl, &r, ACL_CAP_WWW),    1);

	r = req("203.0.113.7", 0, 0, NULL);
	check("offnet plaintext, no cert -> DENIED",  acl_check(acl, &r, ACL_CAP_STATUS), 0);

	r = req("203.0.113.7", 1, 1, "some-host");
	check("offnet TLS+cert -> status",            acl_check(acl, &r, ACL_CAP_STATUS), 1);
	check("offnet TLS+cert -> admin DENIED",      acl_check(acl, &r, ACL_CAP_ADMIN),  0);

	r = req("203.0.113.7", 1, 1, "ops-admin");
	check("named cert over TLS -> admin",         acl_check(acl, &r, ACL_CAP_ADMIN),  1);

	r = req("203.0.113.7", 0, 1, "ops-admin");
	check("cert claim but NOT encrypted -> DENIED", acl_check(acl, &r, ACL_CAP_STATUS), 0);

	printf("== exact transport matching (plain != tls) ==\n");
	acl2 = add(acl2, "192.168.0.0/16  plain  status");
	acl2 = add(acl2, "192.168.0.0/16  tls    www");
	r = req("192.168.1.1", 0, 0, NULL);
	check("192.168/16 plaintext -> status",       acl_check(acl2, &r, ACL_CAP_STATUS), 1);
	check("192.168/16 plaintext -> www DENIED",   acl_check(acl2, &r, ACL_CAP_WWW),    0);
	r = req("192.168.1.1", 1, 0, NULL);
	check("192.168/16 TLS -> www",                acl_check(acl2, &r, ACL_CAP_WWW),    1);
	check("192.168/16 TLS -> status DENIED",      acl_check(acl2, &r, ACL_CAP_STATUS), 0);

	printf("== parser rejects malformed rules ==\n");
	bad = acl_parse_line("10.0.0.0/8 frobnicate status", err, sizeof(err));
	check("bad transport rejected", (bad == NULL) && (err[0] != '\0'), 1); if (bad) acl_free(bad);
	bad = acl_parse_line("not-an-ip any status", err, sizeof(err));
	check("bad source rejected",    (bad == NULL) && (err[0] != '\0'), 1); if (bad) acl_free(bad);
	bad = acl_parse_line("10.0.0.0/8 any boguscap", err, sizeof(err));
	check("bad capability rejected", (bad == NULL) && (err[0] != '\0'), 1); if (bad) acl_free(bad);
	bad = acl_parse_line("   # comment", err, sizeof(err));
	check("comment -> no rule, no error", (bad == NULL) && (err[0] == '\0'), 1); if (bad) acl_free(bad);
	bad = acl_parse_line("\n", err, sizeof(err));
	check("blank line -> no rule, no error", (bad == NULL) && (err[0] == '\0'), 1); if (bad) acl_free(bad);
	bad = acl_parse_line("   \t\r\n", err, sizeof(err));
	check("whitespace-only line -> no rule, no error", (bad == NULL) && (err[0] == '\0'), 1); if (bad) acl_free(bad);

	printf("== admin-breadth guard (acl_audit_admin) ==\n");
	{
		acl_rule_t *a; char e[128];
		/* broad: cert:* granted admin (via all) -> offender */
		a = NULL; a = add(a, "cert:*  tls  all");
		check("cert:* all -> flagged",        acl_audit_admin(a, e, sizeof(e)) > 0, 1); acl_free(a);
		/* broad: wide v4 CIDR with admin -> offender */
		a = NULL; a = add(a, "10.0.0.0/8  any  admin");
		check("10/8 admin -> flagged",        acl_audit_admin(a, e, sizeof(e)) > 0, 1); acl_free(a);
		/* broad but force-acknowledged -> ok */
		a = NULL; a = add(a, "cert:*  tls  all  force");
		check("cert:* all force -> ok",       acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		/* narrow sources granting admin -> ok */
		a = NULL; a = add(a, "local  any  all");
		check("local all -> ok",              acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		a = NULL; a = add(a, "cert:ops-admin  tls  all");
		check("cert:<id> all -> ok",          acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		a = NULL; a = add(a, "192.0.2.5/32  any  admin");
		check("host /32 admin -> ok",         acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		a = NULL; a = add(a, "192.0.2.0/24  any  admin");
		check("/24 admin -> ok (threshold)",  acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		/* broad source but NOT granting admin -> ok */
		a = NULL; a = add(a, "cert:*  tls  status,www");
		check("cert:* non-admin -> ok",       acl_audit_admin(a, e, sizeof(e)), 0); acl_free(a);
		/* wide v6 CIDR with admin -> offender */
		a = NULL; a = add(a, "2001:db8::/32  tls  all");
		check("v6 /32 admin -> flagged",      acl_audit_admin(a, e, sizeof(e)) > 0, 1); acl_free(a);
		/* unexpected trailing token rejected */
		a = acl_parse_line("local any all bogus", e, sizeof(e));
		check("bad trailing token rejected",  (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
	}

	printf("== inline comments accepted (documented examples) ==\n");
	{
		acl_rule_t *a; char e[128];
		acl_request_t rr;
		a = acl_parse_line("10.0.0.0/8  any  status  # intranet reporters", e, sizeof(e));
		check("rule with trailing inline comment parses", (a != NULL) && (e[0] == '\0'), 1);
		if (a) {
			rr = req("10.1.2.3", 0, 0, NULL);
			check("  ...and still matches/grants",  acl_check(a, &rr, ACL_CAP_STATUS), 1);
			acl_free(a);
		}
		a = acl_parse_line("0.0.0.0/0  tls  all  force  # acknowledged broad admin", e, sizeof(e));
		check("comment after 'force' parses",  (a != NULL) && (e[0] == '\0'), 1);
		check("  ...force still acknowledged",  (a != NULL) && (acl_audit_admin(a, e, sizeof(e)) == 0), 1);
		if (a) acl_free(a);
		a = acl_parse_line("local any all# no space before comment", e, sizeof(e));
		check("comment with no leading space parses", (a != NULL) && (e[0] == '\0'), 1); if (a) acl_free(a);
	}

	printf("== strict CIDR prefix parsing (no atoi widening) ==\n");
	{
		acl_rule_t *a; char e[128];
		a = acl_parse_line("10.0.0.0/junk  any  status", e, sizeof(e));
		check("/junk rejected (not silently /0)", (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("10.0.0.0/24junk  any  status", e, sizeof(e));
		check("/24junk rejected (no trailing garbage)", (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("10.0.0.0/  any  status", e, sizeof(e));
		check("empty prefix rejected", (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("10.0.0.0/33  any  status", e, sizeof(e));
		check("v4 /33 out of range rejected", (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("2001:db8::/129  tls  status", e, sizeof(e));
		check("v6 /129 out of range rejected", (a == NULL) && (e[0] != '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("10.0.0.0/0  any  status", e, sizeof(e));
		check("explicit /0 still accepted", (a != NULL) && (e[0] == '\0'), 1); if (a) acl_free(a);
		a = acl_parse_line("2001:db8::/32  tls  status", e, sizeof(e));
		check("valid v6 prefix accepted", (a != NULL) && (e[0] == '\0'), 1); if (a) acl_free(a);
	}

	acl_free(acl);
	acl_free(acl2);
	printf("---- %d passed, %d failed ----\n", oks, fails);
	return fails ? 1 : 0;
}
