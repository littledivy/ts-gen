// realloc releases memory itself, bypassing the zeroing free() wrapper in
// packages/snapshot.c: the old block when it moves one, and the tail when it
// shrinks one in place (as _PyBytes_Resize does after reading a source
// file). While pre-initializing, a growing realloc is a malloc, a copy and a
// wrapped free, and a shrinking one zeros the tail first, so both land in the
// snapshot as zeros.
#include <malloc.h>
#include <stdlib.h>
#include <string.h>

extern int cfworkers_snapshotting(void);
void *__real_realloc(void *, size_t);
void __wrap_free(void *);

void *__wrap_realloc(void *p, size_t n) {
  if (!p || !cfworkers_snapshotting()) return __real_realloc(p, n);
  if (!n) {
    __wrap_free(p);
    return NULL;
  }
  size_t old = malloc_usable_size(p);
  if (n <= old) {
    memset((char *)p + n, 0, old - n);
    return __real_realloc(p, n);
  }
  void *q = malloc(n);
  if (!q) return NULL;
  memcpy(q, p, old);
  __wrap_free(p);
  return q;
}
