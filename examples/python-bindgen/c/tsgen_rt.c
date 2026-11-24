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

// ---- calls, waits and the shadow stack ----
//
// Each call into the module runs on its own JSPI stack, but they all share
// the C shadow stack (__stack_pointer, in linear memory), and a call
// suspended in a wait can resume while calls that entered after it are
// still suspended, as Pyodide's stack switching allows. A suspended call's
// part of the shadow stack, [low, base), stays where it is ("resident")
// until another call needs that memory; it is then copied out ("evicted")
// and copied back when the call resumes. Whenever no C code runs, the stack
// pointer is at or below every resident part, so a call that enters then
// (the shim holds back calls while C runs, bindgen.py --defer) only uses
// memory below them. A language's own per-call state (an interpreter's
// frame chain) is swapped by the tsgen_lang_* hooks.

__asm__(".globaltype __stack_pointer, i32\n"
        ".globl tsgen_get_sp\n"
        ".type tsgen_get_sp,@function\n"
        "tsgen_get_sp:\n"
        ".functype tsgen_get_sp () -> (i32)\n"
        "  global.get __stack_pointer\n"
        "  end_function\n"
        ".globl tsgen_set_sp\n"
        ".type tsgen_set_sp,@function\n"
        "tsgen_set_sp:\n"
        ".functype tsgen_set_sp (i32) -> ()\n"
        "  local.get 0\n"
        "  global.set __stack_pointer\n"
        "  end_function\n");
uintptr_t tsgen_get_sp(void);
void tsgen_set_sp(uintptr_t sp);
extern char __stack_low, __stack_high;

// Below this much free shadow stack, a call suspending with no C code to
// return to moves every suspended call's stack out of the way.
#define LOW_WATER (256 * 1024)

typedef struct task task;
struct task {
  task *parent;  // the call running when this one entered or resumed, if any
  task *next, *prev;  // in `suspended`
  uintptr_t base, low;
  uint8_t *copy;  // the stack, while evicted
  int resident;
  void *lang;
};

static task *current, *suspended;
static int depth, running;
static int32_t next_waker = 1;
// The stack pointer the export saw on entry (tsgen_note_entry).
static uintptr_t entry_sp;
// The stack pointer while no C code runs, where the next call from JS
// starts: set as a call suspends with nothing to return to, and when the
// outermost call returns. A call's base is this rather than anything read
// inside it, since the export's glue may take shadow stack (a return
// area) before the C code runs. Zero until the first call (wizer's).
static uintptr_t idle_sp;
static void release_held(void);

__attribute__((weak)) void *tsgen_lang_enter(void) { return 0; }
__attribute__((weak)) void tsgen_lang_suspend(void *lang) { (void)lang; }
__attribute__((weak)) void tsgen_lang_resume(void *lang) { (void)lang; }
__attribute__((weak)) void tsgen_lang_leave(void *lang) { (void)lang; }
// A future the module settles itself: tsgen_hold makes one (returning it,
// its resolver in *resolver), tsgen_release settles it through the
// resolver. Weak: a module without them never holds a resume back.
__attribute__((weak)) int32_t tsgen_hold(int32_t *resolver) { (void)resolver; return 0; }
__attribute__((weak)) void tsgen_release(int32_t resolver) { (void)resolver; }

int tsgen_depth(void) { return depth; }

// For the shim: whether C code is running now (not suspended in a wait).
EXPORT("cfts_running") int32_t tsgen_running(void) { return running; }
EXPORT("cfts_waker") int32_t tsgen_waker(void) { return next_waker++; }

void tsgen_note_entry(void) { entry_sp = tsgen_get_sp(); }

uintptr_t tsgen_stack_pointer(void) { return tsgen_get_sp(); }

void *tsgen_last_suspended(void) { return suspended ? suspended->lang : 0; }

int tsgen_enter(void) {
  task *t = calloc(1, sizeof *t);
  if (!t) abort();
  // A call made before any export noted its entry (wizer's) is its own base.
  if (!current && idle_sp) t->base = idle_sp;
  else t->base = entry_sp ? entry_sp : tsgen_get_sp();
  entry_sp = 0;
  t->parent = current;
  current = t;
  int prev = running;
  depth++;
  running = 1;
  t->lang = tsgen_lang_enter();
  return prev;
}

