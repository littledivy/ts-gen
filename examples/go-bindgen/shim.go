package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// The shim adapts the Go module to the `tw` ABI the bridge implements.
// Go can't name externref, and a Go function returns at most one value, so
// the shim (generated after the Go module is linked, for exactly the
// imports and exports it has, and merged into it):
//
//   - owns `tw:table` and its bases, and moves externrefs in and out of its
//     slots, which Go allocates (tsgen_ref_alloc1, tsgen_ref_free1);
//   - calls each import for Go, leaving its results in Go's return area and
//     returning a status: 0, 1 for the member's declared tag, 2 for any
//     other JS exception (caught with WebAssembly.JSTag, imported as
//     ("tsgen:js", "tag"));
//   - exports each of Go's exports under its key, reading extra results,
//     and a thrown error, from the return area.

func flatExport(e *ExportOp) (params []string, ret string) {
	for _, w := range e.Params {
		if w == "externref" {
			w = "i32"
		}
		params = append(params, w)
	}
	switch {
	case e.Throws != nil:
		ret = "i32"
	case len(e.Results) == 1:
		ret = e.Results[0]
		if ret == "externref" {
			ret = "i32"
		}
	}
	return
}

func watStr(s string) string {
	b, _ := json.Marshal(s)
	out := string(b)
	// WAT has no \uXXXX escape; it has \u{X}.
	var sb strings.Builder
	for i := 0; i < len(out); i++ {
		if out[i] == '\\' && i+1 < len(out) && out[i+1] == 'u' {
			sb.WriteString(`\u{` + out[i+2:i+6] + `}`)
			i += 5
			continue
		}
		sb.WriteByte(out[i])
	}
	return sb.String()
}

