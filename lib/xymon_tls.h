/*----------------------------------------------------------------------------*/
/* Xymon monitor library.                                                     */
/*                                                                            */
/* Native TLS support for the Xymon wire protocol.                            */
/*                                                                            */
/* This is the client-side surface used by lib/sendmsg.c. The server-side    */
/* helpers (xymon_tls_server_*) land with the xymond changes.                 */
/*                                                                            */
/* All declarations are compiled out when HAVE_XYMON_TLS is not defined, so   */
/* including this header on a non-TLS build is a no-op.                       */
/*                                                                            */
/* This program is released under the GNU General Public License (GPL),       */
/* version 2. See the file "COPYING" for details.                             */
/*----------------------------------------------------------------------------*/

#ifndef __XYMON_TLS_H_
#define __XYMON_TLS_H_

#ifdef HAVE_XYMON_TLS

#include <sys/types.h>

/* Opaque per-connection TLS state. */
typedef struct xymon_tls_s xymon_tls_t;

/*
 * Lazy one-time process init for the client SSL_CTX. Reads:
 *   XYMON_TLS_CA   - PEM bundle to verify the server cert     (required)
 *   XYMON_TLS_CERT - PEM client certificate (mTLS)            (required)
 *   XYMON_TLS_KEY  - PEM client private key  (mTLS)            (required)
 * Returns 0 on success, -1 on error (an explanatory message is logged via
 * errprintf). Safe to call multiple times; only the first call does work.
 */
int xymon_tls_client_init(void);

/*
 * Perform a TLS client handshake on an already-connected, BLOCKING socket.
 * `sni_hostname` is the peer name to verify against the server cert (the
 * xymons:// host, or XYMON_TLS_SNI when set); must not be NULL. A DNS name
 * is sent as SNI and matched against dNSName SANs; an IP literal is matched
 * against iPAddress SANs (and not sent as SNI, per RFC 6066).
 *
 * Returns NULL on any failure (handshake error, cert verification failure,
 * hostname mismatch, etc.). Caller retains ownership of sockfd.
 */
xymon_tls_t *xymon_tls_client_handshake(int sockfd, const char *sni_hostname);

/*
 * Blocking read/write through TLS. Semantics mirror read(2)/write(2):
 *   read:  returns >0 bytes read, 0 on clean shutdown, -1 on error.
 *   write: returns >0 bytes written, -1 on error. Short writes are possible.
 */
ssize_t xymon_tls_read (xymon_tls_t *t, void *buf, size_t len);
ssize_t xymon_tls_write(xymon_tls_t *t, const void *buf, size_t len);

/*
 * Send a TLS close_notify on the write direction to delimit the end of a
 * request -- the TLS analogue of shutdown(fd, SHUT_WR). The caller may (and
 * for a request/response exchange should) keep reading the peer's response
 * afterwards. Best-effort; does not wait for the peer's close_notify.
 */
void xymon_tls_shutdown_write(xymon_tls_t *t);

/*
 * Best-effort TLS shutdown + free of the per-connection state. Does NOT
 * close the underlying socket fd; that remains the caller's responsibility.
 */
void xymon_tls_close(xymon_tls_t *t);


/* ---- Server side (xymond) ---------------------------------------------- */

/*
 * Opaque per-process server SSL context. Built once at startup from the
 * --tls-cert / --tls-key / --tls-ca file paths and reused for every accepted
 * connection.
 */
typedef struct xymon_tls_server_ctx_s xymon_tls_server_ctx_t;

/*
 * Build a server SSL_CTX from PEM file paths. mTLS is required:
 * SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, peer chain checked
 * against ca_file. TLS 1.3 only. Returns NULL on any failure (logged).
 */
xymon_tls_server_ctx_t *xymon_tls_server_ctx_new(const char *cert_file,
						 const char *key_file,
						 const char *ca_file);

void xymon_tls_server_ctx_free(xymon_tls_server_ctx_t *sctx);

/*
 * Server-side handshake on an already-accepted, BLOCKING socket. Returns
 * NULL on handshake or verification failure. On success the returned handle
 * can be used with the same xymon_tls_read / xymon_tls_write / xymon_tls_close
 * functions as the client side.
 *
 * If `peer_cn_out` is non-NULL, on success it is filled with a newly-malloc'd
 * copy of the peer cert's CN (caller frees). Useful for audit logging.
 */
xymon_tls_t *xymon_tls_server_handshake(int sockfd,
					xymon_tls_server_ctx_t *sctx,
					char **peer_cn_out);

#endif /* HAVE_XYMON_TLS */

#endif /* __XYMON_TLS_H_ */