void tsgen_leave(int prev) {
  task *t = current;
  tsgen_lang_leave(t->lang);
  (void)prev;
  current = t->parent;
  if (!current) {
    idle_sp = t->base;
    release_held();
  }
  free(t);
  depth--;
  running = current != 0;
}

static void evict(task *t) {
  if (!t->resident) return;
  size_t n = t->base - t->low;
  t->copy = malloc(n ? n : 1);
  if (!t->copy) abort();
  memcpy(t->copy, (void *)t->low, n);
  t->resident = 0;
}

static void unlink_suspended(task *t) {
  if (t->prev) t->prev->next = t->next;
  else suspended = t->next;
  if (t->next) t->next->prev = t->prev;
  t->next = t->prev = 0;
}

// Brings `t`'s stack back, moving out every resident one it overlaps or
// lies above (which it would grow into). Runs with the stack pointer below
// every resident stack, and uses no shadow stack of its own.
static void bring_back(task *t) {
  for (task *o = suspended; o; o = o->next) {
    if (o != t && o->resident && o->low < t->base) evict(o);
  }
  // Nothing resident lies below t's base now.
  tsgen_set_sp(t->low);
  if (!t->resident) {
    memcpy((void *)t->low, t->copy, t->base - t->low);
    free(t->copy);
    t->copy = 0;
    t->resident = 1;
  }
}

// Resumes held back until no C code runs, by their resolvers.
static int32_t *held;
static int n_held, cap_held;

static void hold_back(void) {
  int32_t r;
  int32_t f = tsgen_hold(&r);
  if (!f) abort();
  if (n_held == cap_held) {
    cap_held = cap_held ? cap_held * 2 : 8;
    held = realloc(held, sizeof *held * cap_held);
    if (!held) abort();
  }
  held[n_held++] = r;
  int32_t w = next_waker++;
  if (tsgen_future_poll(f, w) == 0) tsgen_future_wait(w);
  tsgen_future_drop(f);
  tsgen_slot_free(f);
}

// As C code stops running (the last thing it does before returning to JS).
static void release_held(void) {
  while (n_held) tsgen_release(held[--n_held]);
}

// One wait for the waker: the call suspends, and resumes with its stack
// where it was. After the wait returns, nothing reads this function's
// shadow stack frame before bring_back has restored it.
__attribute__((noinline)) static void suspend(int32_t w) {
  task *t = current;
  t->low = tsgen_get_sp();
  t->resident = 1;
  t->prev = 0;
  t->next = suspended;
  if (suspended) suspended->prev = t;
  suspended = t;
  tsgen_lang_suspend(t->lang);
  task *parent = t->parent;
  current = parent;
  running = parent != 0;
  if (parent) {
    // The C code that called in continues on its own stack, below which
    // this one lies.
    evict(t);
    tsgen_set_sp(t->base);
  } else if (t->low - (uintptr_t)&__stack_low < LOW_WATER) {
    for (task *o = suspended; o; o = o->next) evict(o);
    tsgen_set_sp((uintptr_t)&__stack_high);
  }
  if (!parent) {
    idle_sp = tsgen_get_sp();
    release_held();
  }
  tsgen_future_wait(w);
  // JS can run the job that resumes this from inside an import another
  // call made, with that call's C code still on the stack (and its stack
  // pointer, below which this waits without touching memory above it).
  // Then it waits again, until no C code runs.
  while (running) hold_back();
  bring_back(t);
  unlink_suspended(t);
  t->parent = current;
  current = t;
  running = 1;
  tsgen_lang_resume(t->lang);
}

int tsgen_wait_any(const int32_t *fs, int n) {
  int32_t w = next_waker++;
  for (;;) {
    for (int i = 0; i < n; i++) {
      if (tsgen_future_poll(fs[i], w) != 0) return i;
    }
    suspend(w);
  }
}

// A wake no wait holds: the module polls again whenever it next waits.
EXPORT("tw:future/wake") void tsgen_wake(int32_t waker) { (void)waker; }
