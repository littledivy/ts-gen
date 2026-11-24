//go:build tsgen_runtime

// The Go side of the ts-gen `tw` ABI under the all-linear profile, copied
// into every package go-bindgen generates (the build tag above is dropped).
// It names no API. Go has no externref, so a shim generated with the
// bindings (shim.wat, merged into the module) keeps JS values in the
// module's `tw:table`, and Go holds their slot numbers:
//
//   Object   a JS value in one slot; the slot is freed by Close, or by a
//            cleanup (runtime.AddCleanup) once the Go value is unreachable
//   Value    a JS value of no declared type: `Any`, or an erased type
//            parameter, decoded with Decode through its JSON (json.go)
//   await    blocks the calling goroutine until a JS promise settles. Other
//            goroutines run meanwhile; once all of them wait, the module
//            suspends in `tw:future wait` (JSPI, the profile's `jspi = on`)
//            until a promise settles.
//
// Every shim import returns a status: 0 when the call returned (results in
// the return area), 1 when it threw the member's declared error (the
// error's enum in the return area), 2 when it threw any other JS exception
// (the exception's slot in the return area).

package tsgenruntime

import (
	"errors"
	"math"
	"reflect"
	"runtime"
	"strconv"
	"unsafe"
)

//go:wasmimport shim tsgen_table_grow
func tsgenTableGrow(n int32) int32

//go:wasmimport shim tsgen_ref_clear
func tsgenRefClear(base, n int32)

//go:wasmimport shim tsgen_ref_copy
func tsgenRefCopy(dst, src int32)

//go:wasmimport shim tsgen_ref_is_null
func tsgenRefIsNull(slot int32) int32

//go:wasmimport tw:future wait
func tsgenWait(waker int32)

// The return area: one 8-byte slot per wire value, where the shim leaves an
// import's results and an export leaves its own. It's read straight after
// each crossing, before anything else can run, so one area serves every
// call.
var retArea [64]uint64

func retPtr() int32              { return int32(uintptr(unsafe.Pointer(&retArea))) }
func retI32(i int) int32         { return int32(uint32(retArea[i])) }
func retI64(i int) int64         { return int64(retArea[i]) }
func retF32(i int) float32       { return math.Float32frombits(uint32(retArea[i])) }
func retF64(i int) float64       { return math.Float64frombits(retArea[i]) }
func setRetI32(i int, v int32)   { retArea[i] = uint64(uint32(v)) }
func setRetI64(i int, v int64)   { retArea[i] = uint64(v) }
func setRetF32(i int, v float32) { retArea[i] = uint64(math.Float32bits(v)) }
func setRetF64(i int, v float64) { retArea[i] = math.Float64bits(v) }
func b2i(b bool) int32 {
	if b {
		return 1
	}
	return 0
}

//go:wasmexport tsgen_ret_area
func tsgenRetArea() int32 { return retPtr() }

// Memory (IR.md §11). What the bridge allocates stays reachable from
// allocs until it's freed or taken.

var allocs = map[int32][]byte{}

//go:wasmexport tw:realloc
func twRealloc(old, oldSize, align, size int32) int32 {
	n := size
	if align > 1 {
		n = (size + align - 1) / align * align
	}
	b := make([]byte, n)
	if old != 0 {
		copy(b, allocs[old])
		delete(allocs, old)
	}
	p := int32(uintptr(unsafe.Pointer(unsafe.SliceData(b))))
	allocs[p] = b
	return p
}

//go:wasmexport tw:free
func twFree(p, size, align int32) {
	delete(allocs, p)
}

// take hands what the bridge allocated at p to Go.
func take(p, n int32) []byte {
	if n == 0 {
		return nil
	}
	b := allocs[p]
	delete(allocs, p)
	return b
}

// A string the bridge allocated, without a copy.
func takeString(p, n int32) string {
	if n <= 0 {
		return ""
	}
	return unsafe.String(unsafe.SliceData(take(p, n)), int(n))
}