func shimWat(m *manifest, used, exported map[string]bool) string {
	var L []string
	type tag struct {
		id string
		t  *TagInfo
	}
	tags := map[string]*tag{}
	var tagOrder []*tag
	tagOf := func(t *TagInfo) string {
		k := t.Module + "\x00" + t.Name
		if x, ok := tags[k]; ok {
			return x.id
		}
		x := &tag{id: fmt.Sprintf("$tag%d", len(tags)), t: t}
		tags[k] = x
		tagOrder = append(tagOrder, x)
		return x.id
	}
	var imports []*ImportOp
	for _, e := range m.Imports {
		if used[e.C] {
			imports = append(imports, e)
			if e.Throws != nil {
				tagOf(e.Throws)
			}
		}
	}
	var exports []*ExportOp
	for _, e := range m.Exports {
		if exported[e.C] {
			exports = append(exports, e)
			if e.Throws != nil {
				tagOf(e.Throws)
			}
		}
	}
	L = append(L, "(module",
		`  (import "go" "tsgen_ref_alloc1" (func $alloc (result i32)))`,
		`  (import "go" "tsgen_ref_free1" (func $free (param i32)))`,
		`  (import "go" "tsgen_ret_area" (func $ret (result i32)))`,
		`  (import "go" "memory" (memory 0))`,
		`  (import "tsgen:js" "tag" (tag $js (param externref)))`)
	for _, t := range tagOrder {
		L = append(L, fmt.Sprintf("  (import %s %s (tag %s (param %s)))", watStr(t.t.Module), watStr(t.t.Name), t.id, strings.Join(t.t.Params, " ")))
	}
	sig := func(params, results []string) string {
		s := ""
		if len(params) > 0 {
			s += " (param " + strings.Join(params, " ") + ")"
		}
		if len(results) > 0 {
			s += " (result " + strings.Join(results, " ") + ")"
		}
		return s
	}
	for i, e := range imports {
		L = append(L, fmt.Sprintf("  (import %s %s (func $f%d%s))", watStr(e.Module), watStr(e.Name), i, sig(e.Params, e.Results)))
	}
	for i, e := range exports {
		ps, ret := flatExport(e)
		var rs []string
		if ret != "" {
			rs = []string{ret}
		}
		L = append(L, fmt.Sprintf("  (import \"go\" %s (func $x%d%s))", watStr(e.C), i, sig(ps, rs)))
	}
	// The table and its ranges (IR.md §14).
	L = append(L,
		`  (table $t (export "tw:table") 132 externref)`,
		`  (global (export "tw:table/stack_base") i32 (i32.const 1))`,
		`  (global (export "tw:table/const_base") i32 (i32.const 128))`,
		`  (global (export "tw:table/heap_base") i32 (i32.const 132))`,
		`  (func (export "tsgen_table_grow") (param i32) (result i32) (table.grow $t (ref.null extern) (local.get 0)))`,
		`  (func (export "tsgen_ref_clear") (param i32 i32) (table.fill $t (local.get 0) (ref.null extern) (local.get 1)))`,
		`  (func (export "tsgen_ref_copy") (param i32 i32) (table.set $t (local.get 0) (table.get $t (local.get 1))))`,
		`  (func (export "tsgen_ref_is_null") (param i32) (result i32) (ref.is_null (table.get $t (local.get 0))))`,
		// An externref into a new slot (0 for null), and back out of one.
		`  (func $stash (param $v externref) (result i32) (local $s i32)
    (if (ref.is_null (local.get $v)) (then (return (i32.const 0))))
    (local.set $s (call $alloc))
    (table.set $t (local.get $s) (local.get $v))
    (local.get $s))`,
		`  (func $take (param $s i32) (result externref) (local $v externref)
    (if (i32.eqz (local.get $s)) (then (return (ref.null extern))))
    (local.set $v (table.get $t (local.get $s)))
    (call $free (local.get $s))
    (local.get $v))`)
	store := func(w, addr string, off int, val string) string {
		if w == "externref" {
			return fmt.Sprintf("(i32.store offset=%d %s (call $stash %s))", off, addr, val)
		}
		return fmt.Sprintf("(%s.store offset=%d %s %s)", w, off, addr, val)
	}
	load := func(w, addr string, off int) string {
		if w == "externref" {
			return fmt.Sprintf("(call $take (i32.load offset=%d %s))", off, addr)
		}
		return fmt.Sprintf("(%s.load offset=%d %s)", w, off, addr)
	}
	for i, e := range imports {
		var ps, locals, args, sets, stores []string
		for k, w := range e.Params {
			if w == "externref" {
				ps = append(ps, fmt.Sprintf("(param $p%d i32)", k))
				args = append(args, fmt.Sprintf("(table.get $t (local.get $p%d))", k))
			} else {
				ps = append(ps, fmt.Sprintf("(param $p%d %s)", k, w))
				args = append(args, fmt.Sprintf("(local.get $p%d)", k))
			}
		}
		ps = append(ps, "(param $ret i32)")
		for k, w := range e.Results {
			locals = append(locals, fmt.Sprintf("(local $r%d %s)", k, w))
			sets = append([]string{fmt.Sprintf("(local.set $r%d)", k)}, sets...)
			stores = append(stores, store(w, "(local.get $ret)", k*8, fmt.Sprintf("(local.get $r%d)", k)))
		}
		locals = append(locals, "(local $x externref)")
		catches := "(catch $js $js)"
		tagBlockOpen, tagBlockClose := "", ""
		if e.Throws != nil {
			tp := e.Throws.Params
			for k, w := range tp {
				locals = append(locals, fmt.Sprintf("(local $e%d %s)", k, w))
			}
			catches = fmt.Sprintf("(catch %s $tag) (catch $js $js)", tagOf(e.Throws))
			tagBlockOpen = fmt.Sprintf("(block $tag (result %s)\n        ", strings.Join(tp, " "))
			var tsets, tstores []string
			for k := range tp {
				tsets = append([]string{fmt.Sprintf("(local.set $e%d)", k)}, tsets...)
			}
			for k, w := range tp {
				tstores = append(tstores, store(w, "(local.get $ret)", k*8, fmt.Sprintf("(local.get $e%d)", k)))
			}
			tagBlockClose = fmt.Sprintf(")\n      %s\n      %s\n      (return (i32.const 1))", strings.Join(tsets, " "), strings.Join(tstores, "\n      "))
		}
		body := fmt.Sprintf(`(block $ok
    (block $js (result externref)
      %s(try_table %s
          (call $f%d %s)
          %s
          %s
          (br $ok))%s)
    (local.set $x)
    (i32.store (local.get $ret) (call $stash (local.get $x)))
    (return (i32.const 2)))
  (i32.const 0)`, tagBlockOpen, catches, i, strings.Join(args, " "), strings.Join(sets, " "), strings.Join(stores, "\n          "), tagBlockClose)
		L = append(L, fmt.Sprintf("  (func (export %s) %s (result i32) %s\n  %s)", watStr(e.C), strings.Join(ps, " "), strings.Join(locals, " "), body))
	}
	for i, e := range exports {
		var ps, args []string
		for k, w := range e.Params {
			ps = append(ps, fmt.Sprintf("(param $p%d %s)", k, w))
			if w == "externref" {
				args = append(args, fmt.Sprintf("(call $stash (local.get $p%d))", k))
			} else {
				args = append(args, fmt.Sprintf("(local.get $p%d)", k))
			}
		}
		var loads []string
		for k, w := range e.Results {
			loads = append(loads, load(w, "(local.get $a)", k*8))
		}
		var body string
		switch {
		case e.Throws != nil:
			var tl []string
			for k, w := range e.Throws.Params {
				tl = append(tl, load(w, "(local.get $a)", k*8))
			}
			body = fmt.Sprintf(`(local $a i32)
    (if (call $x%d %s)
      (then
        (local.set $a (call $ret))
        (throw %s %s)))
    (local.set $a (call $ret))
    %s`, i, strings.Join(args, " "), tagOf(e.Throws), strings.Join(tl, " "), strings.Join(loads, " "))
		case len(e.Results) == 1 && e.Results[0] == "externref":
			body = fmt.Sprintf("(call $take (call $x%d %s))", i, strings.Join(args, " "))
		case len(e.Results) <= 1:
			body = fmt.Sprintf("(call $x%d %s)", i, strings.Join(args, " "))
		default:
			body = fmt.Sprintf("(local $a i32)\n    (call $x%d %s)\n    (local.set $a (call $ret))\n    %s", i, strings.Join(args, " "), strings.Join(loads, " "))
		}
		res := ""
		if len(e.Results) > 0 {
			res = " (result " + strings.Join(e.Results, " ") + ")"
		}
		L = append(L, fmt.Sprintf("  (func (export %s) %s%s\n    %s)", watStr(e.Name), strings.Join(ps, " "), res, body))
	}
	L = append(L, ")")
	return strings.Join(L, "\n") + "\n"
}
