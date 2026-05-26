/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* Native TLS support for the Xymon wire protocol -- client side.             */
/*                                                                            */
/* This is the OpenSSL-backed implementation behind xymon_tls.h. It is        */
/* intentionally minimal: one process-global SSL_CTX, mTLS required,          */
/* TLS 1.3 only, server cert verified against XYMON_TLS_CA, hostname checked  */
/* via X509_VERIFY_PARAM_set1_host.                                           */
/*                                                                            */
/* Threading: Xymon client tools are single-threaded; the SSL_CTX is created  */
/* lazily on first use and lives until process exit (intentional leak --      */
/* OpenSSL's own atexit handlers tear down library state).                    */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*----------------------------------------------------------------------------*/

#include "config.h"

#ifdef HAVE_XYMON_TLS

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#ifndef LIBRESSL_VERSION_NUMBER
/* OpenSSL keeps the SSL_R_* reason codes in <openssl/sslerr.h>; LibreSSL has
 * no such header (and no SSL_R_UNEXPECTED_EOF_WHILE_READING). ssl.h above
 * defines LIBRESSL_VERSION_NUMBER on LibreSSL, so this include is OpenSSL-only. */
#include <openssl/sslerr.h>
#endif
#include <openssl/x509v3.h>

#include "libxymon.h"
#include "xymon_tls.h"

struct xymon_tls_s {
	SSL *ssl;
};

/* Process-global, lazily initialised. NULL until first successful init. */
static SSL_CTX *client_ctx = NULL;

/* Client verification policy, from XYMON_TLS_VERIFY:
 *   full (default) - verify the server cert chain AND its hostname/IP
 *   peer           - verify the chain only; skip the name check (cert
 *                    pinning: trust a specific self-signed cert directly)
 *   none           - no verification at all (encryption only; MITM-able)
 */
enum tls_verify_mode { TLS_VERIFY_FULL, TLS_VERIFY_PEER, TLS_VERIFY_NONE };
static enum tls_verify_mode client_verify = TLS_VERIFY_FULL;

/* Log the head of the OpenSSL error queue with a context prefix. */
static void log_ssl_err(const char *where)
{
	unsigned long e = ERR_get_error();
	char buf[256];

	if (e == 0) {
		errprintf("xymon_tls: %s: (no OpenSSL error queued)\n", where);
		return;
	}
	ERR_error_string_n(e, buf, sizeof(buf));
	errprintf("xymon_tls: %s: %s\n", where, buf);

	/* Drain the rest of the queue to avoid bleed into the next call. */
	while ((e = ERR_get_error()) != 0) {
		ERR_error_string_n(e, buf, sizeof(buf));
		errprintf("xymon_tls:   ... %s\n", buf);
	}
}

int xymon_tls_client_init(void)
{
	const char *ca_file, *cert_file, *key_file, *vmode;
	SSL_CTX *ctx;

	if (client_ctx) return 0;

	/* getenv (not xgetenv): these are optional now, and xgetenv would log a
	 * spurious "Cannot find value" for any that are unset. */
	ca_file   = getenv("XYMON_TLS_CA");
	cert_file = getenv("XYMON_TLS_CERT");
	key_file  = getenv("XYMON_TLS_KEY");
	vmode     = getenv("XYMON_TLS_VERIFY");

	client_verify = TLS_VERIFY_FULL;
	if (vmode && *vmode) {
		if      (strcmp(vmode, "full") == 0) client_verify = TLS_VERIFY_FULL;
		else if (strcmp(vmode, "peer") == 0) client_verify = TLS_VERIFY_PEER;
		else if (strcmp(vmode, "none") == 0) client_verify = TLS_VERIFY_NONE;
		else {
			errprintf("xymon_tls: unknown XYMON_TLS_VERIFY='%s' (use full|peer|none)\n", vmode);
			return -1;
		}
	}

	/* Bring up the library. OPENSSL_init_ssl is a no-op on second call. */
	OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS
			 | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);

	ctx = SSL_CTX_new(TLS_client_method());
	if (!ctx) { log_ssl_err("SSL_CTX_new"); return -1; }

	/* TLS 1.3 only for the prototype. Avoids cipher-policy debates and gets
	 * us forward secrecy + modern AEAD by default. */
	if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION)) {
		log_ssl_err("SSL_CTX_set_min_proto_version(1.3)");
		SSL_CTX_free(ctx); return -1;
	}
	if (!SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
		log_ssl_err("SSL_CTX_set_max_proto_version(1.3)");
		SSL_CTX_free(ctx); return -1;
	}

	/* Server-cert verification. In 'none' mode we skip it entirely
	 * (encryption only); otherwise the chain is checked against XYMON_TLS_CA
	 * -- which for cert pinning is simply the server's own self-signed cert. */
	if (client_verify == TLS_VERIFY_NONE) {
		SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
		errprintf("xymon_tls: WARNING: XYMON_TLS_VERIFY=none -- server certificate "
			  "NOT verified (encryption only, vulnerable to MITM)\n");
	}
	else {
		if (!ca_file || !*ca_file) {
			errprintf("xymon_tls: XYMON_TLS_CA is required unless XYMON_TLS_VERIFY=none\n");
			SSL_CTX_free(ctx); return -1;
		}
		if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
			errprintf("xymon_tls: cannot load CA/trust file '%s'\n", ca_file);
			log_ssl_err("SSL_CTX_load_verify_locations");
			SSL_CTX_free(ctx); return -1;
		}
		SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
	}

	/* Client cert + key are optional (only needed when the server requires
	 * mTLS). If one is given, both must be. */
	if ((cert_file && *cert_file) || (key_file && *key_file)) {
		if (!cert_file || !*cert_file || !key_file || !*key_file) {
			errprintf("xymon_tls: XYMON_TLS_CERT and XYMON_TLS_KEY must be set together\n");
			SSL_CTX_free(ctx); return -1;
		}
		if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
			errprintf("xymon_tls: cannot load client cert '%s'\n", cert_file);
			log_ssl_err("SSL_CTX_use_certificate_chain_file");
			SSL_CTX_free(ctx); return -1;
		}
		if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
			errprintf("xymon_tls: cannot load client key '%s'\n", key_file);
			log_ssl_err("SSL_CTX_use_PrivateKey_file");
			SSL_CTX_free(ctx); return -1;
		}
		if (SSL_CTX_check_private_key(ctx) != 1) {
			errprintf("xymon_tls: client cert and key do not match\n");
			log_ssl_err("SSL_CTX_check_private_key");
			SSL_CTX_free(ctx); return -1;
		}
	}

	client_ctx = ctx;
	return 0;
}

