package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Callbacks (IR.md §18): a Go func JS holds is a handle; JS calls it
// through its type's trampoline and drops it through tw:drop.

// setRets writes an export's results to the return area. Each value is
// computed first: boxing one calls the shim, which uses the return area too.
func setRets(wires, vals []string) []string {
	if len(vals) == 1 {
		return []string{fmt.Sprintf("%s(0, %s)", retSet[wires[0]], vals[0])}
	}
	var out []string
	for i, v := range vals {
		out = append(out, fmt.Sprintf("_rv%d := %s", i, v))
	}
	for i := range vals {
		out = append(out, fmt.Sprintf("%s(%d, _rv%d)", retSet[wires[i]], i, i))
	}
	return out
}

// jsNumber: the scalars JS holds as a number.
var jsNumber = map[string]bool{"i8": true, "u8": true, "i16": true, "u16": true, "i32": true, "u32": true, "f32": true, "f64": true}

func (g *Gen) useCallback(r *Repr) {
	if g.memberCbs != nil {
		g.memberCbs[r.Trampoline] = true
	}
	if prev, ok := g.callbacks[r.Trampoline]; ok {
		if prev == nil {
			fail("callback %s", r.Ty)
		}
		return
	}
	saved, out := g.liftCode, g.out
	g.out = nil
	g.callbacks[r.Trampoline] = nil
	defer func() {
		g.out, g.liftCode = out, saved
	}()
	g.emitCallback(r)
	g.callbacks[r.Trampoline] = r
	g.callbackCode[r.Trampoline] = g.out
}

func (g *Gen) emitCallback(r *Repr) {
	ft := g.funcType(r)
	res := g.callbackResult(r.Result)
	if r.Result != nil && r.Result.Kind == "host" && r.Result.Of == "future" && !r.Result.Nullable {
		fail("a callback returning a future")
	}
	var flat []string
	var wires []string
	g.liftCode = nil
	var args []string
	for i, p := range r.Params {
		var w []string
		for j, x := range p.Wire {
			n := fmt.Sprintf("_a%d_%d", i, j)
			flat = append(flat, n+" "+wireGo[x])
			wires = append(wires, x)
			w = append(w, n)
		}
		args = append(args, g.lift(p, w))
	}
	pre := g.liftCode
	g.liftCode = nil
	var wireResults []string
	if r.Result != nil && r.Result.Kind != "unit" {
		wireResults = r.Result.Wire
	}
	throws := tagInfo(r.FnThrows)
	x := g.exportOp(r.Trampoline, append([]string{"i32"}, wires...), wireResults, throws)
	body := []string{"enter(false)", "defer leave(false)"}
	body = append(body, pre...)
	body = append(body, fmt.Sprintf("_f := handle[%s](_env)", ft))
	call := "_f(" + strings.Join(args, ", ") + ")"
	var l lowered
	switch {
	case res == "" && len(wireResults) == 1:
		l = lowered{vals: []string{"0"}}
	case res != "":
		l = g.lowerOwned(r.Result, "_r")
	}
	lhs := ""
	switch {
	case res != "" && throws != nil:
		lhs = "_r, _err := "
	case res != "":
		lhs = "_r := "
	case throws != nil:
		lhs = "_err := "
	}
	body = append(body, lhs+call)
	ret := ""
	if throws != nil {
		ret = " int32"
		body = append(body, "if _err != nil {")
		for _, c := range g.lowerThrow(throws.enum, "_err") {
			body = append(body, "\t"+c)
		}
		body = append(body, "\treturn 1", "}")
		body = append(body, l.code...)
		body = append(body, setRets(wireResults, l.vals)...)
		body = append(body, "return 0")
	} else {
		body = append(body, l.code...)
		if len(wireResults) == 1 {
			ret = " " + wireGo[wireResults[0]]
			body = append(body, "return "+l.vals[0])
		} else {
			body = append(body, setRets(wireResults, l.vals)...)
		}
	}
	params := append([]string{"_env int32"}, flat...)
	g.out = append(g.out, fmt.Sprintf("//go:wasmexport %s\nfunc %s(%s)%s {\n\t%s\n}", x.C, x.C, strings.Join(params, ", "), ret, strings.Join(body, "\n\t")))
	d := g.exportOp("tw:drop:"+r.Ty, []string{"i32"}, nil, nil)
	g.out = append(g.out, fmt.Sprintf("//go:wasmexport %s\nfunc %s(_env int32) { release(_env) }", d.C, d.C))
}