func takeOptString(p, n int32) *string {
	if n == -1 {
		return nil
	}
	s := takeString(p, n)
	return &s
}

// The (ptr, len) of a string for one call; the caller keeps s alive.
func strPtr(s string) int32 {
	if len(s) == 0 {
		return 1
	}
	return int32(uintptr(unsafe.Pointer(unsafe.StringData(s))))
}

func bytesPtr[T any](b []T, align int32) int32 {
	if len(b) == 0 {
		return align
	}
	return int32(uintptr(unsafe.Pointer(unsafe.SliceData(b))))
}

// A typed array the bridge allocated, as a Go slice over it.
func takeVec[T any](p, n int32) []T {
	if n <= 0 {
		return nil
	}
	b := take(p, n)
	return unsafe.Slice((*T)(unsafe.Pointer(unsafe.SliceData(b))), int(n))
}

// Packed memory parts of arr<T> (IR.md §11): unaligned access.
func memAt(p int32, off int) unsafe.Pointer {
	return unsafe.Pointer(uintptr(p) + uintptr(off))
}
func ldI32(p int32, off int) int32     { return *(*int32)(memAt(p, off)) }
func ldI64(p int32, off int) int64     { return *(*int64)(memAt(p, off)) }
func ldF32(p int32, off int) float32   { return *(*float32)(memAt(p, off)) }
func ldF64(p int32, off int) float64   { return *(*float64)(memAt(p, off)) }
func ldU8(p int32, off int) uint8      { return *(*uint8)(memAt(p, off)) }
func ldI8(p int32, off int) int8       { return *(*int8)(memAt(p, off)) }
func ldU16(p int32, off int) uint16    { return *(*uint16)(memAt(p, off)) }
func ldI16(p int32, off int) int16     { return *(*int16)(memAt(p, off)) }
func ldU32(p int32, off int) uint32    { return *(*uint32)(memAt(p, off)) }
func ldU64(p int32, off int) uint64    { return *(*uint64)(memAt(p, off)) }
func stI32(b []byte, off int, v int32) { *(*int32)(unsafe.Pointer(&b[off])) = v }
func stI64(b []byte, off int, v int64) { *(*int64)(unsafe.Pointer(&b[off])) = v }
func stF32(b []byte, off int, v float32) {
	*(*float32)(unsafe.Pointer(&b[off])) = v
}
func stF64(b []byte, off int, v float64) {
	*(*float64)(unsafe.Pointer(&b[off])) = v
}
func stU8(b []byte, off int, v uint8)   { b[off] = v }
func stI8(b []byte, off int, v int8)    { b[off] = uint8(v) }
func stU16(b []byte, off int, v uint16) { *(*uint16)(unsafe.Pointer(&b[off])) = v }
func stI16(b []byte, off int, v int16)  { *(*int16)(unsafe.Pointer(&b[off])) = v }
func stU32(b []byte, off int, v uint32) { *(*uint32)(unsafe.Pointer(&b[off])) = v }
func stU64(b []byte, off int, v uint64) { *(*uint64)(unsafe.Pointer(&b[off])) = v }

// The externref table (IR.md §14): slots from heap_base on. A run of slots
// for an arr<T> of references is contiguous; everything else takes one.

const heapBase = 132

var (
	slotUsed []bool
	slotHint int
	slotFree []int32
)

func refAlloc(count int32) int32 {
	n := int(count)
	if n == 0 {
		return 0
	}
	if n == 1 && len(slotFree) > 0 {
		s := slotFree[len(slotFree)-1]
		slotFree = slotFree[:len(slotFree)-1]
		slotUsed[s-heapBase] = true
		return s
	}
	i := slotHint
search:
	for {
		if i+n > len(slotUsed) {
			grow := max(i+n-len(slotUsed), 64)
			tsgenTableGrow(int32(grow))
			slotUsed = append(slotUsed, make([]bool, grow)...)
		}
		for k := i; k < i+n; k++ {
			if slotUsed[k] {
				i = k + 1
				continue search
			}
		}
		break
	}
	for k := i; k < i+n; k++ {
		slotUsed[k] = true
	}
	if i == slotHint {
		slotHint = i + n
	}
	return heapBase + int32(i)
}

