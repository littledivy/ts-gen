/* See ffi.h: libffi's types and layout rules for wasm32, without calls. */
#include <Python.h>
#include <stdlib.h>

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
  (void)nfixedargs;
  return ffi_prep_cif(cif, abi, ntotalargs, rtype, atypes);
}

/* cffi releases the GIL around the call; the error is raised in the
   caller's thread state, which cffi's call then returns into. */
void ffi_call(ffi_cif *cif, void (*fn)(void), void *rvalue, void **avalue) {
  (void)fn;
  (void)avalue;
  if (rvalue && cif->rtype->size) memset(rvalue, 0, cif->rtype->size < 8 ? 8 : cif->rtype->size);
  PyGILState_STATE g = PyGILState_Ensure();
  if (!PyErr_Occurred())
    PyErr_SetString(PyExc_NotImplementedError,
                    "cffi can't call a C function by its address on WASI (libffi has no wasm "
                    "port); call it through a compiled cffi module (API mode) instead");
  PyGILState_Release(g);
}

void *ffi_closure_alloc(size_t size, void **code) {
  (void)size;
  *code = NULL;
  return NULL;
}

void ffi_closure_free(void *closure) { free(closure); }

ffi_status ffi_prep_closure(ffi_closure *closure, ffi_cif *cif,
                            void (*fun)(ffi_cif *, void *, void **, void *), void *user_data) {
  (void)closure, (void)cif, (void)fun, (void)user_data;
  return FFI_BAD_ABI;
}

ffi_status ffi_prep_closure_loc(ffi_closure *closure, ffi_cif *cif,
                                void (*fun)(ffi_cif *, void *, void **, void *), void *user_data,
                                void *codeloc) {
  (void)codeloc;
  return ffi_prep_closure(closure, cif, fun, user_data);
}
