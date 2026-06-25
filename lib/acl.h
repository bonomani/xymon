/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* Unified, capability-based, transport-aware, IPv4/IPv6 access control.      */
/* Replaces the four parallel IPv4-only sender lists (status/www/maint/admin) */
/* and the cert-trust special case with one ordered rule table.              */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*----------------------------------------------------------------------------*/

#ifndef __ACL_H__
#define __ACL_H__

#include <stddef.h>

/* Capability bits a request may require / a rule may grant. The four bits are
 * the former --status-senders / --www-senders / --maint-senders /
 * --admin-senders privilege classes, now data in a rule rather than separate
 * lists. By default ACL_CAP_ADMIN is not granted to a cert:* rule -- "a cert is
 * a reporter, not an administrator" -- but an operator may grant it explicitly
 * by appending `force` to the rule (see acl_audit_admin). */
#define ACL_CAP_STATUS  0x01u
#define ACL_CAP_WWW     0x02u
#define ACL_CAP_MAINT   0x04u
#define ACL_CAP_ADMIN   0x08u
#define ACL_CAP_ALL     (ACL_CAP_STATUS | ACL_CAP_WWW | ACL_CAP_MAINT | ACL_CAP_ADMIN)

/* Transport an incoming connection used / a rule requires. "plain" and "tls"
 * are exact; "any" matches either. Use "tls" to require encryption, "any" for
 * source-based grants that don't care about transport. */
enum acl_transport { ACL_TR_ANY = 0, ACL_TR_PLAIN, ACL_TR_TLS };

typedef struct acl_rule_s acl_rule_t;

/* The context a single message/connection presents to the matcher. The caller
 * normalizes an IPv4-mapped-IPv6 peer to AF_INET (so v4 rules match it); a
 * native IPv6 peer uses AF_INET6 with all 16 address bytes. */
typedef struct {
	int            family;        /* AF_INET or AF_INET6 */
	unsigned char  addr[16];      /* network-order address bytes (4 used for v4) */
	int            encrypted;     /* connection used TLS */
	int            cert_verified; /* a verified client cert was presented */
	const char    *cert_id;       /* cert CN/identity, or NULL */
} acl_request_t;

/* Parse one rule line "SOURCE TRANSPORT CAPS", e.g.:
 *     10.0.0.0/8     any   status,www,maint
 *     cert:*         tls   status,www
 *     local          any   all
 *     0.0.0.0/0      tls   all              force   # acknowledged broad admin
 * SOURCE is a v4/v6 CIDR (bare address => host), "local" (loopback), "cert:*"
 * (any verified cert) or "cert:<id>" (a named cert identity). A trailing
 * "force" acknowledges an intentionally broad admin grant (see acl_audit_admin).
 *   - returns a malloc'd rule on success;
 *   - returns NULL with errbuf empty for a blank or "#"-comment line;
 *   - returns NULL with errbuf filled for a malformed line.
 */
acl_rule_t *acl_parse_line(const char *line, char *errbuf, size_t errsz);

/* Safety guard against granting admin too broadly. Returns the number of rules
 * that confer admin (via `admin` or `all`) on a broad source -- `cert:*`, or a
 * CIDR wider than /24 (v4) / /120 (v6) -- without a `force` acknowledgement.
 * `local` and `cert:<id>` are never broad. First offender described in errbuf;
 * 0 = clean. */
int acl_audit_admin(const acl_rule_t *rules, char *errbuf, size_t errsz);

/* Append rule to the end of list (preserving order); returns the head. */
acl_rule_t *acl_append(acl_rule_t *list, acl_rule_t *rule);

/* First-match-wins: the first rule whose SOURCE and TRANSPORT match the request
 * is authoritative -- the request is allowed iff that rule grants needcap. If
 * no rule matches, the request is denied. Order rules specific-before-general. */
int acl_check(const acl_rule_t *rules, const acl_request_t *req, unsigned int needcap);

void acl_free(acl_rule_t *rules);

#endif
