/* See ffi.h: libffi for wasm32, its calls and closures over trampolines.c. */
#include <Python.h>
#include <stdlib.h>
#include <string.h>
#include <alloca.h>

#include "ffi.h"

#define T(name, sz, al, id) ffi_type name = {sz, al, id, NULL}
T(ffi_type_void, 1, 1, FFI_TYPE_VOID);
T(ffi_type_uint8, 1, 1, FFI_TYPE_UINT8);
T(ffi_type_sint8, 1, 1, FFI_TYPE_SINT8);
T(ffi_type_uint16, 2, 2, FFI_TYPE_UINT16);
T(ffi_type_sint16, 2, 2, FFI_TYPE_SINT16);
T(ffi_type_uint32, 4, 4, FFI_TYPE_UINT32);
T(ffi_type_sint32, 4, 4, FFI_TYPE_SINT32);
T(ffi_type_uint64, 8, 8, FFI_TYPE_UINT64);
T(ffi_type_sint64, 8, 8, FFI_TYPE_SINT64);
T(ffi_type_float, 4, 4, FFI_TYPE_FLOAT);
T(ffi_type_double, 8, 8, FFI_TYPE_DOUBLE);
T(ffi_type_longdouble, 16, 16, FFI_TYPE_LONGDOUBLE);
T(ffi_type_pointer, 4, 4, FFI_TYPE_POINTER);
static ffi_type *complex_float_elems[] = {&ffi_type_float, NULL};
static ffi_type *complex_double_elems[] = {&ffi_type_double, NULL};
static ffi_type *complex_longdouble_elems[] = {&ffi_type_longdouble, NULL};
ffi_type ffi_type_complex_float = {8, 4, FFI_TYPE_COMPLEX, complex_float_elems};
ffi_type ffi_type_complex_double = {16, 8, FFI_TYPE_COMPLEX, complex_double_elems};
ffi_type ffi_type_complex_longdouble = {32, 16, FFI_TYPE_COMPLEX, complex_longdouble_elems};

/* libffi's initialize_aggregate: a struct's size and alignment from its
   elements, for structs given with size 0. */
static ffi_status layout(ffi_type *t) {
  if (t->type != FFI_TYPE_STRUCT || t->size != 0) return FFI_OK;
  if (t->elements == NULL || t->elements[0] == NULL) return FFI_BAD_TYPEDEF;
  size_t size = 0;
  unsigned short align = 1;
  for (ffi_type **e = t->elements; *e; e++) {
    if (layout(*e) != FFI_OK) return FFI_BAD_TYPEDEF;
    size = (size + (*e)->alignment - 1) & ~(size_t)((*e)->alignment - 1);
    size += (*e)->size;
    if ((*e)->alignment > align) align = (*e)->alignment;
  }
  t->size = (size + align - 1) & ~(size_t)(align - 1);
  t->alignment = align;
  return FFI_OK;
}

ffi_status ffi_prep_cif(ffi_cif *cif, ffi_abi abi, unsigned int nargs, ffi_type *rtype,
                        ffi_type **atypes) {
  if (abi <= FFI_FIRST_ABI || abi >= FFI_LAST_ABI) return FFI_BAD_ABI;
  if (layout(rtype) != FFI_OK) return FFI_BAD_TYPEDEF;
  unsigned bytes = 0;
  for (unsigned i = 0; i < nargs; i++) {
    if (layout(atypes[i]) != FFI_OK) return FFI_BAD_TYPEDEF;
    bytes += (unsigned)((atypes[i]->size + 3) & ~3u);
  }
  cif->abi = abi;
  cif->nargs = nargs;
  cif->arg_types = atypes;
  cif->rtype = rtype;
  cif->bytes = bytes;
  cif->flags = 0;
  return FFI_OK;
}

ffi_status ffi_prep_cif_var(ffi_cif *cif, ffi_abi abi, unsigned int nfixedargs,
                            unsigned int ntotalargs, ffi_type *rtype, ffi_type **atypes) {
  ffi_status st = ffi_prep_cif(cif, abi, ntotalargs, rtype, atypes);
  if (st == FFI_OK) cif->flags = nfixedargs + 1; /* variadic after nfixedargs */
  return st;
}

