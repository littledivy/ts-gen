// Pre-initialization entry for `wasmtime wizer`. It runs the normal
// `wizer_initialize` with free() wrapped to zero each block it releases, so
// memory freed during startup (source text, compiler temporaries, import
// scaffolding) lands in the snapshot as zeros instead of stale bytes.
#include <malloc.h>
#include <stddef.h>
#include <string.h>

void wizer_initialize(void);
void __real_free(void *);

static int zero_freed;

void __wrap_free(void *p) {
  if (p && zero_freed) memset(p, 0, malloc_usable_size(p));
  __real_free(p);
}

__attribute__((export_name("snapshot-initialize"))) void snapshot_initialize(void) {
  zero_freed = 1;
  wizer_initialize();
  zero_freed = 0;
}