/* True if `name` is a numeric IPv4/IPv6 literal rather than a DNS hostname. */
static int is_ip_literal(const char *name)
{
	unsigned char buf[sizeof(struct in6_addr)];
	if (inet_pton(AF_INET,  name, buf) == 1) return 1;
	if (inet_pton(AF_INET6, name, buf) == 1) return 1;
	return 0;
}

xymon_tls_t *xymon_tls_client_handshake(int sockfd, const char *sni_hostname)
{
	xymon_tls_t *t;
	SSL *ssl;
	X509_VERIFY_PARAM *vp;
	int rc;
	int is_ip;

	if (!sni_hostname || !*sni_hostname) {
		errprintf("xymon_tls: handshake called without SNI hostname\n");
		return NULL;
	}
	if (xymon_tls_client_init() != 0) return NULL;

	ssl = SSL_new(client_ctx);
	if (!ssl) { log_ssl_err("SSL_new"); return NULL; }

	if (SSL_set_fd(ssl, sockfd) != 1) {
		log_ssl_err("SSL_set_fd");
		SSL_free(ssl); return NULL;
	}

	is_ip = is_ip_literal(sni_hostname);

	/* SNI -- some server-side TLS terminators key on this. RFC 6066 forbids
	 * IP literals in SNI, so only send it for real hostnames. */
	if (!is_ip) {
		if (SSL_set_tlsext_host_name(ssl, sni_hostname) != 1) {
			log_ssl_err("SSL_set_tlsext_host_name");
			SSL_free(ssl); return NULL;
		}
	}

	/* Certificate identity (hostname/IP) check -- only in 'full' mode. In
	 * 'peer' mode the cert is pinned, so its name is irrelevant; in 'none'
	 * mode the cert isn't verified at all. IP literals must be matched
	 * against iPAddress SANs via set1_ip; set1_host would treat them as DNS
	 * names and never match an IP SAN. */
	if (client_verify == TLS_VERIFY_FULL) {
		vp = SSL_get0_param(ssl);
		if (is_ip) {
			if (X509_VERIFY_PARAM_set1_ip_asc(vp, sni_hostname) != 1) {
				log_ssl_err("X509_VERIFY_PARAM_set1_ip_asc");
				SSL_free(ssl); return NULL;
			}
		}
		else {
			X509_VERIFY_PARAM_set_hostflags(vp, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
			if (X509_VERIFY_PARAM_set1_host(vp, sni_hostname, 0) != 1) {
				log_ssl_err("X509_VERIFY_PARAM_set1_host");
				SSL_free(ssl); return NULL;
			}
		}
	}

	rc = SSL_connect(ssl);
	if (rc != 1) {
		int e = SSL_get_error(ssl, rc);
		errprintf("xymon_tls: SSL_connect to '%s' failed (ssl-err=%d)\n",
			  sni_hostname, e);
		log_ssl_err("SSL_connect");
		SSL_free(ssl); return NULL;
	}

	t = (xymon_tls_t *)calloc(1, sizeof(*t));
	if (!t) {
		errprintf("xymon_tls: out of memory\n");
		SSL_free(ssl); return NULL;
	}
	t->ssl = ssl;
	return t;
}

ssize_t xymon_tls_read(xymon_tls_t *t, void *buf, size_t len)
{
	int n;
	if (!t || !t->ssl) { errno = EINVAL; return -1; }
	ERR_clear_error();
	n = SSL_read(t->ssl, buf, (int)len);
	if (n > 0) return n;
	switch (SSL_get_error(t->ssl, n)) {
	  case SSL_ERROR_ZERO_RETURN:
		return 0;   /* peer sent close_notify -- clean end of stream */
	  case SSL_ERROR_WANT_READ:
	  case SSL_ERROR_WANT_WRITE:
		/* Non-blocking socket: caller should retry. Signal via the
		 * standard errno=EAGAIN convention so existing read-loops that
		 * already check for it (e.g. xymond) just work. */
		errno = EAGAIN;
		return -1;
	  case SSL_ERROR_SYSCALL:
		/* errno==0 means the peer closed the TCP connection without a
		 * TLS close_notify. Xymon's plaintext path treats a bare TCP FIN
		 * as a clean end-of-stream (recv()==0), so mirror that here. */
		if (errno == 0) return 0;
		return -1;
	  case SSL_ERROR_SSL:
		/* OpenSSL 3.0+ reports a close without close_notify as a distinct
		 * "unexpected eof while reading" SSL error rather than SYSCALL.
		 * Treat it as EOF too, for parity with the plaintext path. The
		 * reason code only exists on 3.0+; on 1.1.1 / LibreSSL this path
		 * isn't reached (they surface it as SSL_ERROR_SYSCALL, handled
		 * above), and the macro is undefined, so guard its use. */
#ifdef SSL_R_UNEXPECTED_EOF_WHILE_READING
		if (ERR_GET_REASON(ERR_peek_error()) == SSL_R_UNEXPECTED_EOF_WHILE_READING) {
			ERR_clear_error();
			return 0;
		}
#endif
		log_ssl_err("SSL_read");
		errno = EIO;
		return -1;
	  default:
		log_ssl_err("SSL_read");
		errno = EIO;
		return -1;
	}
}

ssize_t xymon_tls_write(xymon_tls_t *t, const void *buf, size_t len)
{
	int n;
	if (!t || !t->ssl) { errno = EINVAL; return -1; }
	n = SSL_write(t->ssl, buf, (int)len);
	if (n > 0) return n;
	switch (SSL_get_error(t->ssl, n)) {
	  case SSL_ERROR_WANT_READ:
	  case SSL_ERROR_WANT_WRITE:
		errno = EAGAIN;
		return -1;
	  case SSL_ERROR_SYSCALL:
		return -1;
	  default:
		log_ssl_err("SSL_write");
		errno = EIO;
		return -1;
	}
}

void xymon_tls_shutdown_write(xymon_tls_t *t)
{
	if (!t || !t->ssl) return;
	/* The first SSL_shutdown() sends our close_notify -- the TLS analogue of
	 * shutdown(fd, SHUT_WR). It tells the peer "no more request data", which
	 * lets a half-duplex server (xymond) treat it as end-of-message. We do
	 * not wait for the peer's close_notify; the response read that follows
	 * picks that up, and the final xymon_tls_close() completes the teardown. */
	(void)SSL_shutdown(t->ssl);
}

void xymon_tls_close(xymon_tls_t *t)
{
	if (!t) return;
	if (t->ssl) {
		/* Best-effort: don't loop on WANT_READ/WRITE -- if the peer is
		 * gone, the second call just returns. */
		(void)SSL_shutdown(t->ssl);
		SSL_free(t->ssl);
	}
	free(t);
}


/* ---- Server side ------------------------------------------------------- */

struct xymon_tls_server_ctx_s {
	SSL_CTX *ctx;
};

xymon_tls_server_ctx_t *xymon_tls_server_ctx_new(const char *cert_file,
						 const char *key_file,
						 const char *ca_file)
{
	xymon_tls_server_ctx_t *s;
	SSL_CTX *ctx;

	if (!cert_file || !key_file) {
		errprintf("xymon_tls: server ctx needs at least a cert and key path\n");
		return NULL;
	}

	OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS
			 | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);

	ctx = SSL_CTX_new(TLS_server_method());
	if (!ctx) { log_ssl_err("SSL_CTX_new(server)"); return NULL; }

	if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) ||
	    !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
		log_ssl_err("SSL_CTX_set_*_proto_version(1.3)");
		SSL_CTX_free(ctx); return NULL;
	}

	if (SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
		errprintf("xymon_tls: cannot load server cert '%s'\n", cert_file);
		log_ssl_err("SSL_CTX_use_certificate_chain_file");
		SSL_CTX_free(ctx); return NULL;
	}
	if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
		errprintf("xymon_tls: cannot load server key '%s'\n", key_file);
		log_ssl_err("SSL_CTX_use_PrivateKey_file");
		SSL_CTX_free(ctx); return NULL;
	}
	if (SSL_CTX_check_private_key(ctx) != 1) {
		errprintf("xymon_tls: server cert and key do not match\n");
		log_ssl_err("SSL_CTX_check_private_key");
		SSL_CTX_free(ctx); return NULL;
	}

	/* Client-cert policy. With a CA/trust file we require and verify a client
	 * cert (mTLS) -- the trust file may be a real CA or a single pinned
	 * self-signed client cert. Without one we accept any client (encryption
	 * only, no client authentication). */
	if (ca_file && *ca_file) {
		if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
			errprintf("xymon_tls: cannot load client CA/trust file '%s'\n", ca_file);
			log_ssl_err("SSL_CTX_load_verify_locations(server)");
			SSL_CTX_free(ctx); return NULL;
		}
		SSL_CTX_set_verify(ctx,
			SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);

		/* Make CA names available so clients know which CA to chain to. */
		{
			STACK_OF(X509_NAME) *ca_names = SSL_load_client_CA_file(ca_file);
			if (ca_names) SSL_CTX_set_client_CA_list(ctx, ca_names);
		}
	}
	else {
		SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
		errprintf("xymon_tls: WARNING: no client CA configured (--tls-ca) -- client "
			  "certificates NOT required or verified (encryption only)\n");
	}

	s = (xymon_tls_server_ctx_t *)calloc(1, sizeof(*s));
	if (!s) { SSL_CTX_free(ctx); return NULL; }
	s->ctx = ctx;
	return s;
}