/* --- Calls and closures ---------------------------------------------------
   clang's wasm32 C ABI: integers up to 32 bits and pointers are i32, 64-bit
   integers i64, float f32, double f64, and long double two i64s. A struct
   (or union) with a single scalar member, at any depth, is passed and
   returned as that scalar; any other is passed by the address of a copy
   the caller makes, and returned through a pointer the caller passes first
   (as is long double; a _Complex is such a struct). Variadic arguments go in a buffer, each promoted
   (to int or double) and aligned to its size, passed by address after the
   fixed ones; a struct there by address. A signature is its return class,
   '_', and its argument classes (trampolines.h). */

#include "trampolines.h"

#define MAX_SIG 64

static ffi_type *single_scalar(ffi_type *t) {
  while (t->type == FFI_TYPE_STRUCT) {
    if (!t->elements || !t->elements[0] || t->elements[1]) return NULL;
    if (t->elements[0]->size != t->size) return NULL;
    t = t->elements[0];
  }
  return t;
}

/* The class of a scalar type, or 0. */
static char scalar_class(ffi_type *t) {
  switch (t->type) {
    case FFI_TYPE_UINT8: case FFI_TYPE_SINT8: case FFI_TYPE_UINT16: case FFI_TYPE_SINT16:
    case FFI_TYPE_UINT32: case FFI_TYPE_SINT32: case FFI_TYPE_INT: case FFI_TYPE_POINTER:
      return 'i';
    case FFI_TYPE_UINT64: case FFI_TYPE_SINT64: return 'j';
    case FFI_TYPE_FLOAT: return 'f';
    case FFI_TYPE_DOUBLE: return 'd';
    default: return 0;
  }
}

/* How a value of type t travels: 'i','j','f','d' directly (its scalar in
   *scalar), 'L' (long double: two i64), 'S' (a struct by address), or 0. */
static char lower(ffi_type *t, ffi_type **scalar) {
  if (t->type == FFI_TYPE_LONGDOUBLE) return 'L';
  if (t->type == FFI_TYPE_COMPLEX) return 'S';
  if (t->type == FFI_TYPE_STRUCT) {
    ffi_type *e = single_scalar(t);
    if (e && e->type == FFI_TYPE_LONGDOUBLE) return 'S';
    if (e && scalar_class(e)) { *scalar = e; return scalar_class(e); }
    return 'S';
  }
  *scalar = t;
  return scalar_class(t);
}

/* A value of scalar type t, read from p, as the Wasm value in a slot. */
static uint64_t load(ffi_type *t, const void *p) {
  uint64_t v = 0;
  switch (t->type) {
    case FFI_TYPE_UINT8: v = (uint32_t)*(const uint8_t *)p; break;
    case FFI_TYPE_SINT8: v = (uint32_t)(int32_t)*(const int8_t *)p; break;
    case FFI_TYPE_UINT16: v = (uint32_t)*(const uint16_t *)p; break;
    case FFI_TYPE_SINT16: v = (uint32_t)(int32_t)*(const int16_t *)p; break;
    default: memcpy(&v, p, t->size); break;
  }
  return v;
}

static void raise(const char *fmt, const char *sig) {
  PyGILState_STATE g = PyGILState_Ensure();
  if (!PyErr_Occurred()) PyErr_Format(PyExc_NotImplementedError, fmt, sig);
  PyGILState_Release(g);
}

static int by_sig(const void *k, const void *e) { return strcmp((const char *)k, *(const char *const *)e); }

/* cffi releases the GIL around the call; an error is raised in the
   caller's thread state, which cffi's call then returns into. */
