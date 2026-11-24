/* The tables gen-trampolines.py writes into trampolines.c, for ffi.c. */
#ifndef CF_LIBFFI_WASI_TRAMPOLINES_H
#define CF_LIBFFI_WASI_TRAMPOLINES_H
#include <stdint.h>

/* A call through `fn` with the arguments' values in a[] (one 8-byte slot
   each, holding the Wasm value), storing the result (if any) at ret. */
typedef struct {
  const char *sig;
  void (*call)(void (*fn)(void), uint64_t *a, void *ret);
} ffi_wasi_call;

/* A closure entry point's slot: the closure it runs, or NULL when free. */
typedef struct {
  void *closure;
} ffi_wasi_slot;

typedef struct {
  const char *sig;
  ffi_wasi_slot *slots;
  void (*const *entries)(void);
} ffi_wasi_closure_sig;

extern const ffi_wasi_call ffi_wasi_calls[];
extern const unsigned ffi_wasi_ncalls;
extern const ffi_wasi_closure_sig ffi_wasi_closure_sigs[];
extern const unsigned ffi_wasi_nclosure_sigs;
extern const unsigned ffi_wasi_closure_slots;

/* In ffi.c: runs slot's closure with the arguments in a[], its result (if
   any) left in *ret. */
void ffi_wasi_dispatch(ffi_wasi_slot *slot, uint64_t *a, uint64_t *ret);
#endif