void xymon_tls_server_ctx_free(xymon_tls_server_ctx_t *sctx)
{
	if (!sctx) return;
	if (sctx->ctx) SSL_CTX_free(sctx->ctx);
	free(sctx);
}

/* Extract the peer cert's CN (best-effort; returns NULL if no cert or no CN). */
static char *peer_cn(SSL *ssl)
{
	X509 *cert;
	X509_NAME *subj;
	int idx;
	X509_NAME_ENTRY *e;
	ASN1_STRING *asn;
	char buf[256];
	int n;
	char *out;

	cert = SSL_get_peer_certificate(ssl);
	if (!cert) return NULL;
	subj = X509_get_subject_name(cert);
	if (!subj) { X509_free(cert); return NULL; }
	idx = X509_NAME_get_index_by_NID(subj, NID_commonName, -1);
	if (idx < 0) { X509_free(cert); return NULL; }
	e = X509_NAME_get_entry(subj, idx);
	if (!e) { X509_free(cert); return NULL; }
	asn = X509_NAME_ENTRY_get_data(e);
	if (!asn) { X509_free(cert); return NULL; }
	n = ASN1_STRING_length(asn);
	if (n <= 0 || n >= (int)sizeof(buf)) { X509_free(cert); return NULL; }
	memcpy(buf, ASN1_STRING_get0_data(asn), n);
	buf[n] = '\0';
	out = strdup(buf);
	X509_free(cert);
	return out;
}