void ffi_call(ffi_cif *cif, void (*fn)(void), void *rvalue, void **avalue) {
  char sig[MAX_SIG + 4];
  uint64_t a[MAX_SIG];
  unsigned n = 0, nfixed = cif->flags ? cif->flags - 1 : cif->nargs;
  ffi_type *rs = NULL;
  char rc = cif->rtype->type == FFI_TYPE_VOID ? 'v' : lower(cif->rtype, &rs);
  int sret = rc == 'S' || rc == 'L';
  if (rvalue && cif->rtype->size) memset(rvalue, 0, cif->rtype->size < 8 ? 8 : cif->rtype->size);
  sig[0] = sret ? 'v' : rc, sig[1] = '_';
  if (!rc) goto unsupported;
  if (sret) sig[2 + n] = 'i', a[n++] = (uint32_t)(uintptr_t)rvalue;
  for (unsigned i = 0; i < nfixed; i++) {
    ffi_type *t = cif->arg_types[i], *sc = NULL;
    char c = lower(t, &sc);
    if (!c || n + 2 > MAX_SIG) goto unsupported;
    if (c == 'S') {
      void *copy = alloca(t->size);
      memcpy(copy, avalue[i], t->size);
      sig[2 + n] = 'i', a[n++] = (uint32_t)(uintptr_t)copy;
    } else if (c == 'L') {
      memcpy(&a[n], avalue[i], 16);
      sig[2 + n] = 'j', sig[3 + n] = 'j', n += 2;
    } else {
      sig[2 + n] = c, a[n++] = load(sc, avalue[i]);
    }
  }
  if (cif->flags) { /* the variadic arguments' buffer */
    size_t size = 0;
    for (unsigned i = nfixed; i < cif->nargs; i++) size = (size + 15) & ~(size_t)15, size += 16;
    unsigned char *buf = alloca(size + 16), *q = buf;
    for (unsigned i = nfixed; i < cif->nargs; i++) {
      ffi_type *t = cif->arg_types[i], *sc = NULL;
      char c = lower(t, &sc);
      if (!c) goto unsupported;
      if (c == 'S') {
        void *copy = alloca(t->size);
        memcpy(copy, avalue[i], t->size);
        q = (unsigned char *)(((uintptr_t)q + 3) & ~(uintptr_t)3);
        uint32_t p = (uint32_t)(uintptr_t)copy;
        memcpy(q, &p, 4), q += 4;
      } else if (c == 'L') {
        q = (unsigned char *)(((uintptr_t)q + 15) & ~(uintptr_t)15);
        memcpy(q, avalue[i], 16), q += 16;
      } else if (c == 'f' || c == 'd') {
        double d = c == 'f' ? (double)*(const float *)avalue[i] : *(const double *)avalue[i];
        q = (unsigned char *)(((uintptr_t)q + 7) & ~(uintptr_t)7);
        memcpy(q, &d, 8), q += 8;
      } else if (c == 'j') {
        q = (unsigned char *)(((uintptr_t)q + 7) & ~(uintptr_t)7);
        memcpy(q, avalue[i], 8), q += 8;
      } else {
        uint32_t v = (uint32_t)load(sc, avalue[i]);
        q = (unsigned char *)(((uintptr_t)q + 3) & ~(uintptr_t)3);
        memcpy(q, &v, 4), q += 4;
      }
    }
    if (n + 1 > MAX_SIG) goto unsupported;
    sig[2 + n] = 'i', a[n++] = (uint32_t)(uintptr_t)buf;
  }
  sig[2 + n] = 0;
  const ffi_wasi_call *c = bsearch(sig, ffi_wasi_calls, ffi_wasi_ncalls, sizeof *c, by_sig);
  if (!c) goto unsupported;
  uint64_t ret = 0;
  c->call(fn, a, &ret);
  if (!sret && rc != 'v' && rvalue) {
    if (cif->rtype->type == FFI_TYPE_STRUCT) memcpy(rvalue, &ret, cif->rtype->size);
    else if (rc == 'i') { ffi_arg v = (ffi_arg)(uint32_t)ret; memcpy(rvalue, &v, sizeof v); }
    else memcpy(rvalue, &ret, rc == 'f' ? 4 : 8);
  }
  return;
unsupported:
  sig[2 + n] = 0;
  raise("cffi on WASI can't call a C function of signature '%s' by its address: libffi-wasi "
        "has a compiled trampoline per signature (see gen-trampolines.py)", sig);
}

/* A closure's code pointer and slot, kept in its trampoline bytes. */
typedef struct {
  void (*code)(void);
  ffi_wasi_slot *slot;
} closure_tramp;

