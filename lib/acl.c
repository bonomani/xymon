/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* Unified, capability-based, transport-aware, IPv4/IPv6 access control.      */
/* See acl.h for the model. This module is intentionally self-contained (only */
/* standard/socket headers) so it can be unit-tested in isolation and so the  */
/* legacy ipaccess.c can be retired once the ~25 oksender() call sites are    */
/* migrated onto acl_check().                                                 */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*----------------------------------------------------------------------------*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "acl.h"

enum acl_srctype { ACL_SRC_CIDR, ACL_SRC_LOCAL, ACL_SRC_CERTANY, ACL_SRC_CERTID };

struct acl_rule_s {
	enum acl_srctype    srctype;
	int                 family;     /* AF_INET / AF_INET6 (ACL_SRC_CIDR) */
	unsigned char       addr[16];   /* network bytes (ACL_SRC_CIDR) */
	int                 prefix;     /* prefix length in bits (ACL_SRC_CIDR) */
	char               *certid;     /* ACL_SRC_CERTID */
	enum acl_transport  transport;
	unsigned int        caps;
	int                 force;      /* operator acknowledged a broad admin grant */
	acl_rule_t         *next;
};

/* A rule grants admin to a "broad" source if it confers admin on more than a
 * small, intentional set: any verified cert (cert:*), or a CIDR holding more
 * than 256 addresses (v4 shorter than /24, v6 shorter than /120). `local` and a
 * named cert:<id> are never broad. acl_audit_admin() flags these unless the rule
 * carries the `force` acknowledgement. */
#define ACL_BROAD_V4_PREFIX 24
#define ACL_BROAD_V6_PREFIX 120

/* Compare the first `bits` bits of two byte arrays. */
static int prefix_match(const unsigned char *a, const unsigned char *b, int bits)
{
	int full = bits / 8, rem = bits % 8;

	if (full && (memcmp(a, b, full) != 0)) return 0;
	if (rem) {
		unsigned char mask = (unsigned char)(0xFF << (8 - rem));
		if ((a[full] & mask) != (b[full] & mask)) return 0;
	}
	return 1;
}

static int is_loopback(const acl_request_t *req)
{
	if (req->family == AF_INET)  return req->addr[0] == 127;	/* 127.0.0.0/8 */
	if (req->family == AF_INET6) {					/* ::1 */
		int i;
		for (i = 0; i < 15; i++) if (req->addr[i]) return 0;
		return req->addr[15] == 1;
	}
	return 0;
}

static int src_match(const acl_rule_t *r, const acl_request_t *req)
{
	switch (r->srctype) {
	  case ACL_SRC_LOCAL:   return is_loopback(req);
	  case ACL_SRC_CERTANY: return req->cert_verified;
	  case ACL_SRC_CERTID:  return req->cert_verified && req->cert_id && r->certid &&
				       (strcmp(req->cert_id, r->certid) == 0);
	  case ACL_SRC_CIDR:    return (r->family == req->family) &&
				       prefix_match(r->addr, req->addr, r->prefix);
	}
	return 0;
}

int acl_check(const acl_rule_t *rules, const acl_request_t *req, unsigned int needcap)
{
	const acl_rule_t *r;

	for (r = rules; r; r = r->next) {
		if ((r->transport == ACL_TR_PLAIN) && req->encrypted) continue;
		if ((r->transport == ACL_TR_TLS) && !req->encrypted) continue;
		if (!src_match(r, req)) continue;
		return (r->caps & needcap) ? 1 : 0;	/* first match is authoritative */
	}
	return 0;	/* default deny */
}

acl_rule_t *acl_append(acl_rule_t *list, acl_rule_t *rule)
{
	acl_rule_t *p;

	if (!rule) return list;
	rule->next = NULL;
	if (!list) return rule;
	for (p = list; p->next; p = p->next) ;
	p->next = rule;
	return list;
}

void acl_free(acl_rule_t *rules)
{
	while (rules) {
		acl_rule_t *n = rules->next;
		free(rules->certid);
		free(rules);
		rules = n;
	}
}

/* ---------------------------------------------------------------- parsing -- */

static int parse_caps(char *tok, unsigned int *out)
{
	unsigned int caps = 0;
	char *save = NULL, *c = strtok_r(tok, ",", &save);

	if (!c) return -1;
	while (c) {
		if      (strcmp(c, "status") == 0) caps |= ACL_CAP_STATUS;
		else if (strcmp(c, "www")    == 0) caps |= ACL_CAP_WWW;
		else if (strcmp(c, "maint")  == 0) caps |= ACL_CAP_MAINT;
		else if (strcmp(c, "admin")  == 0) caps |= ACL_CAP_ADMIN;
		else if (strcmp(c, "all")    == 0) caps |= ACL_CAP_ALL;
		else return -1;
		c = strtok_r(NULL, ",", &save);
	}
	*out = caps;
	return 0;
}

/* Parse a CIDR prefix length: the whole string must be a decimal in [0,max].
 * atoi() would silently turn "/junk" into /0 (match-everything) and "/24junk"
 * into /24 -- unacceptable in an access-control file, so demand a clean parse. */
static int parse_prefix(const char *s, int max, int *out)
{
	char *end;
	long v;

	if (!*s) return -1;
	errno = 0;
	v = strtol(s, &end, 10);
	if ((*end != '\0') || errno || (v < 0) || (v > max)) return -1;
	*out = (int)v;
	return 0;
}