// Exports (IR.md §17): Exports holds the app's funcs; the generated main
// glue fills it.

type exportField struct {
	name, typ string
}

func (g *Gen) emitExports() {
	var exps []*Member
	for _, m := range g.members {
		if m.Role == "export" {
			exps = append(exps, m)
		}
	}
	var fields []exportField
	type classInfo struct {
		name    string
		methods []string
	}
	var classes []*classInfo
	byClass := map[string]*classInfo{}
	for _, m := range exps {
		owner := m.owner()
		ok := g.try(m.Key, func() {
			if owner != "" {
				ci := byClass[owner]
				if ci == nil {
					ci = &classInfo{name: g.typeName(owner) + "Export"}
					byClass[owner] = ci
					classes = append(classes, ci)
				}
				f, meth := g.emitExport(m, ci.name)
				if f != nil {
					fields = append(fields, *f)
				}
				if meth != "" {
					ci.methods = append(ci.methods, meth)
				}
				return
			}
			f, _ := g.emitExport(m, "")
			fields = append(fields, *f)
		})
		_ = ok
	}
	var b strings.Builder
	for _, ci := range classes {
		fmt.Fprintf(&b, "// %s is what the app's exported class implements.\ntype %s interface {\n", ci.name, ci.name)
		for _, m := range ci.methods {
			b.WriteString("\t" + m + "\n")
		}
		b.WriteString("}\n\n")
		g.pkgNames[ci.name] = true
	}
	b.WriteString("// Exports are what the module exports, from the app: the generated main glue\n// passes them to SetExports.\ntype Exports struct {\n")
	for _, f := range fields {
		fmt.Fprintf(&b, "\t%s %s\n", f.name, f.typ)
	}
	b.WriteString("}\n\nvar exports Exports\n\n// SetExports installs the app's exports.\nfunc SetExports(e Exports) { exports = e }\n")
	g.out = append(g.out, b.String())
	g.exportFields = fields
	for owner := range byClass {
		n := strings.ReplaceAll(g.typeName(owner), ".", "_")
		x := g.exportOp("tw:drop:"+owner, []string{"i32"}, nil, nil)
		_ = n
		g.out = append(g.out, fmt.Sprintf("//go:wasmexport %s\nfunc %s(h int32) { release(h) }", x.C, x.C))
	}
}

