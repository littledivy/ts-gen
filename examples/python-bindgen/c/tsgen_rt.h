// The C side of a module bound through a ts-gen bridge, for languages whose
// interop is C (bindgen.py writes the bindings and the Wasm shim
// that owns the externref table). JS values are slots of that table: an
// int32_t index, 0 for null. A slot keeps its value alive until it is freed.
//
// Every call into the module (exports and callback trampolines) runs on its
// own JSPI stack, and a call suspended in a wait (tsgen_wait_any) resumes
// as soon as what it waits for has settled, whatever else is suspended:
// tsgen_rt.c moves the suspended calls' parts of the shared C shadow stack
// out of each other's way, and the tsgen_lang_* hooks swap the language's
// own per-call state. JS calling in synchronously while C runs is held back
// by the shim until that code suspends (bindgen.py --defer).
#pragma once
#include <stddef.h>
#include <stdint.h>

int32_t tsgen_slot_alloc(void);
void tsgen_slot_free(int32_t slot);
// A new slot holding the same value; 0 for 0.
int32_t tsgen_slot_dup(int32_t slot);
// The slot holding `undefined` (the table's first constant, IR.md §14).
#define TSGEN_UNDEFINED 128

// The slot allocator's counts, for debug stats: slots in use (singles and
// ranges), the top of the used part of the table, slots on the free list
// below it, and the table's size.
typedef struct {
  int32_t live, top, free, size;
} tsgen_stats;
void tsgen_slot_stats(tsgen_stats *st);

// n contiguous slots, all null, and their release.
int32_t tsgen_range_alloc(int32_t n);
void tsgen_range_free(int32_t base, int32_t n);

// Brackets every call into the module. tsgen_enter returns what
// tsgen_leave restores. An export calls tsgen_note_entry first, before
// anything uses the shadow stack, to give the call's stack its base.
void tsgen_note_entry(void);
int tsgen_enter(void);
void tsgen_leave(int prev);
// Calls into the module in progress, nested ones included.
int tsgen_depth(void);

// The language's state for each call (an interpreter's frames): enter
// makes the call's own, which suspend sets aside for what ran before it,
// resume puts back and leave drops. Weak: a language without any keeps
// the defaults, which do nothing.
void *tsgen_lang_enter(void);
void tsgen_lang_suspend(void *lang);
void tsgen_lang_resume(void *lang);
void tsgen_lang_leave(void *lang);

// The language state of the call that suspended most recently and hasn't
// resumed, if any.
void *tsgen_last_suspended(void);

// The shadow stack pointer, for a language's runtime (Pyodide's stackSave).
uintptr_t tsgen_stack_pointer(void);

// Suspends (JSPI) until one of the futures has settled, and returns its
// index; it doesn't take or drop them. n must be at least 1.
int tsgen_wait_any(const int32_t *futures, int n);
