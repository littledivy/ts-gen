// The C side of a module bound through a ts-gen bridge, for languages whose
// interop is C (bindgen.py writes the bindings and the Wasm shim
// that owns the externref table). JS values are slots of that table: an
// int32_t index, 0 for null. A slot keeps its value alive until it is freed.
//
// Calls into the module (exports and callback trampolines) and waits nest
// strictly. The C shadow stack and an interpreter's own state live in linear
// memory, which every suspended call shares, so a call suspended in a wait
// resumes only once every call that entered after it has returned
// (tsgen_wait_any); and JS calling in synchronously while C runs is held
// back by the shim until that code suspends (bindgen.py --defer). Nesting
// strictly keeps the shadow stack pointer right across a suspension: the
// calls that ran meanwhile have all restored it as they returned.
#pragma once
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
// tsgen_leave restores.
int tsgen_enter(void);
void tsgen_leave(int prev);
// Calls into the module in progress, nested ones included.
int tsgen_depth(void);

// Suspends (JSPI) until one of the futures has settled, and returns its
// index; it doesn't take or drop them. n must be at least 1.
int tsgen_wait_any(const int32_t *futures, int n);