// emitExport emits one export's wrapper. It returns the Exports field it
// calls, or the method of the class interface iface.
func (g *Gen) emitExport(m *Member, iface string) (*exportField, string) {
	sig := m.Sig
	var params []SigParam
	hasThis, hasHandle := false, false
	for _, p := range sig.Params {
		switch p.Role {
		case "param":
			params = append(params, p)
		case "this":
			hasThis = true
		case "handle":
			hasHandle = true
		}
	}
	resultR := &Repr{Kind: "unit"}
	if len(sig.Results) > 0 {
		resultR = sig.Results[0].Repr
	}
	isFuture := resultR.Kind == "host" && resultR.Of == "future"
	valueR := resultR
	if isFuture {
		valueR = resultR.Value
	}
	var throwL *EnumLayout
	var throws *TagInfo
	if sig.Throws != nil {
		throwL = sig.Throws.Enum
		throws = tagInfo(sig.Throws)
	} else if isFuture {
		throwL = resultR.Rejection
		throws = &TagInfo{Module: "tw:tag", Name: throwL.Path, Params: append([]string{"i32"}, throwL.Shape.Slots...), enum: throwL}
	}
	if throwL != nil {
		g.errorType(throwL)
	}
	isCtor := m.Kind == "new"
	var flat []string
	var pre []string
	if hasThis {
		flat = append(flat, "_this int32")
		pre = append(pre, "refFree(_this, 1)")
	}
	if hasHandle {
		flat = append(flat, "_h int32")
	}
	g.liftCode = nil
	var args, ptypes []string
	for i, p := range params {
		var w []string
		for j, x := range p.Repr.Wire {
			n := fmt.Sprintf("_p%d_%d", i, j)
			flat = append(flat, n+" "+wireGo[x])
			w = append(w, n)
		}
		args = append(args, g.lift(p.Repr, w))
		ptypes = append(ptypes, g.goType(p.Repr, false))
	}
	pre = append(pre, g.liftCode...)
	g.liftCode = nil
	resT := ""
	if !isCtor {
		resT = g.goType(valueR, true)
	}
	fallible := throwL != nil
	results := ""
	switch {
	case isCtor:
		results = " (" + iface + ", error)"
	case fallible && resT != "":
		results = " (" + resT + ", error)"
	case fallible:
		results = " error"
	case resT != "":
		results = " " + resT
	}
	var field *exportField
	method := ""
	var target string
	ns := ""
	if len(m.Namespace) > 0 && m.Namespace[0] != "default" {
		ns = exported(strings.Join(m.Namespace, "_"))
	}
	switch {
	case isCtor:
		field = &exportField{name: "New" + g.typeName(m.owner()), typ: "func(" + strings.Join(ptypes, ", ") + ")" + results}
		target = "exports." + field.name
	case iface != "":
		mname := exported(m.Variant)
		switch m.Kind {
		case "get":
			mname = exported(m.Name)
		case "set":
			mname = "Set" + exported(m.Name)
		}
		method = mname + "(" + strings.Join(ptypes, ", ") + ")" + results
		target = fmt.Sprintf("handle[%s](_h).%s", iface, mname)
	default:
		field = &exportField{name: ns + exported(m.Variant), typ: "func(" + strings.Join(ptypes, ", ") + ")" + results}
		target = "exports." + field.name
	}
	var wireResults []string
	switch {
	case isCtor:
		wireResults = []string{"i32"}
	case isFuture:
		wireResults = resultR.Wire
	default:
		wireResults = sig.Core.Results
	}
	x := g.exportOp(m.Key, sig.Core.Params, wireResults, throws)
	x.Async = isFuture
	x.Owner = m.owner()
	x.Member = m.Name
	x.Kind = m.Kind
	// The result as wire values.
	var l lowered
	switch {
	case isCtor:
		l = lowered{vals: []string{"retain(_r)"}}
	case valueR.Kind == "unit":
		if isFuture {
			l = lowered{vals: []string{"0"}}
		}
	case isFuture && (isHostRef(valueR) && !g.isDict(valueR.Path) || valueR.Kind == "host" && valueR.Of != "box"):
		l = lowered{vals: []string{"refDup(slotJS(_r))"}}
	case isFuture && valueR.Kind == "str" && !valueR.Nullable:
		l = lowered{vals: []string{"opBoxStr(_r)"}}
	case isFuture && valueR.Kind == "scalar" && !valueR.Nullable && jsNumber[valueR.Scalar]:
		// A JS number, boxed.
		l = lowered{vals: []string{"opBoxF64(float64(_r))"}}
	case isFuture && valueR.Kind == "scalar" && !valueR.Nullable && valueR.Scalar == "bool":
		l = lowered{vals: []string{"opBoxBool(b2i(_r))"}}
	case isFuture && (valueR.Kind == "erased" || valueR.Kind == "host" && valueR.Of == "any"):
		l = lowered{code: []string{"_o, _own := anySlot(_r)", "if !_own { _o = refDup(_o) }"}, vals: []string{"_o"}}
	case isFuture:
		fail("an export returning future<%s>", valueR.Ty)
	default:
		l = g.lowerOwned(valueR, "_r")
	}
	async := "false"
	if isFuture {
		async = "true"
	}
	body := []string{"enter(" + async + ")", "defer leave(" + async + ")"}
	call := target + "(" + strings.Join(args, ", ") + ")"
	hasR := isCtor || resT != ""
	var decl []string
	if hasR {
		rt := resT
		if isCtor {
			rt = iface
		}
		decl = append(decl, "var _r "+rt)
	}
	if fallible || isCtor {
		decl = append(decl, "var _err error")
	}
	body = append(body, decl...)
	inner := append([]string{}, pre...)
	switch {
	case hasR && (fallible || isCtor):
		inner = append(inner, "_r, _err = "+call)
	case hasR:
		inner = append(inner, "_r = "+call)
	case fallible:
		inner = append(inner, "_err = "+call)
	default:
		inner = append(inner, call)
	}
	if throws != nil {
		body = append(body, "func() {", "\tdefer func() {", "\t\tif p := recover(); p != nil {", "\t\t\t_err = panicError(p)", "\t\t}", "\t}()")
		for _, c := range inner {
			body = append(body, "\t"+c)
		}
		body = append(body, "}()")
		if isCtor {
			body = append(body, "if _err == nil && _r == nil { _err = errNilInstance }")
		}
		body = append(body, "if _err != nil {")
		for _, c := range g.lowerThrow(throwL, "_err") {
			body = append(body, "\t"+c)
		}
		body = append(body, "\treturn 1", "}")
		body = append(body, l.code...)
		body = append(body, setRets(wireResults, l.vals)...)
		body = append(body, l.post...)
		body = append(body, "return 0")
	} else {
		body = append(body, inner...)
		if isCtor {
			body = append(body, "if _err != nil { panic(_err) }")
		}
		body = append(body, l.code...)
		if len(wireResults) == 1 {
			body = append(body, "return "+l.vals[0])
		} else {
			body = append(body, setRets(wireResults, l.vals)...)
		}
	}
	ret := ""
	if throws != nil {
		ret = " int32"
	} else if len(wireResults) == 1 {
		ret = " " + wireGo[wireResults[0]]
	}
	g.out = append(g.out, fmt.Sprintf("// %s exports `%s`.\n//\n//go:wasmexport %s\nfunc %s(%s)%s {\n\t%s\n}", x.C, m.Key, x.C, x.C, strings.Join(flat, ", "), ret, strings.Join(body, "\n\t")))
	return field, method
}

