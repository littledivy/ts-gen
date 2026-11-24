/* OpenSSL built with no-sock and no-dgram (WASI preview 1 has no socket()
   or connect()) leaves out these four, which cryptography's cffi bindings
   declare for pyOpenSSL. Force-included into the generated _openssl.c, they
   fail as OpenSSL does when out of memory or given a bad socket. */
#include <openssl/bio.h>
#include <openssl/ssl.h>

static inline BIO_ADDR *BIO_ADDR_new(void) { return NULL; }
static inline void BIO_ADDR_free(BIO_ADDR *a) { (void)a; }
static inline int DTLSv1_listen(SSL *s, BIO_ADDR *client) {
  (void)s, (void)client;
  return -1;
}
static inline int SSL_set_fd(SSL *s, int fd) {
  (void)s, (void)fd;
  return 0;
}