void *ffi_closure_alloc(size_t size, void **code) {
  ffi_closure *c = calloc(1, size < sizeof(ffi_closure) ? sizeof(ffi_closure) : size);
  *code = NULL; /* known once ffi_prep_closure_loc has the signature */
  return c;
}

void ffi_closure_free(void *closure) {
  if (!closure) return;
  closure_tramp *t = (closure_tramp *)((ffi_closure *)closure)->tramp;
  if (t->slot) t->slot->closure = NULL;
  free(closure);
}

ffi_status ffi_prep_closure_loc(ffi_closure *closure, ffi_cif *cif,
                                void (*fun)(ffi_cif *, void *, void **, void *), void *user_data,
                                void *codeloc) {
  (void)codeloc;
  char sig[MAX_SIG + 4];
  unsigned n = 0;
  ffi_type *rs = NULL;
  char rc = cif->rtype->type == FFI_TYPE_VOID ? 'v' : lower(cif->rtype, &rs);
  int sret = rc == 'S' || rc == 'L';
  sig[0] = sret ? 'v' : rc, sig[1] = '_';
  if (!rc || cif->flags) goto unsupported;
  if (sret) sig[2 + n++] = 'i';
  for (unsigned i = 0; i < cif->nargs; i++) {
    ffi_type *sc = NULL;
    char c = lower(cif->arg_types[i], &sc);
    if (!c || n + 2 > MAX_SIG) goto unsupported;
    if (c == 'S') sig[2 + n++] = 'i';
    else if (c == 'L') sig[2 + n++] = 'j', sig[2 + n++] = 'j';
    else sig[2 + n++] = c;
  }
  sig[2 + n] = 0;
  const ffi_wasi_closure_sig *s =
      bsearch(sig, ffi_wasi_closure_sigs, ffi_wasi_nclosure_sigs, sizeof *s, by_sig);
  if (!s) goto unsupported;
  for (unsigned k = 0; k < ffi_wasi_closure_slots; k++) {
    if (s->slots[k].closure) continue;
    s->slots[k].closure = closure;
    closure_tramp *t = (closure_tramp *)closure->tramp;
    t->code = s->entries[k], t->slot = &s->slots[k];
    closure->cif = cif, closure->fun = fun, closure->user_data = user_data;
    return FFI_OK;
  }
  PyErr_Format(PyExc_MemoryError,
               "cffi on WASI: all %u callbacks of signature '%s' are alive; free one first",
               ffi_wasi_closure_slots, sig);
  return FFI_BAD_ABI;
unsupported:
  sig[2 + n] = 0;
  PyErr_Format(PyExc_NotImplementedError,
               "cffi on WASI can't make a callback of signature '%s' (variadic, or not among "
               "libffi-wasi's compiled entry points; see gen-trampolines.py)", sig);
  return FFI_BAD_ABI;
}

ffi_status ffi_prep_closure(ffi_closure *closure, ffi_cif *cif,
                            void (*fun)(ffi_cif *, void *, void **, void *), void *user_data) {
  return ffi_prep_closure_loc(closure, cif, fun, user_data, NULL);
}

/* The closure's function, called with its arguments' Wasm values. */
void ffi_wasi_dispatch(ffi_wasi_slot *slot, uint64_t *a, uint64_t *ret) {
  ffi_closure *c = slot->closure;
  ffi_cif *cif = c->cif;
  void **avalue = alloca(sizeof(void *) * (cif->nargs ? cif->nargs : 1));
  ffi_type *rs = NULL;
  char rc = cif->rtype->type == FFI_TYPE_VOID ? 'v' : lower(cif->rtype, &rs);
  unsigned n = 0;
  void *rvalue = ret;
  if (rc == 'S' || rc == 'L') rvalue = (void *)(uintptr_t)(uint32_t)a[n++];
  for (unsigned i = 0; i < cif->nargs; i++) {
    ffi_type *sc = NULL;
    char k = lower(cif->arg_types[i], &sc);
    if (k == 'S') avalue[i] = (void *)(uintptr_t)(uint32_t)a[n++];
    else if (k == 'L') avalue[i] = &a[n], n += 2;
    else avalue[i] = &a[n++];
  }
  c->fun(cif, rvalue, avalue, c->user_data);
}
