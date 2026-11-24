;; A hand-written language that blocks on futures under JSPI: `app.run`
;; awaits two JS promises by polling and suspending in `tw:future wait`,
;; then returns their sum as a future of its own.
(module
  (import "tw:js/global" "Api#later()" (func $later (param externref) (result externref)))
  (import "tw:future" "poll" (func $poll (param externref i32) (result i32)))
  (import "tw:future" "wait" (func $wait (param i32)))
  (import "tw:future" "take<u32>" (func $take (param externref) (result i32)))
  (import "tw:future" "drop" (func $drop (param externref)))
  (import "tw:future" "new" (func $new (result externref externref)))
  (import "tw:future" "resolve<u32>" (func $resolve (param externref i32)))
{RUNTIME}
  (global $wakes (mut i32) (i32.const 0))
  (func (export "test:wakes") (result i32) (global.get $wakes))
  ;; Only a wake no wait holds reaches the language.
  (func (export "tw:future/wake") (param $w i32)
    (global.set $wakes (i32.add (global.get $wakes) (i32.const 1))))

  ;; Waits for `f` on waker `w`, then takes and drops it.
  (func $await (param $f externref) (param $w i32) (result i32)
    (local $v i32)
    (block $ready
      (loop $again
        (br_if $ready (i32.ne (call $poll (local.get $f) (local.get $w)) (i32.const 0)))
        (call $wait (local.get $w))
        (br $again)))
    (local.set $v (call $take (local.get $f)))
    (call $drop (local.get $f))
    (local.get $v))

  (func (export "app.run(Api)") (param $api externref) (result externref)
    (local $a externref) (local $b externref) (local $sum i32)
    (local $fut externref) (local $res externref)
    (local.set $a (call $later (local.get $api)))
    (local.set $b (call $later (local.get $api)))
    ;; `b` gets a waker no wait holds while `a` is awaited.
    (drop (call $poll (local.get $b) (i32.const 9)))
    (local.set $sum (call $await (local.get $a) (i32.const 7)))
    (local.set $sum (i32.add (local.get $sum) (call $await (local.get $b) (i32.const 9))))
    (call $new)
    (local.set $res)
    (local.set $fut)
    (call $resolve (local.get $res) (local.get $sum))
    (local.get $fut))
)
