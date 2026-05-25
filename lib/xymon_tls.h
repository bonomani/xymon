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
 * `sni_hostname` is the original hostname from the xymons:// URL (used for
 * SNI and cert hostname verification); must not be NULL.
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
 * Best-effort TLS shutdown + free of the per-connection state. Does NOT
 * close the underlying socket fd; that remains the caller's responsibility.
 */
void xymon_tls_close(xymon_tls_t *t);

#endif /* HAVE_XYMON_TLS */

#endif /* __XYMON_TLS_H_ */
