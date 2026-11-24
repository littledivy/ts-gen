/* WASI has no dup(): cffi's FILE * arguments made from Python files fail
   with ENOTSUP. Force-included (-include) into _cffi_backend.c. */
#include <errno.h>
static inline int dup(int fd) {
  (void)fd;
  errno = ENOTSUP;
  return -1;
}