// The protocol operations the runtime calls (IR.md §13, §16), and the
// runtime IR's members (runtime.ir).

func (g *Gen) emitOps() {
	var b strings.Builder
	boxStr := g.importOp("tw:box", "str", []string{"i32", "i32"}, []string{"externref"}, nil)
	boxF64 := g.importOp("tw:box", "f64", []string{"f64"}, []string{"externref"}, nil)
	boxBool := g.importOp("tw:box", "bool", []string{"i32"}, []string{"externref"}, nil)
	poll := g.importOp("tw:future", "poll", []string{"externref", "i32"}, []string{"i32"}, nil)
	fmt.Fprintf(&b, "func opBoxStr(s string) int32 {\n\t_st := %s(strPtr(s), int32(len(s)), retPtr())\n\truntime.KeepAlive(s)\n\tif _st != 0 { fail(_st) }\n\treturn retI32(0)\n}\n\n", boxStr.C)
	fmt.Fprintf(&b, "func opBoxF64(v float64) int32 {\n\tif _st := %s(v, retPtr()); _st != 0 { fail(_st) }\n\treturn retI32(0)\n}\n\n", boxF64.C)
	fmt.Fprintf(&b, "func opBoxBool(v int32) int32 {\n\tif _st := %s(v, retPtr()); _st != 0 { fail(_st) }\n\treturn retI32(0)\n}\n\n", boxBool.C)
	fmt.Fprintf(&b, "func opPoll(f, waker int32) int32 {\n\tif _st := %s(f, waker, retPtr()); _st != 0 { fail(_st) }\n\treturn retI32(0)\n}\n\n", poll.C)
	find := func(key string) *Member {
		for _, m := range g.members {
			if m.Key == key {
				return m
			}
		}
		return nil
	}
	if m := find("TsgenJSON.stringify(Any?)"); m != nil {
		op := g.importOp(moduleOf(m), m.Key, m.Sig.Core.Params, m.Sig.Core.Results, tagInfo(m.Sig.Throws))
		g.liftCode = nil
		e := g.liftThrow(m.Sig.Throws.Enum, op.Throws.Params)
		fmt.Fprintf(&b, "func opJSONStringify(slot int32) (*string, error) {\n\t_st := %s(slot, retPtr())\n\tif _st == 1 {\n\t\t%s\n\t\treturn nil, %s\n\t}\n\tif _st != 0 { return nil, exception(retI32(0)) }\n\treturn takeOptString(retI32(0), retI32(1)), nil\n}\n\n", op.C, strings.Join(g.liftCode, "\n\t\t"), e)
	} else {
		b.WriteString("func opJSONStringify(slot int32) (*string, error) { panic(\"ts-gen: the IR lacks go-bindgen's runtime.ir\") }\n\n")
	}
	if m := find("TsgenJSON.parse(str)"); m != nil {
		op := g.importOp(moduleOf(m), m.Key, m.Sig.Core.Params, m.Sig.Core.Results, tagInfo(m.Sig.Throws))
		g.liftCode = nil
		e := g.liftThrow(m.Sig.Throws.Enum, op.Throws.Params)
		fmt.Fprintf(&b, "func opJSONParse(text string) (int32, error) {\n\t_st := %s(strPtr(text), int32(len(text)), retPtr())\n\truntime.KeepAlive(text)\n\tif _st == 1 {\n\t\t%s\n\t\treturn 0, %s\n\t}\n\tif _st != 0 { return 0, exception(retI32(0)) }\n\treturn retI32(0), nil\n}\n\n", op.C, strings.Join(g.liftCode, "\n\t\t"), e)
	} else {
		b.WriteString("func opJSONParse(text string) (int32, error) { panic(\"ts-gen: the IR lacks go-bindgen's runtime.ir\") }\n\n")
	}
	for _, p := range []struct{ fn, key string }{{"opErrName", "TsgenError#get:name()"}, {"opErrMessage", "TsgenError#get:message()"}} {
		if m := find(p.key); m != nil {
			op := g.importOp(moduleOf(m), m.Key, m.Sig.Core.Params, m.Sig.Core.Results, nil)
			// A getter that throws reads as none: this runs while reporting
			// an exception.
			fmt.Fprintf(&b, "func %s(slot int32) *string {\n\tif %s(slot, retPtr()) != 0 { return nil }\n\treturn takeOptString(retI32(0), retI32(1))\n}\n\n", p.fn, op.C)
		} else {
			fmt.Fprintf(&b, "func %s(slot int32) *string { return nil }\n\n", p.fn)
		}
	}
	g.g_ops = b.String()
	g.liftCode = nil
}

