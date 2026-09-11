/*
 * FMMA - TLS setup, in one place.
 *
 * Both outbound connections (the market feed and the broker) need the
 * same thing: a real trust anchor and the right SNI name.  Getting this
 * wrong is quiet - the previous version passed an empty CA, which
 * disables the certificate check and leaves only host-name matching, so
 * it "worked" while protecting nothing.
 *
 * Two notes that cost real debugging time and are recorded here so they
 * are not rediscovered:
 *
 *  - mongoose must be built with -DMG_TLS=MG_TLS_OPENSSL.  With no
 *    -DMG_TLS at all it compiles with TLS disabled and every connection
 *    fails at the handshake, silently.
 *
 *  - mongoose's *built-in* TLS stack cannot complete a handshake with
 *    Coinbase: it rejects P-384 certificate intermediates outright
 *    ("reject secp386 for now"), and Coinbase is behind Cloudflare,
 *    which uses one.  Setting skip_verification does not help, because
 *    the chain-signature loop is not gated on it.
 */
#ifndef FMMA_TLS_H
#define FMMA_TLS_H

struct mg_connection;

/* Choose a CA bundle: the configured one, else the first of the usual
 * system locations that exists.  NULL if none was found. */
const char *fmma_tls_ca_file(void);

/* Override the autodetected bundle (from --ca). */
void fmma_tls_set_ca_file(const char *path);

/* Warn once at startup if there is no trust anchor to be had. */
void fmma_tls_check(void);

/* Begin the handshake on a freshly connected socket. */
void fmma_tls_start(struct mg_connection *c, const char *host);

#endif /* FMMA_TLS_H */