xymon_tls_t *xymon_tls_server_handshake(int sockfd,
					xymon_tls_server_ctx_t *sctx,
					char **peer_cn_out)
{
	xymon_tls_t *t;
	SSL *ssl;
	int rc;

	if (!sctx || !sctx->ctx) { errprintf("xymon_tls: null server ctx\n"); return NULL; }

	ssl = SSL_new(sctx->ctx);
	if (!ssl) { log_ssl_err("SSL_new(server)"); return NULL; }
	if (SSL_set_fd(ssl, sockfd) != 1) {
		log_ssl_err("SSL_set_fd(server)");
		SSL_free(ssl); return NULL;
	}

	rc = SSL_accept(ssl);
	if (rc != 1) {
		int e = SSL_get_error(ssl, rc);
		errprintf("xymon_tls: SSL_accept failed (ssl-err=%d)\n", e);
		log_ssl_err("SSL_accept");
		SSL_free(ssl); return NULL;
	}

	if (peer_cn_out) *peer_cn_out = peer_cn(ssl);

	t = (xymon_tls_t *)calloc(1, sizeof(*t));
	if (!t) {
		errprintf("xymon_tls: out of memory\n");
		if (peer_cn_out && *peer_cn_out) { free(*peer_cn_out); *peer_cn_out = NULL; }
		SSL_free(ssl); return NULL;
	}
	t->ssl = ssl;
	return t;
}

#endif /* HAVE_XYMON_TLS */
