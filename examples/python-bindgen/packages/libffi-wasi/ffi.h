/* libffi's interface for wasm32-wasip1, for cffi's _cffi_backend.
 *
 * Wasm calls a function pointer with call_indirect, whose type is fixed in
 * the code, so a call or callback whose signature is only known at run
 * time needs a function compiled for it. gen-trampolines.py compiles one
 * per signature over Wasm's four value types, up to a number of arguments
 * (see there); ffi_call raises NotImplementedError for a signature beyond
 * them, and a callback with one fails to be made. Closures come from a
 * fixed pool of entry points per signature, so only so many callbacks of
 * a signature live at once. See ffi.c.
 */
#ifndef CF_LIBFFI_WASI_H
#define CF_LIBFFI_WASI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FFI_CLOSURES 1
#define FFI_GO_CLOSURES 0
#define FFI_TRAMPOLINE_SIZE 16
#define FFI_NATIVE_RAW_API 0

typedef enum ffi_abi {
  FFI_FIRST_ABI = 0,
  FFI_WASM32,
  FFI_LAST_ABI,
  FFI_DEFAULT_ABI = FFI_WASM32
} ffi_abi;

#define FFI_TYPE_VOID 0
#define FFI_TYPE_INT 1
#define FFI_TYPE_FLOAT 2
#define FFI_TYPE_DOUBLE 3
#define FFI_TYPE_LONGDOUBLE 4
#define FFI_TYPE_UINT8 5
#define FFI_TYPE_SINT8 6
#define FFI_TYPE_UINT16 7
#define FFI_TYPE_SINT16 8
#define FFI_TYPE_UINT32 9
#define FFI_TYPE_SINT32 10
#define FFI_TYPE_UINT64 11
#define FFI_TYPE_SINT64 12
#define FFI_TYPE_STRUCT 13
#define FFI_TYPE_POINTER 14
#define FFI_TYPE_COMPLEX 15
#define FFI_TYPE_LAST FFI_TYPE_COMPLEX

typedef struct _ffi_type {
  size_t size;
  unsigned short alignment;
  unsigned short type;
  struct _ffi_type **elements;
} ffi_type;

extern ffi_type ffi_type_void, ffi_type_uint8, ffi_type_sint8, ffi_type_uint16, ffi_type_sint16,
    ffi_type_uint32, ffi_type_sint32, ffi_type_uint64, ffi_type_sint64, ffi_type_float,
    ffi_type_double, ffi_type_longdouble, ffi_type_pointer, ffi_type_complex_float,
    ffi_type_complex_double, ffi_type_complex_longdouble;

#define ffi_type_uchar ffi_type_uint8
#define ffi_type_schar ffi_type_sint8
#define ffi_type_ushort ffi_type_uint16
#define ffi_type_sshort ffi_type_sint16
#define ffi_type_uint ffi_type_uint32
#define ffi_type_sint ffi_type_sint32
#define ffi_type_ulong ffi_type_uint32
#define ffi_type_slong ffi_type_sint32

typedef enum { FFI_OK = 0, FFI_BAD_TYPEDEF, FFI_BAD_ABI, FFI_BAD_ARGTYPE } ffi_status;

typedef unsigned long ffi_arg;
typedef signed long ffi_sarg;

typedef struct {
  ffi_abi abi;
  unsigned nargs;
  ffi_type **arg_types;
  ffi_type *rtype;
  unsigned bytes;
  unsigned flags;
} ffi_cif;

typedef struct {
  char tramp[FFI_TRAMPOLINE_SIZE];
  ffi_cif *cif;
  void (*fun)(ffi_cif *, void *, void **, void *);
  void *user_data;
} ffi_closure;

ffi_status ffi_prep_cif(ffi_cif *cif, ffi_abi abi, unsigned int nargs, ffi_type *rtype,
                        ffi_type **atypes);
ffi_status ffi_prep_cif_var(ffi_cif *cif, ffi_abi abi, unsigned int nfixedargs,
                            unsigned int ntotalargs, ffi_type *rtype, ffi_type **atypes);
void ffi_call(ffi_cif *cif, void (*fn)(void), void *rvalue, void **avalue);
void *ffi_closure_alloc(size_t size, void **code);
void ffi_closure_free(void *closure);
ffi_status ffi_prep_closure(ffi_closure *closure, ffi_cif *cif,
                            void (*fun)(ffi_cif *, void *, void **, void *), void *user_data);
ffi_status ffi_prep_closure_loc(ffi_closure *closure, ffi_cif *cif,
                                void (*fun)(ffi_cif *, void *, void **, void *), void *user_data,
                                void *codeloc);

#ifdef __cplusplus
}
#endif
#endif