func refFree(base, count int32) {
	if base < heapBase || count <= 0 {
		return
	}
	tsgenRefClear(base, count)
	i := int(base - heapBase)
	for k := i; k < i+int(count); k++ {
		slotUsed[k] = false
	}
	if count == 1 && len(slotFree) < 256 {
		slotFree = append(slotFree, base)
		return
	}
	if i < slotHint {
		slotHint = i
	}
}

// A new slot holding the same value as slot.
func refDup(slot int32) int32 {
	if slot == 0 {
		return 0
	}
	s := refAlloc(1)
	tsgenRefCopy(s, slot)
	return s
}

//go:wasmexport tw:table/alloc
func twTableAlloc(n int32) int32 { return refAlloc(n) }

//go:wasmexport tw:table/free
func twTableFree(base, n int32) { refFree(base, n) }

//go:wasmexport tsgen_ref_alloc1
func tsgenRefAlloc1() int32 { return refAlloc(1) }

//go:wasmexport tsgen_ref_free1
func tsgenRefFree1(slot int32) { refFree(slot, 1) }

// JS values

// Object is a JS value held in one slot of the module's table. Every
// generated class and interface embeds it. Close releases the value now;
// otherwise it's released once the Go value is unreachable. A class whose
// JS API has its own close method shadows Close; its Object.Close still
// releases the handle.
type Object struct {
	slot    int32
	cleanup runtime.Cleanup
}

func (o *Object) object() *Object { return o }

// Close releases the JS value. The object must not be used after.
func (o *Object) Close() {
	if o != nil && o.slot != 0 {
		o.cleanup.Stop()
		refFree(o.slot, 1)
		o.slot = 0
	}
}

func (o *Object) borrow() int32 {
	if o == nil {
		return 0
	}
	return o.slot
}

// JSValue is anything that holds a JS value: every generated class and
// interface, and Value.
type JSValue interface{ object() *Object }

func freeSlot(slot int32) { refFree(slot, 1) }

// wrap makes the Go value of type T that owns slot; 0 gives nil.
func wrap[T any, PT interface {
	*T
	JSValue
}](slot int32) PT {
	if slot == 0 {
		return nil
	}
	p := PT(new(T))
	o := p.object()
	o.slot = slot
	o.cleanup = runtime.AddCleanup((*T)(p), freeSlot, slot)
	return p
}

// wrapMaybe is wrap for a slot that may hold null or undefined.
func wrapMaybe[T any, PT interface {
	*T
	JSValue
}](slot int32) PT {
	if slot != 0 && tsgenRefIsNull(slot) != 0 {
		refFree(slot, 1)
		return nil
	}
	return wrap[T, PT](slot)
}

// Cast views the JS value v holds as another generated type T, unchecked
// (IR.md §4). Both hold the value.
func Cast[T any, PT interface {
	*T
	JSValue
}](v JSValue) PT {
	if v == nil || v.object().slot == 0 {
		return nil
	}
	return wrap[T, PT](refDup(v.object().slot))
}

// Value is a JS value of no declared type.
type Value struct{ Object }

// Decode reads the JS value into dst through its JSON, mapped as
// encoding/json maps it (json.go).
func (v *Value) Decode(dst any) error {
	if v == nil || v.slot == 0 {
		return jsonUnmarshal([]byte("null"), dst)
	}
	text, err := opJSONStringify(v.slot)
	if err != nil {
		return err
	}
	if text == nil {
		return jsonUnmarshal([]byte("null"), dst)
	}
	return jsonUnmarshal([]byte(*text), dst)
}

