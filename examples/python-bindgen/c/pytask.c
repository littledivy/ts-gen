// Python's per-call state, for tsgen_rt.c's calls that suspend and resume
// out of order (the tsgen_lang_* hooks): what Pyodide's stack switching
// saves and restores, as workerd's Pyodide does it.
//
// The thread state holds the running call's frame chain, its frames' data
// stack, the exception being handled, the context, the recursion depth and
// asyncio's running loop and task. A call starts with the caller's
// context, exception, depth and asyncio state, an empty frame chain (so
// the garbage collector, which walks the thread state's frames, never
// reaches a suspended call's frames) and a data stack of its own (so the
// calls' frames don't interleave). Suspending puts back the state from
// before the call ran, and resuming puts the call's back.

#define Py_BUILD_CORE 1
#include <Python.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#include "internal/pycore_obmalloc.h"
#include "internal/pycore_pystate.h"
#include "internal/pycore_tstate.h"

extern int32_t cur_cx;  // cfjs.c

typedef struct {
  struct _PyInterpreterFrame *frame;
  _PyStackChunk *chunk;
  PyObject **top, **limit;
  _PyErr_StackItem *exc_info;
  PyObject *context;
  uint64_t context_ver;
  int recursion_remaining;
  PyObject *loop, *task;
  int32_t cx;
} state;

typedef struct {
  state own, outer;
} pytask;

// Copies the thread state into `s`, which takes references of its own.
static void capture(PyThreadState *ts, state *s) {
  _PyThreadStateImpl *ti = (_PyThreadStateImpl *)ts;
  s->frame = ts->current_frame;
  s->chunk = ts->datastack_chunk;
  s->top = ts->datastack_top;
  s->limit = ts->datastack_limit;
  s->exc_info = ts->exc_info;
  s->context = Py_XNewRef(ts->context);
  s->context_ver = ts->context_ver;
  s->recursion_remaining = ts->py_recursion_remaining;
  s->loop = Py_XNewRef(ti->asyncio_running_loop);
  s->task = Py_XNewRef(ti->asyncio_running_task);
  s->cx = cur_cx;
}

// Makes `s` the thread state's, its references moving with it.
static void install(PyThreadState *ts, state *s) {
  _PyThreadStateImpl *ti = (_PyThreadStateImpl *)ts;
  PyObject *context = ts->context, *loop = ti->asyncio_running_loop, *task = ti->asyncio_running_task;
  ts->current_frame = s->frame;
  ts->datastack_chunk = s->chunk;
  ts->datastack_top = s->top;
  ts->datastack_limit = s->limit;
  ts->exc_info = s->exc_info;
  ts->context = s->context;
  ts->context_ver = s->context_ver;
  ts->py_recursion_remaining = s->recursion_remaining;
  ti->asyncio_running_loop = s->loop;
  ti->asyncio_running_task = s->task;
  cur_cx = s->cx;
  // None of these is the last reference: `s` held one of each it had, and
  // the old values are still held by the state they were captured into.
  Py_XDECREF(context);
  Py_XDECREF(loop);
  Py_XDECREF(task);
}

void *tsgen_lang_enter(void) {
  PyThreadState *ts = _PyThreadState_GET();
  if (!ts) return NULL;
  pytask *t = malloc(sizeof *t);
  if (!t) abort();
  capture(ts, &t->outer);
  ts->current_frame = NULL;
  // The first frame pushed makes a root chunk (push_chunk), which
  // _PyThreadState_PopFrame never frees: tsgen_lang_leave does.
  ts->datastack_chunk = NULL;
  ts->datastack_top = NULL;
  ts->datastack_limit = NULL;
  return t;
}

void tsgen_lang_suspend(void *lang) {
  pytask *t = lang;
  if (!t) return;
  PyThreadState *ts = _PyThreadState_GET();
  capture(ts, &t->own);
  install(ts, &t->outer);
}

void tsgen_lang_resume(void *lang) {
  pytask *t = lang;
  if (!t) return;
  PyThreadState *ts = _PyThreadState_GET();
  capture(ts, &t->outer);
  install(ts, &t->own);
}

void tsgen_lang_leave(void *lang) {
  pytask *t = lang;
  if (!t) return;
  PyThreadState *ts = _PyThreadState_GET();
  _PyStackChunk *chunk = ts->datastack_chunk;
  if (chunk) {
    // Every frame has been popped, so this is the root chunk; push_chunk
    // reuses the thread's cached one.
    if (!ts->datastack_cached_chunk) ts->datastack_cached_chunk = chunk;
    else _PyObject_VirtualFree(chunk, chunk->size);
  }
  install(ts, &t->outer);
  free(t);
}

// The context of the call `lang` (tsgen_last_suspended) left suspended.
int32_t cf_pytask_cx(void *lang) {
  pytask *t = lang;
  return t ? t->own.cx : 0;
}