// Output

func (g *Gen) emitAll() {
	g.aliases = map[string]bool{}
	// Names first, in a stable order, so a collision always resolves the
	// same way.
	paths := sortedKeys(g.selected)
	for _, p := range paths {
		if g.decls[p].Kind == "enum" || g.isClassLike(p) || g.isDict(p) {
			g.typeName(p)
		}
	}
	var classes, dicts []string
	for _, p := range paths {
		if strings.HasPrefix(p, "Tsgen") {
			continue
		}
		if g.isClassLike(p) {
			classes = append(classes, p)
		} else if g.isDict(p) {
			dicts = append(dicts, p)
		}
	}
	// Parents first, so the alias each child embeds exists.
	var order []string
	seen := map[string]bool{}
	var visit func(p string)
	visit = func(p string) {
		if seen[p] {
			return
		}
		seen[p] = true
		if q := g.primaryParent(p); q != "" {
			visit(q)
		}
		order = append(order, p)
	}
	for _, p := range classes {
		visit(p)
	}
	for _, p := range order {
		g.emitClass(p)
	}
	for _, p := range dicts {
		g.emitDict(p)
	}
	g.emitGlobals()
	g.emitGenerics()
	g.emitExports()
	g.emitOps()
	if g.keepCallbacksFor != nil {
		g.keepCallbacks = map[string]bool{}
		for _, e := range g.importSeq {
			if g.keepCallbacksFor[e.C] {
				for _, cb := range e.Callbacks {
					g.keepCallbacks[cb] = true
				}
			}
		}
	}
	// Enums, including those the others pulled in.
	for _, p := range paths {
		if d := g.decls[p]; d.Kind == "enum" && d.Layout != nil {
			g.useEnum(d.Layout)
		}
	}
	done := map[string]bool{}
	for {
		more := false
		for _, p := range append([]string{}, g.enumOrder...) {
			if done[p] {
				continue
			}
			done[p] = true
			more = true
			L := g.enumsUsed[p]
			if g.errorEnums[p] != nil {
				continue
			}
			saved := g.out
			g.out = nil
			g.try("enum "+p, func() { g.emitEnum(L) })
			g.out = append(saved, g.out...)
		}
		if !more {
			break
		}
	}
	for _, p := range sortedKeys(g.errorEnums) {
		g.emitErrorEnum(g.errorEnums[p])
	}
}

func (g *Gen) keptCallbacks() []string {
	var out []string
	for _, t := range sortedKeys(g.callbackCode) {
		if g.keepCallbacks == nil || g.keepCallbacks[t] {
			out = append(out, t)
		}
	}
	return out
}