// Decode reads a JS value as T through its JSON (json.go). A null
// value gives T's zero value.
func Decode[T any](v *Value) (T, error) {
	var out T
	err := v.Decode(&out)
	return out, err
}

// ValueOf makes a JS value of v: see the conversions anySlot makes.
func ValueOf(v any) *Value {
	slot, owned := anySlot(v)
	if !owned {
		slot = refDup(slot)
	}
	return wrap[Value](slot)
}

// anySlot converts a Go value for a parameter of type `Any` or an erased
// type parameter: nil is null; a JSValue passes its own value; strings,
// numbers and booleans are boxed; anything else crosses as its JSON
// (json.go, then JSON.parse). owned says the caller frees the slot.
func anySlot(v any) (slot int32, owned bool) {
	switch x := v.(type) {
	case nil:
		return 0, false
	case JSValue:
		return x.object().borrow(), false
	case string:
		return opBoxStr(x), true
	case bool:
		return opBoxBool(b2i(x)), true
	case float64:
		return opBoxF64(x), true
	case float32:
		return opBoxF64(float64(x)), true
	case int:
		return opBoxF64(float64(x)), true
	case int8:
		return opBoxF64(float64(x)), true
	case int16:
		return opBoxF64(float64(x)), true
	case int32:
		return opBoxF64(float64(x)), true
	case int64:
		return opBoxF64(float64(x)), true
	case uint:
		return opBoxF64(float64(x)), true
	case uint8:
		return opBoxF64(float64(x)), true
	case uint16:
		return opBoxF64(float64(x)), true
	case uint32:
		return opBoxF64(float64(x)), true
	case uint64:
		return opBoxF64(float64(x)), true
	}
	b, err := jsonMarshal(v)
	if err != nil {
		panic(errors.New("ts-gen: " + typeString(v) + " as a JS value: " + err.Error()))
	}
	s, err := opJSONParse(string(b))
	if err != nil {
		panic(err)
	}
	return s, true
}

// Handles (IR.md §14): Go values JS holds, a callback's func or an
// exported class's instance, as numbers.

var (
	handles    = map[int32]any{}
	nextHandle int32
)

func retain(v any) int32 {
	nextHandle++
	for nextHandle == 0 || handles[nextHandle] != nil {
		nextHandle++
	}
	handles[nextHandle] = v
	return nextHandle
}

func handle[T any](h int32) T { return handles[h].(T) }

func release(h int32) { delete(handles, h) }

// Errors

// Exception is a JS exception from a member that declares no error. It
// reaches Go as a panic, which an export turns back into a JS error.
type Exception struct {
	Name    string
	Message string
}

func (e *Exception) Error() string {
	if e.Name == "" {
		return e.Message
	}
	return e.Name + ": " + e.Message
}

// exception reads a caught JS exception from its slot, and frees the slot.
func exception(slot int32) *Exception {
	defer refFree(slot, 1)
	if slot == 0 || tsgenRefIsNull(slot) != 0 {
		return &Exception{Message: "null"}
	}
	name, msg := opErrName(slot), opErrMessage(slot)
	e := &Exception{Message: "unknown error"}
	if name != nil {
		e.Name = *name
	}
	if msg != nil {
		e.Message = *msg
	}
	return e
}

// fail panics with the exception a status-2 crossing left.
func fail(st int32) {
	if st == 2 {
		panic(exception(retI32(0)))
	}
	panic("ts-gen: unexpected status " + strconv.Itoa(int(st)))
}

// describe is the text of an error or a recovered panic, for the JS error
// it becomes.
func describe(r any) string {
	switch x := r.(type) {
	case error:
		return x.Error()
	case string:
		return x
	case interface{ String() string }:
		return x.String()
	}
	if b, err := jsonMarshal(r); err == nil {
		return string(b)
	}
	return typeString(r)
}

func typeString(v any) string {
	if v == nil {
		return "nil"
	}
	return reflect.TypeOf(v).String()
}