static int parse_source(char *tok, acl_rule_t *r, char *errbuf, size_t errsz)
{
	char *slash;

	if (strcmp(tok, "local") == 0) { r->srctype = ACL_SRC_LOCAL; return 0; }

	if (strncmp(tok, "cert:", 5) == 0) {
		char *id = tok + 5;
		if (strcmp(id, "*") == 0) { r->srctype = ACL_SRC_CERTANY; return 0; }
		if (!*id) { snprintf(errbuf, errsz, "empty cert identity"); return -1; }
		r->srctype = ACL_SRC_CERTID;
		r->certid = strdup(id);
		return 0;
	}

	/* CIDR (v4 or v6); a bare address is a single host. */
	r->srctype = ACL_SRC_CIDR;
	slash = strchr(tok, '/');
	if (slash) *slash = '\0';
	if (inet_pton(AF_INET, tok, r->addr) == 1) {
		r->family = AF_INET; r->prefix = 32;
		if (slash && parse_prefix(slash + 1, 32, &r->prefix) != 0) { snprintf(errbuf, errsz, "bad IPv4 prefix '%s' (want 0-32)", slash + 1); return -1; }
	}
	else if (inet_pton(AF_INET6, tok, r->addr) == 1) {
		r->family = AF_INET6; r->prefix = 128;
		if (slash && parse_prefix(slash + 1, 128, &r->prefix) != 0) { snprintf(errbuf, errsz, "bad IPv6 prefix '%s' (want 0-128)", slash + 1); return -1; }
	}
	else { snprintf(errbuf, errsz, "bad source address '%s'", tok); return -1; }
	return 0;
}

acl_rule_t *acl_parse_line(const char *line, char *errbuf, size_t errsz)
{
	char buf[512];
	char *save = NULL, *src, *tr, *caps, *tok;
	acl_rule_t *r;
	const char *p = line;

	if (errsz) errbuf[0] = '\0';

	while ((*p == ' ') || (*p == '\t') || (*p == '\r') || (*p == '\n')) p++;
	if ((*p == '\0') || (*p == '#')) return NULL;	/* blank/comment: no rule, no error */

	if (strlen(p) >= sizeof(buf)) { snprintf(errbuf, errsz, "line too long"); return NULL; }
	strcpy(buf, p);

	/* Strip a trailing inline comment ('#' to end of line); the documented
	 * examples use them. A leading '#' was already handled as a comment above. */
	{ char *hash = strchr(buf, '#'); if (hash) *hash = '\0'; }

	src  = strtok_r(buf,  " \t\r\n", &save);
	tr   = strtok_r(NULL, " \t\r\n", &save);
	caps = strtok_r(NULL, " \t\r\n", &save);
	if (!src || !tr || !caps) { snprintf(errbuf, errsz, "expected: SOURCE TRANSPORT CAPS [force]"); return NULL; }

	r = (acl_rule_t *)calloc(1, sizeof(*r));
	if (!r) { snprintf(errbuf, errsz, "out of memory"); return NULL; }

	if (parse_source(src, r, errbuf, errsz) != 0) { acl_free(r); return NULL; }

	if      (strcmp(tr, "any")   == 0) r->transport = ACL_TR_ANY;
	else if (strcmp(tr, "plain") == 0) r->transport = ACL_TR_PLAIN;
	else if (strcmp(tr, "tls")   == 0) r->transport = ACL_TR_TLS;
	else { snprintf(errbuf, errsz, "bad transport '%s' (want any|plain|tls)", tr); acl_free(r); return NULL; }

	if (parse_caps(caps, &r->caps) != 0) { snprintf(errbuf, errsz, "bad capability list '%s'", caps); acl_free(r); return NULL; }

	/* Optional trailing "force": acknowledge an intentionally broad admin grant
	 * (see acl_audit_admin). Any other trailing token is an error. */
	tok = strtok_r(NULL, " \t\r\n", &save);
	if (tok) {
		if (strcmp(tok, "force") == 0) r->force = 1;
		else { snprintf(errbuf, errsz, "unexpected token '%s' (only 'force' may follow CAPS)", tok); acl_free(r); return NULL; }
	}

	return r;
}

/* Is this rule's source a "broad" admin grantee? (cert:* or a wide CIDR.) */
static int src_is_broad(const acl_rule_t *r)
{
	if (r->srctype == ACL_SRC_CERTANY) return 1;
	if (r->srctype == ACL_SRC_CIDR) {
		if (r->family == AF_INET)  return r->prefix < ACL_BROAD_V4_PREFIX;
		if (r->family == AF_INET6) return r->prefix < ACL_BROAD_V6_PREFIX;
	}
	return 0;	/* local, cert:<id>, narrow CIDR */
}

int acl_audit_admin(const acl_rule_t *rules, char *errbuf, size_t errsz)
{
	const acl_rule_t *r;
	int offenders = 0;

	if (errsz) errbuf[0] = '\0';
	for (r = rules; r; r = r->next) {
		if (!(r->caps & ACL_CAP_ADMIN)) continue;	/* doesn't grant admin */
		if (r->force) continue;				/* operator acknowledged */
		if (!src_is_broad(r)) continue;			/* narrow source: fine */

		if (offenders == 0) {	/* describe the first offender */
			if (r->srctype == ACL_SRC_CERTANY)
				snprintf(errbuf, errsz, "rule grants admin to 'cert:*' (any verified cert)");
			else
				snprintf(errbuf, errsz, "rule grants admin to a CIDR wider than /%d (v4) or /%d (v6)",
					 ACL_BROAD_V4_PREFIX, ACL_BROAD_V6_PREFIX);
		}
		offenders++;
	}
	return offenders;
}
