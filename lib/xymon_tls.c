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

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#include "libxymon.h"
#include "xymon_tls.h"

struct xymon_tls_s {
	SSL *ssl;
};

/* Process-global, lazily initialised. NULL until first successful init. */
static SSL_CTX *client_ctx = NULL;

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
	const char *ca_file, *cert_file, *key_file;
	SSL_CTX *ctx;

	if (client_ctx) return 0;

	ca_file   = xgetenv("XYMON_TLS_CA");
	cert_file = xgetenv("XYMON_TLS_CERT");
	key_file  = xgetenv("XYMON_TLS_KEY");

	if (!ca_file || !*ca_file) {
		errprintf("xymon_tls: XYMON_TLS_CA is required for xymons:// URLs\n");
		return -1;
	}
	if (!cert_file || !*cert_file || !key_file || !*key_file) {
		errprintf("xymon_tls: XYMON_TLS_CERT and XYMON_TLS_KEY are required (mTLS)\n");
		return -1;
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

	/* Verify the server's certificate chain against XYMON_TLS_CA. */
	if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) {
		errprintf("xymon_tls: cannot load CA bundle '%s'\n", ca_file);
		log_ssl_err("SSL_CTX_load_verify_locations");
		SSL_CTX_free(ctx); return -1;
	}
	SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);

	/* Our client cert + key (for mTLS). */
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

	client_ctx = ctx;
	return 0;
}

xymon_tls_t *xymon_tls_client_handshake(int sockfd, const char *sni_hostname)
{
	xymon_tls_t *t;
	SSL *ssl;
	X509_VERIFY_PARAM *vp;
	int rc;

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

	/* SNI -- some server-side TLS terminators key on this. */
	if (SSL_set_tlsext_host_name(ssl, sni_hostname) != 1) {
		log_ssl_err("SSL_set_tlsext_host_name");
		SSL_free(ssl); return NULL;
	}

	/* Hostname verification: cert's CN/SAN must match sni_hostname. */
	vp = SSL_get0_param(ssl);
	X509_VERIFY_PARAM_set_hostflags(vp, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
	if (X509_VERIFY_PARAM_set1_host(vp, sni_hostname, 0) != 1) {
		log_ssl_err("X509_VERIFY_PARAM_set1_host");
		SSL_free(ssl); return NULL;
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
	n = SSL_read(t->ssl, buf, (int)len);
	if (n > 0) return n;
	switch (SSL_get_error(t->ssl, n)) {
	  case SSL_ERROR_ZERO_RETURN: return 0;   /* clean shutdown */
	  case SSL_ERROR_SYSCALL:     return -1;
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
	log_ssl_err("SSL_write");
	errno = EIO;
	return -1;
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

#endif /* HAVE_XYMON_TLS */