func (g *Gen) goSource() string {
	var b strings.Builder
	fmt.Fprintf(&b, "// Code generated by go-bindgen. DO NOT EDIT.\n\npackage %s\n\nimport (\n\t\"errors\"\n\t\"runtime\"\n)\n\nvar (\n\t_ = errors.As\n\t_ = runtime.KeepAlive\n)\n\n", g.pkg)
	for _, e := range g.importSeq {
		var ps []string
		for i, w := range e.Params {
			ps = append(ps, fmt.Sprintf("p%d %s", i, wireGo[w]))
		}
		ps = append(ps, "ret int32")
		fmt.Fprintf(&b, "//go:wasmimport shim %s\nfunc %s(%s) int32\n\n", e.C, e.C, strings.Join(ps, ", "))
	}
	parts := append([]string{}, g.enumDecls...)
	parts = append(parts, g.out...)
	for _, t := range g.keptCallbacks() {
		parts = append(parts, g.callbackCode[t]...)
	}
	parts = append(parts, g.g_ops)
	for _, p := range parts {
		b.WriteString(p)
		b.WriteString("\n\n")
	}
	return b.String()
}

type manifest struct {
	Imports []*ImportOp `json:"imports"`
	Exports []*ExportOp `json:"exports"`
	Skipped []Skip      `json:"skipped"`
}

func (g *Gen) manifest() []byte {
	kept := map[string]bool{}
	for _, t := range g.keptCallbacks() {
		kept[t] = true
	}
	m := manifest{Imports: g.importSeq, Skipped: g.skipped}
	for _, e := range g.exports {
		name := e.Name
		if strings.HasPrefix(name, "tw:drop:") {
			// A callback type's drop goes with its trampoline.
			if t := "tw:call:" + strings.TrimPrefix(name, "tw:drop:"); g.callbackCode[t] != nil && !kept[t] {
				continue
			}
		}
		if g.callbackCode[name] != nil && !kept[name] {
			continue
		}
		m.Exports = append(m.Exports, e)
	}
	if m.Skipped == nil {
		m.Skipped = []Skip{}
	}
	sort.SliceStable(m.Skipped, func(i, j int) bool { return m.Skipped[i].Key < m.Skipped[j].Key })
	b, _ := json.MarshalIndent(m, "", " ")
	return b
}

// mainGlue is the package-main file passing the app's funcs and types to
// SetExports.
func (g *Gen) mainGlue(importPath string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "// Code generated by go-bindgen. DO NOT EDIT.\n\npackage main\n\nimport %s %s\n\nfunc init() {\n\t%s.SetExports(%s.Exports{\n", g.pkg, goString(importPath), g.pkg, g.pkg)
	for _, f := range g.exportFields {
		if strings.HasPrefix(f.name, "New") && strings.Contains(f.typ, "Export, error)") {
			cls := strings.TrimPrefix(f.name, "New")
			sig := strings.TrimPrefix(f.typ, "func")
			sig = qualify(sig, g.pkg)
			params := strings.TrimSuffix(strings.SplitN(sig, ") (", 2)[0], "")
			params = strings.TrimPrefix(params, "(")
			var names, decls []string
			for i, t := range splitParams(params) {
				names = append(names, fmt.Sprintf("a%d", i))
				decls = append(decls, fmt.Sprintf("a%d %s", i, t))
			}
			fmt.Fprintf(&b, "\t\t%s: func(%s) (%s.%sExport, error) {\n\t\t\tv, err := New%s(%s)\n\t\t\tif err != nil {\n\t\t\t\treturn nil, err\n\t\t\t}\n\t\t\treturn v, nil\n\t\t},\n", f.name, strings.Join(decls, ", "), g.pkg, cls, cls, strings.Join(names, ", "))
			continue
		}
		fmt.Fprintf(&b, "\t\t%s: %s,\n", f.name, f.name)
	}
	// A reactor (-buildmode=c-shared) still links main.main; the host calls
	// _initialize, never _start.
	b.WriteString("\t})\n}\n\nfunc main() {}\n")
	return b.String()
}

func splitParams(s string) []string {
	var out []string
	depth, start := 0, 0
	for i, c := range s {
		switch c {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, strings.TrimSpace(s[start:i]))
				start = i + 1
			}
		}
	}
	if t := strings.TrimSpace(s[start:]); t != "" {
		out = append(out, t)
	}
	return out
}

// qualify prefixes the package's exported type names in a Go type with pkg.
func qualify(t, pkg string) string {
	var b strings.Builder
	i := 0
	for i < len(t) {
		c := t[i]
		if c >= 'A' && c <= 'Z' && (i == 0 || !isIdentByte(t[i-1])) {
			j := i
			for j < len(t) && isIdentByte(t[j]) {
				j++
			}
			b.WriteString(pkg + "." + t[i:j])
			i = j
			continue
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}

func isIdentByte(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.'
}