// noArm panics for a value of a union's Go interface that is none of its
// arms (a type outside the package implementing it).
func noArm(v any, union string) {
	panic("ts-gen: " + typeString(v) + " is no arm of " + union)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// Async (IR.md §16, over JSPI)

type pendingFuture struct {
	future int32
	done   chan int32
}

var (
	// entries is how many calls into the module are on the Wasm stack.
	entries int
	// syncEntries is how many of them can't suspend.
	syncEntries int
	pending     []pendingFuture
	kick        = make(chan struct{}, 1)
	pollerUp    bool
	nextWaker   int32 = 1
)

// enter and leave bracket every export and trampoline.
func enter(async bool) {
	entries++
	if !async {
		syncEntries++
	}
}

func leave(async bool) {
	entries--
	if !async {
		syncEntries--
	}
	if entries == 0 {
		// Lets released values' cleanups run.
		runtime.Gosched()
	}
}

// await blocks until the future in slot f settles: 1 resolved, 2 rejected
// (as `tw:future poll` says). The caller then takes the value or the
// error.
func await(f int32) int32 {
	if s := opPoll(f, -1); s != 0 {
		return s
	}
	if syncEntries > 0 {
		panic("ts-gen: a synchronous callback can't wait for a JS promise")
	}
	if entries > 1 {
		// Nested in another entry, whose goroutines are suspended with it:
		// wait here, on a waker of its own.
		w := nextWaker
		nextWaker++
		for {
			if s := opPoll(f, w); s != 0 {
				return s
			}
			tsgenWait(w)
		}
	}
	if !pollerUp {
		pollerUp = true
		go poller()
	}
	done := make(chan int32, 1)
	pending = append(pending, pendingFuture{f, done})
	select {
	case kick <- struct{}{}:
	default:
	}
	return <-done
}

// poller runs once every other goroutine waits: it hands each settled
// future to its goroutine, and when none has settled, suspends the module
// until one does (every pending future wakes waker 0).
func poller() {
	for {
		<-kick
		for len(pending) > 0 {
			runtime.Gosched()
			settled := false
			for i := 0; i < len(pending); {
				if s := opPoll(pending[i].future, 0); s != 0 {
					p := pending[i]
					pending = append(pending[:i], pending[i+1:]...)
					p.done <- s
					settled = true
					continue
				}
				i++
			}
			if !settled && len(pending) > 0 {
				tsgenWait(0)
			}
		}
	}
}

//go:wasmexport tw:future/wake
func twFutureWake(waker int32) {}

// slotJS is the slot a JSValue borrows; nil is null.
func slotJS(v JSValue) int32 {
	if v == nil {
		return 0
	}
	return v.object().borrow()
}

func ptrTo[T any](v T) *T { return &v }

// Str, Num and Bool are the string, number and boolean arms of the
// generated unions: workers.Str("text") where a BodyInit goes.
type (
	Str  string
	Num  float64
	Bool bool
)

// Tuples: (A, B) is Tuple2[A, B].
type Tuple2[A, B any] struct {
	V0 A
	V1 B
}

type Tuple3[A, B, C any] struct {
	V0 A
	V1 B
	V2 C
}

type Tuple4[A, B, C, D any] struct {
	V0 A
	V1 B
	V2 C
	V3 D
}

type Tuple5[A, B, C, D, E any] struct {
	V0 A
	V1 B
	V2 C
	V3 D
	V4 E
}

func _zero[T any]() (z T) { return }

// decodeAll decodes each value as T.
func decodeAll[T any](vs []*Value) ([]T, error) {
	out := make([]T, len(vs))
	for i, v := range vs {
		if err := v.Decode(&out[i]); err != nil {
			return nil, err
		}
	}
	return out, nil
}

var errNilInstance = errors.New("ts-gen: the constructor returned no instance")

// panicError is the error a panic in an export becomes.
func panicError(p any) error {
	if e, ok := p.(error); ok {
		return e
	}
	return errors.New(describe(p))
}
