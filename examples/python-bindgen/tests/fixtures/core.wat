;; A stand-in for the linked C module the shim is generated against: a few
;; of generic.ir's imports, the dispatch export, and what the C side exports
;; for the shim (the slot allocator, and the running and waker hooks of
;; --defer).
(module
  (import "tsgen" "./runtime/generic.js::get(Any,str)" (func (param i32 i32 i32 i32)))
  (import "tsgen" "./runtime/generic.js::global()" (func (result i32)))
  (import "tsgen" "tw:future::take<Value>" (func (param i32 i32)))
  (memory (export "memory") 1)
  (func (export "cfts_slot_alloc") (result i32) (i32.const 0))
  (func (export "cfts_slot_free") (param i32))
  (func (export "cfts_running") (result i32) (i32.const 0))
  (func (export "cfts_waker") (result i32) (i32.const 0))
  (func (export "cfts:dispatch(str,str,Any?,arr<Value>,Any?)")
    (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i32) (i32.const 0)))
