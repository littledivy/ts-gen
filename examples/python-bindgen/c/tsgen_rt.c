// See tsgen_rt.h.
#include "tsgen_rt.h"

#include <stdlib.h>
#include <string.h>

#define IMPORT(m, n) __attribute__((import_module(m), import_name(n)))
#define EXPORT(n) __attribute__((export_name(n)))

// The shim's table operations (bindgen.py).
IMPORT("tsgen", "tsgen_table_grow") int32_t tsgen_table_grow(int32_t n);
IMPORT("tsgen", "tsgen_ref_clear") void tsgen_ref_clear(int32_t base, int32_t n);
IMPORT("tsgen", "tsgen_ref_copy") void tsgen_ref_copy(int32_t dst, int32_t src);
// The bridge's future operations (IR.md §16), through the shim.
IMPORT("tsgen", "tw:future::poll") int32_t tsgen_future_poll(int32_t f, int32_t waker);
IMPORT("tsgen", "tw:future::wait") void tsgen_future_wait(int32_t waker);
IMPORT("tsgen", "tw:future::drop") void tsgen_future_drop(int32_t f);
IMPORT("tsgen", "tw:future::new") void tsgen_future_new(void *ret);
IMPORT("tsgen", "tw:future::resolve<unit>") void tsgen_future_resolve_unit(int32_t resolver);

// ---- slots ----
//
// The table starts at the shim's heap_base (132) and grows on demand. Single
// slots come from a free list; a range of several comes off the top, and goes
// back on top when it is the topmost one (ranges are short-lived: a call's
// arguments), otherwise onto the free list slot by slot.

#define HEAP_BASE 132
static int32_t top = HEAP_BASE, size = HEAP_BASE;
static int32_t *free_slots;
static int32_t nfree, capfree;

static void reserve_top(int32_t n) {
  if (top + n <= size) return;
  int32_t grow = top + n - size;
  if (grow < size / 2) grow = size / 2;
  if (tsgen_table_grow(grow) < 0) abort();
  size += grow;
}

EXPORT("cfts_slot_alloc") int32_t tsgen_slot_alloc(void) {
  if (nfree) return free_slots[--nfree];
  reserve_top(1);
  return top++;
}

static void push_free(int32_t s) {
  if (nfree == capfree) {
    capfree = capfree ? capfree * 2 : 256;
    free_slots = realloc(free_slots, capfree * sizeof *free_slots);
    if (!free_slots) abort();
  }
  free_slots[nfree++] = s;
}

EXPORT("cfts_slot_free") void tsgen_slot_free(int32_t s) {
  if (s < HEAP_BASE) return;
  tsgen_ref_clear(s, 1);
  if (s == top - 1) top--;
  else push_free(s);
}

int32_t tsgen_slot_dup(int32_t s) {
  if (!s) return 0;
  int32_t d = tsgen_slot_alloc();
  tsgen_ref_copy(d, s);
  return d;
}

EXPORT("tw:table/alloc") int32_t tsgen_range_alloc(int32_t n) {
  if (n <= 0) return 0;
  if (n == 1) return tsgen_slot_alloc();
  reserve_top(n);
  int32_t base = top;
  top += n;
  return base;
}

EXPORT("tw:table/free") void tsgen_range_free(int32_t base, int32_t n) {
  if (n <= 0 || base < HEAP_BASE) return;
  tsgen_ref_clear(base, n);
  if (base + n == top) {
    top = base;
    return;
  }
  for (int32_t i = 0; i < n; i++) push_free(base + i);
}

void tsgen_slot_stats(tsgen_stats *st) {
  st->live = top - HEAP_BASE - nfree;
  st->top = top;
  st->free = nfree;
  st->size = size;
}

// ---- linear memory for the bridge (IR.md §11) ----

EXPORT("tw:realloc") void *tsgen_realloc(void *old, size_t old_size, size_t align, size_t new_size) {
  (void)old_size;
  if (old) return realloc(old, new_size);
  if (align > 16) return aligned_alloc(align, (new_size + align - 1) / align * align);
  return malloc(new_size ? new_size : 1);
}

EXPORT("tw:free") void tsgen_free(void *p, size_t size, size_t align) {
  (void)size;
  (void)align;
  free(p);
}

// ---- nesting and waiting ----

static int depth, running;
static int32_t next_waker = 1;

// A wait resumed while a call that entered after it is still in progress
// holds a future that the next return from a call settles.
typedef struct {
  int32_t resolver;
} level_waiter;
static level_waiter *level_waiters;
static int nlevel, caplevel;

int tsgen_depth(void) { return depth; }

// For the shim: whether C code is running now (not suspended in a wait).
EXPORT("cfts_running") int32_t tsgen_running(void) { return running; }
EXPORT("cfts_waker") int32_t tsgen_waker(void) { return next_waker++; }

int tsgen_enter(void) {
  int prev = running;
  depth++;
  running = 1;
  return prev;
}

void tsgen_leave(int prev) {
  depth--;
  running = prev;
  // Every waiter checks its level again.
  int n = nlevel;
  nlevel = 0;
  for (int i = 0; i < n; i++) {
    tsgen_future_resolve_unit(level_waiters[i].resolver);
    tsgen_slot_free(level_waiters[i].resolver);
  }
}

int tsgen_wait_any(const int32_t *fs, int n) {
  int mine = depth;
  int32_t w = next_waker++;
  for (;;) {
    int ready = -1;
    for (int i = 0; i < n; i++) {
      if (tsgen_future_poll(fs[i], w) != 0) {
        ready = i;
        break;
      }
    }
    if (ready >= 0 && depth == mine) return ready;
    int32_t level = 0;
    if (depth > mine) {
      struct {
        int32_t future, pad0, resolver, pad1;
      } r;
      tsgen_future_new(&r);
      if (nlevel == caplevel) {
        caplevel = caplevel ? caplevel * 2 : 8;
        level_waiters = realloc(level_waiters, caplevel * sizeof *level_waiters);
        if (!level_waiters) abort();
      }
      level_waiters[nlevel++].resolver = r.resolver;
      level = r.future;
      tsgen_future_poll(level, w);
    }
    running = 0;
    tsgen_future_wait(w);
    running = 1;
    if (level) {
      tsgen_future_drop(level);
      tsgen_slot_free(level);
    }
  }
}

// A wake no wait holds: the module polls again whenever it next waits.
EXPORT("tw:future/wake") void tsgen_wake(int32_t waker) { (void)waker; }
