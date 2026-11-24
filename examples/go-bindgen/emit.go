package main

import (
	"fmt"
	"sort"
	"strings"
)

type param struct {
	name   string
	typ    string
	repr   *Repr
	spread bool
}

// memberCode is one imported member as Go: its parameters, results and
// body, over the receiver x (when it has one).
type memberCode struct {
	params   []param
	resT     string // "" for none
	fallible bool   // returns an error last
	body     []string
	isFuture bool
	static   bool
	valueR   *Repr
}

func (mc *memberCode) results() string {
	switch {
	case mc.fallible && mc.resT != "":
		return " (" + mc.resT + ", error)"
	case mc.fallible:
		return " error"
	case mc.resT != "":
		return " " + mc.resT
	}
	return ""
}

func (mc *memberCode) paramList() string {
	var ps []string
	for _, p := range mc.params {
		t := p.typ
		if p.spread {
			t = "..." + strings.TrimPrefix(t, "[]")
		}
		ps = append(ps, p.name+" "+t)
	}
	return strings.Join(ps, ", ")
}

func zeroOf(t string) string {
	switch {
	case t == "":
		return ""
	case t == "string":
		return `""`
	case t == "bool":
		return "false"
	case strings.HasPrefix(t, "*") || strings.HasPrefix(t, "[]") || strings.HasPrefix(t, "func(") || t == "any" || t == "JSValue":
		return "nil"
	case scalarIsNum(t):
		return "0"
	}
	return "_zero[" + t + "]()"
}

func scalarIsNum(t string) bool {
	switch t {
	case "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "float32", "float64", "byte":
		return true
	}
	return false
}

// genMember generates an imported member's call. this is the receiver's
// slot expression.
func (g *Gen) genMember(m *Member, this string) *memberCode {
	sig := m.Sig
	var thisP *SigParam
	var params []SigParam
	for i := range sig.Params {
		p := sig.Params[i]
		if p.Role == "this" {
			thisP = &sig.Params[i]
		} else if p.Role == "param" {
			params = append(params, p)
		}
	}
	resultR := &Repr{Kind: "unit"}
	if len(sig.Results) > 0 {
		resultR = sig.Results[0].Repr
	}
	throws := tagInfo(sig.Throws)
	isFuture := resultR.Kind == "host" && resultR.Of == "future"
	valueR := resultR
	if isFuture {
		valueR = resultR.Value
	}
	g.memberCbs = map[string]bool{}
	mc := &memberCode{isFuture: isFuture, static: thisP == nil, valueR: valueR, fallible: isFuture || throws != nil}
	seen := map[string]bool{"x": true}
	for i, p := range params {
		meta := ParamMeta{Name: fmt.Sprintf("p%d", i)}
		if p.Index < len(m.Params) {
			meta = m.Params[p.Index]
		}
		name := local(meta.Name)
		for seen[name] {
			name += "_"
		}
		seen[name] = true
		var typ string
		spread := meta.Spread && p.Repr.Kind == "array" && i == len(params)-1
		typ = g.goType(p.Repr, true)
		mc.params = append(mc.params, param{name: name, typ: typ, repr: p.Repr, spread: spread})
	}
	if throws != nil {
		g.errorType(throws.enum)
	}
	if isFuture {
		g.errorType(resultR.Rejection)
	}
	mc.resT = g.goType(valueR, false)

	var code, post, args []string
	if thisP != nil {
		args = append(args, this)
	}
	for _, p := range mc.params {
		l := g.lower(p.repr, p.name)
		code = append(code, l.code...)
		args = append(args, l.vals...)
		post = append(post, l.post...)
	}
	module := "tw:js/global"
	if m.Module != nil {
		module = *m.Module
	}
	op := g.importOp(module, m.Key, sig.Core.Params, sig.Core.Results, throws)
	for cb := range g.memberCbs {
		if !contains(op.Callbacks, cb) {
			op.Callbacks = append(op.Callbacks, cb)
		}
	}
	sort.Strings(op.Callbacks)
	args = append(args, "retPtr()")
	body := append([]string{}, code...)
	body = append(body, fmt.Sprintf("_st := %s(%s)", op.C, strings.Join(args, ", ")))
	results := sig.Core.Results
	// Every wire value is read out of the return area before anything else
	// can reuse it.
	readVals := func(ws []string) []string {
		var out []string
		for i, w := range ws {
			v := fmt.Sprintf("_r%d", g.tmpID())
			body = append(body, fmt.Sprintf("%s := %s(%d)", v, retRead[w], i))
			out = append(out, v)
		}
		return out
	}
	zero := zeroOf(mc.resT)
	ret := func(vals ...string) string {
		var parts []string
		if mc.resT != "" {
			parts = append(parts, vals[0])
		}
		if mc.fallible {
			parts = append(parts, vals[len(vals)-1])
		}
		return "return " + strings.Join(parts, ", ")
	}
	if throws != nil {
		body = append(body, "if _st == 1 {")
		g.liftCode = nil
		e := g.liftThrow(throws.enum, throws.Params)
		for _, l := range g.liftCode {
			body = append(body, "\t"+l)
		}
		body = append(body, "\t"+strings.Join(post, "; "), "\t"+ret(zero, e), "}")
		body = append(body, "if _st == 2 {", "\t"+strings.Join(post, "; "), "\t"+ret(zero, "exception(retI32(0))"), "}")
		body = append(body, "if _st != 0 { fail(_st) }")
	} else {
		body = append(body, "if _st != 0 { fail(_st) }")
	}
	var wireVals []string
	if !isFuture {
		wireVals = readVals(results)
	} else {
		wireVals = readVals(results)
	}
	body = append(body, post...)
	if thisP != nil {
		body = append(body, "runtime.KeepAlive(x)")
	}
	g.liftCode = nil
	var resultExpr string
	if isFuture {
		f := wireVals[0]
		body = append(body, fmt.Sprintf("if await(%s) == 2 {", f))
		errOp := g.importOp(resultR.ErrorOp.Module, resultR.ErrorOp.Name, []string{"externref"}, append([]string{"i32"}, resultR.Rejection.Shape.Slots...), nil)
		body = append(body, fmt.Sprintf("\tif _st := %s(%s, retPtr()); _st != 0 { refFree(%s, 1); fail(_st) }", errOp.C, f, f))
		e := g.liftThrow(resultR.Rejection, append([]string{"i32"}, resultR.Rejection.Shape.Slots...))
		for _, l := range g.liftCode {
			body = append(body, "\t"+l)
		}
		g.liftCode = nil
		body = append(body, fmt.Sprintf("\trefFree(%s, 1)", f), "\t"+ret(zero, e), "}")
		vw := valueR.Wire
		takeOp := g.importOp(resultR.Take.Module, resultR.Take.Name, []string{"externref"}, vw, nil)
		body = append(body, fmt.Sprintf("_st = %s(%s, retPtr())", takeOp.C, f), fmt.Sprintf("refFree(%s, 1)", f), "if _st != 0 { fail(_st) }")
		vals := readVals(vw)
		resultExpr = g.lift(valueR, vals)
	} else if len(results) > 0 {
		resultExpr = g.lift(valueR, wireVals)
	}
	body = append(body, g.liftCode...)
	g.liftCode = nil
	if mc.resT != "" {
		body = append(body, ret(resultExpr, "nil"))
	} else if mc.fallible {
		body = append(body, "return nil")
	}
	mc.body = body
	return mc
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// Errors: an enum in `throws`, or a future's rejection, is an error type.

func (g *Gen) errorType(L *EnumLayout) string {
	if _, ok := g.errorEnums[L.Path]; !ok {
		g.errorEnums[L.Path] = L
	}
	return g.typeName(L.Path)
}

// liftThrow reads the error enum from the return area (the wire types ws)
// into an error expression.
func (g *Gen) liftThrow(L *EnumLayout, ws []string) string {
	name := g.errorType(L)
	id := g.tmpID()
	v := fmt.Sprintf("_err%d", id)
	var vals []string
	for i, w := range ws {
		x := fmt.Sprintf("_t%d_%d", id, i)
		g.liftCode = append(g.liftCode, fmt.Sprintf("%s := %s(%d)", x, retRead[w], i))
		vals = append(vals, x)
	}
	g.liftCode = append(g.liftCode, fmt.Sprintf("%s := &%s{Kind: %sKind(%s)}", v, name, name, vals[0]))
	// Every arm carries at most a Str message, in the one slot.
	if len(vals) > 1 {
		op := g.importOp("tw:unbox", "str", []string{"externref"}, []string{"i32", "i32"}, nil)
		g.liftCode = append(g.liftCode, fmt.Sprintf("if %s != 0 { if %s(%s, retPtr()) == 0 { %s.Message = takeString(retI32(0), retI32(1)) }; refFree(%s, 1) }", vals[1], op.C, vals[1], v, vals[1]))
	}
	return v
}

func (g *Gen) emitErrorEnum(L *EnumLayout) {
	name := g.typeName(L.Path)
	var b strings.Builder
	fmt.Fprintf(&b, "// %s is the error `%s`: Kind says which arm, Message is the JS error's.\n// Find it with errors.As.\n", name, L.Path)
	fmt.Fprintf(&b, "type %s struct {\n\tKind    %sKind\n\tMessage string\n}\n\n", name, name)
	fmt.Fprintf(&b, "func (e *%s) Error() string { return e.Kind.String() + \": \" + e.Message }\n\n", name)
	fmt.Fprintf(&b, "// %sKind is an arm of `%s`.\ntype %sKind int32\n\nconst (\n", name, L.Path, name)
	for _, a := range L.Arms {
		fmt.Fprintf(&b, "\t%s%s %sKind = %d\n", name, exported(a.Name), name, a.Index)
	}
	b.WriteString(")\n\n")
	fmt.Fprintf(&b, "func (k %sKind) String() string {\n\tswitch k {\n", name)
	for _, a := range L.Arms {
		fmt.Fprintf(&b, "\tcase %d:\n\t\treturn %s\n", a.Index, goString(a.Name))
	}
	fmt.Fprintf(&b, "\t}\n\treturn \"%s(\" + itoa(int64(k)) + \")\"\n}\n", name)
	g.enumDecls = append(g.enumDecls, b.String())
}

// lowerThrow writes an error returned by Go code into the return area as
// L's wire values: its own arm when it is an L (errors.As), else the
// fallback arm with the error's text.
func (g *Gen) lowerThrow(L *EnumLayout, e string) []string {
	name := g.errorType(L)
	fb := L.Arms[len(L.Arms)-1]
	for _, a := range L.Arms {
		if a.Fallback {
			fb = a
		}
	}
	code := []string{
		fmt.Sprintf("_ek, _em := int32(%d), describe(%s)", fb.Index, e),
		fmt.Sprintf("var _te *%s", name),
		fmt.Sprintf("if errors.As(%s, &_te) { _ek, _em = int32(_te.Kind), _te.Message }", e),
	}
	if len(L.Shape.Slots) > 0 {
		// Boxed before the arm is written: the box is a shim call, which
		// leaves its result in the return area.
		return append(code, "_eb := opBoxStr(_em)", "setRetI32(0, _ek)", "setRetI32(1, _eb)")
	}
	return append(code, "setRetI32(0, _ek)")
}

// Enums used as values.

func (g *Gen) emitEnum(L *EnumLayout) {
	name := g.typeName(L.Path)
	var b strings.Builder
	switch L.Shape.Kind {
	case "index", "carrier":
		t := "int32"
		if L.Shape.Kind == "carrier" {
			t = scalarGo[L.Shape.Scalar]
			if t == "" {
				t = "int32"
			}
		}
		fmt.Fprintf(&b, "// %s is `%s`.", name, L.Path)
		if L.Shape.Kind == "index" {
			b.WriteString(" Its zero value is none.")
		}
		fmt.Fprintf(&b, "\ntype %s %s\n\nconst (\n", name, t)
		seen := map[string]bool{}
		for _, a := range L.Arms {
			c := name + exported(a.Name)
			for seen[c] || g.pkgNames[c] {
				c += "_"
			}
			seen[c] = true
			g.pkgNames[c] = true
			lit := ""
			if len(a.Literal) > 0 && string(a.Literal) != "null" {
				lit = " // " + string(a.Literal)
			}
			fmt.Fprintf(&b, "\t%s %s = %d%s\n", c, name, a.Index, lit)
		}
		b.WriteString(")\n")
	default:
		marker := "is" + name
		fmt.Fprintf(&b, "// %s is the union `%s`; its arms are ", name, L.Path)
		var arms []string
		for _, a := range L.Arms {
			t, _ := g.unionArm(L, a)
			arms = append(arms, t)
		}
		b.WriteString(strings.Join(arms, ", ") + ".\n")
		fmt.Fprintf(&b, "type %s interface{ %s() }\n", name, marker)
		for _, a := range L.Arms {
			t, field := g.unionArm(L, a)
			if field != "" || len(a.Payload) == 0 {
				switch {
				case len(a.Payload) == 0:
					fmt.Fprintf(&b, "\n// %s is the arm %s of %s.\ntype %s struct{}\n", t, a.Name, name, t)
				case len(a.Payload) == 1:
					fmt.Fprintf(&b, "\n// %s is the arm %s of %s.\ntype %s struct{ V %s }\n", t, a.Name, name, t, g.goType(a.Payload[0], false))
				default:
					var fs []string
					for i, p := range a.Payload {
						fs = append(fs, fmt.Sprintf("V%d %s", i, g.goType(p, false)))
					}
					fmt.Fprintf(&b, "\n// %s is the arm %s of %s.\ntype %s struct{ %s }\n", t, a.Name, name, t, strings.Join(fs, "; "))
				}
			}
			recv := t
			fmt.Fprintf(&b, "\nfunc (%s) %s() {}\n", recv, marker)
		}
	}
	g.enumDecls = append(g.enumDecls, b.String())
}

// Classes

func (g *Gen) emitClass(path string) {
	d := g.decls[path]
	name := g.typeName(path)
	parent := g.primaryParent(path)
	var b strings.Builder
	doc := fmt.Sprintf("// %s is `%s`.\n", name, path)
	if d.Doc != nil {
		doc = docComment(name, d.Doc, "")
	}
	b.WriteString(doc)
	if parent != "" {
		alias := "base" + g.typeName(parent)
		if !g.aliases[alias] {
			g.aliases[alias] = true
			g.out = append(g.out, fmt.Sprintf("type %s = %s", alias, g.typeName(parent)))
		}
		fmt.Fprintf(&b, "type %s struct{ %s }\n", name, alias)
	} else {
		fmt.Fprintf(&b, "type %s struct{ Object }\n", name)
	}
	fmt.Fprintf(&b, "\nfunc (x *%s) object() *Object {\n\tif x == nil {\n\t\treturn nil\n\t}\n\treturn &x.Object\n}\n", name)
	fmt.Fprintf(&b, "\n// As%s is x as a %s, for a subtype's value.\nfunc (x *%s) As%s() *%s { return x }\n", name, name, name, name, name)
	g.out = append(g.out, b.String())
	// Members of the other parents (and their ancestors) are copied in.
	owners := []string{path}
	var extra func(p string)
	extra = func(p string) {
		for _, e := range g.decls[p].Extends {
			q := stripArgs(e)
			if _, ok := g.decls[q]; !ok || contains(owners, q) {
				continue
			}
			if q == g.primaryParent(p) && p == path {
				continue
			}
			if g.isClassLike(q) && contains(g.ancestors(path), q) {
				continue
			}
			owners = append(owners, q)
			extra(q)
		}
	}
	extra(path)
	taken := map[string]bool{"Close": false, "object": true, "As" + name: true}
	for _, o := range owners {
		for _, m := range g.byOwner[o] {
			if m.Role != "import" {
				continue
			}
			g.emitMember(m, name, taken)
		}
	}
}

// emitMember emits one member of class cls (or a global when cls is "").
func (g *Gen) emitMember(m *Member, cls string, taken map[string]bool) {
	isStatic := m.Static || m.Kind == "new" || cls == "" || g.inNamespace
	var goName string
	switch m.Kind {
	case "new":
		v := strings.TrimPrefix(m.Variant, "new")
		goName = "New" + cls + exported(v)
		if v == "" {
			goName = "New" + cls
		}
	case "get":
		goName = exported(m.Name)
	case "set":
		goName = "Set" + exported(m.Name)
	default:
		goName = exported(m.Variant)
	}
	if isStatic && m.Kind != "new" && cls != "" {
		goName = cls + goName
	}
	if isStatic {
		if m.Kind == "get" && cls == "" && g.pkgNames[goName] {
			goName = "Global" + goName
		}
		goName = g.funcName(goName)
	} else {
		if taken[goName] {
			return
		}
		taken[goName] = true
	}
	var mc *memberCode
	ok := g.try(m.Key, func() { mc = g.genMember(m, "x.object().borrow()") })
	if !ok {
		if isStatic {
			delete(g.pkgNames, goName)
		}
		return
	}
	g.emitted++
	doc := docComment(goName, m.Doc, "")
	if doc == "" {
		doc = fmt.Sprintf("// %s is `%s`.\n", goName, m.Key)
	}
	recv := ""
	if !isStatic {
		recv = "(x *" + cls + ") "
	}
	g.out = append(g.out, fmt.Sprintf("%sfunc %s%s(%s)%s {\n\t%s\n}", doc, recv, goName, mc.paramList(), mc.results(), strings.Join(mc.body, "\n\t")))
	// A result of an erased type parameter also comes decoded.
	if dec := g.decodeOf(mc.valueR); dec != nil && mc.resT != "" && m.Kind != "new" {
		g.generics = append(g.generics, &genericFn{name: exported(m.Variant), cls: cls, path: m.owner(), method: goName, mc: mc, dec: dec, key: m.Key, static: isStatic})
	}
}

type decoder struct {
	typ  string // the decoded type, over T
	expr string // decodes _v
}

func (g *Gen) decodeOf(r *Repr) *decoder {
	if r == nil {
		return nil
	}
	if r.Kind == "erased" {
		return &decoder{typ: "T", expr: "Decode[T](_v)"}
	}
	if r.Kind == "array" && r.Elem().Kind == "erased" {
		return &decoder{typ: "[]T", expr: "decodeAll[T](_v)"}
	}
	return nil
}

type genericFn struct {
	name, cls, method, key string
	path                   string // the receiver's declaration
	mc                     *memberCode
	dec                    *decoder
	static                 bool
}

// emitGenerics: for each member with a result of an erased type parameter,
// a generic func decoding it. Same-named ones of several classes with the
// same parameters share one func over a union of their receivers.
func (g *Gen) emitGenerics() {
	groups := map[string][]*genericFn{}
	var order []string
	for _, f := range g.generics {
		if _, ok := groups[f.name]; !ok {
			order = append(order, f.name)
		}
		groups[f.name] = append(groups[f.name], f)
	}
	for _, n := range order {
		fs := groups[n]
		sigOf := func(f *genericFn) string { return f.mc.paramList() + "|" + f.mc.results() + "|" + f.dec.typ }
		same := len(fs) > 1
		for _, f := range fs[1:] {
			if sigOf(f) != sigOf(fs[0]) || f.static != fs[0].static {
				same = false
			}
		}
		if len(fs) == 1 || same {
			name := g.funcName(n)
			if name != n {
				// Taken: name each by its class.
				delete(g.pkgNames, name)
				for _, f := range fs {
					g.emitGeneric(g.funcName(f.cls+n), []*genericFn{f})
				}
				continue
			}
			g.emitGeneric(name, fs)
			continue
		}
		for _, f := range fs {
			g.emitGeneric(g.funcName(f.cls+n), []*genericFn{f})
		}
	}
}

func (g *Gen) emitGeneric(name string, fs []*genericFn) {
	f := fs[0]
	mc := f.mc
	var params, args []string
	tparams := "T any"
	// The receivers: each class, and the classes extending it, which have
	// its methods too (embedded, or copied in).
	var recvs []string
	seen := map[string]bool{}
	for _, x := range fs {
		for _, c := range append([]string{x.cls}, g.subclasses(x.path)...) {
			if !seen[c] {
				seen[c] = true
				recvs = append(recvs, c)
			}
		}
	}
	method := map[string]string{}
	for _, x := range fs {
		method[x.cls] = x.method
	}
	for _, c := range recvs {
		if method[c] == "" {
			method[c] = f.method
		}
	}
	if !f.static {
		recvT := "*" + recvs[0]
		if len(recvs) > 1 {
			var cs []string
			for _, c := range recvs {
				cs = append(cs, "*"+c)
			}
			recvT = "R"
			tparams += ", R interface{ " + strings.Join(cs, " | ") + " }"
		}
		params = append(params, "x "+recvT)
	}
	for _, p := range mc.params {
		t := p.typ
		if p.spread {
			t = "..." + strings.TrimPrefix(t, "[]")
			args = append(args, p.name+"...")
		} else {
			args = append(args, p.name)
		}
		params = append(params, p.name+" "+t)
	}
	resT := f.dec.typ
	results := " " + resT
	if mc.fallible {
		results = " (" + resT + ", error)"
	}
	var call string
	var body []string
	if f.static {
		call = f.method + "(" + strings.Join(args, ", ") + ")"
	} else if len(recvs) == 1 {
		call = "x." + f.method + "(" + strings.Join(args, ", ") + ")"
	}
	if !f.static && len(recvs) > 1 {
		body = append(body, "var _v "+mc.resT)
		if mc.fallible {
			body = append(body, "var _err error")
		}
		body = append(body, "switch y := any(x).(type) {")
		for _, c := range recvs {
			if mc.fallible {
				body = append(body, fmt.Sprintf("case *%s:\n\t\t_v, _err = y.%s(%s)", c, method[c], strings.Join(args, ", ")))
			} else {
				body = append(body, fmt.Sprintf("case *%s:\n\t\t_v = y.%s(%s)", c, method[c], strings.Join(args, ", ")))
			}
		}
		body = append(body, "}")
		if mc.fallible {
			body = append(body, "if _err != nil {\n\t\tvar _z "+resT+"\n\t\treturn _z, _err\n\t}")
		}
	} else if mc.fallible {
		body = append(body, "_v, _err := "+call, "if _err != nil {\n\t\tvar _z "+resT+"\n\t\treturn _z, _err\n\t}")
	} else {
		body = append(body, "_v := "+call)
	}
	if mc.fallible {
		body = append(body, "return "+f.dec.expr)
	} else {
		body = append(body, "_d, _ := "+f.dec.expr, "return _d")
	}
	var keys []string
	for _, x := range fs {
		keys = append(keys, "`"+x.key+"`")
	}
	g.out = append(g.out, fmt.Sprintf("// %s is %s, its result decoded as T.\nfunc %s[%s](%s)%s {\n\t%s\n}", name, strings.Join(keys, " or "), name, tparams, strings.Join(params, ", "), results, strings.Join(body, "\n\t")))
}

// subclasses are the generated classes extending path, at any depth, in
// name order.
func (g *Gen) subclasses(path string) []string {
	var out []string
	for _, p := range sortedKeys(g.decls) {
		if p == path || !g.isClassLike(p) {
			continue
		}
		if g.extends(p, path, map[string]bool{}) {
			out = append(out, g.typeName(p))
		}
	}
	return out
}

func (g *Gen) extends(p, ancestor string, seen map[string]bool) bool {
	if seen[p] || g.decls[p] == nil {
		return false
	}
	seen[p] = true
	for _, e := range g.decls[p].Extends {
		if e := stripArgs(e); e == ancestor || g.extends(e, ancestor, seen) {
			return true
		}
	}
	return false
}

// Dictionaries: interfaces with an `@js(object) new()`, as plain structs.

type dictField struct {
	name   string
	typ    string
	get    *Member
	set    *Member
	sets   []*Member
	scalar bool // a nullable scalar or string, unwrapped: zero is unset
}

type dictFn struct{ to, from string }

func (g *Gen) dictFns(path string) dictFn {
	g.dictsUsed[path] = true
	n := g.typeName(path)
	return dictFn{to: "toJS" + n, from: "fromJS" + n}
}

func (g *Gen) dictMembers(path string) []*Member {
	var out []*Member
	seen := map[string]bool{path: true}
	var walk func(p string)
	walk = func(p string) {
		out = append(out, g.byOwner[p]...)
		for _, e := range g.decls[p].Extends {
			q := stripArgs(e)
			if !seen[q] && g.decls[q] != nil {
				seen[q] = true
				walk(q)
			}
		}
	}
	walk(path)
	return out
}

func (g *Gen) emitDict(path string) {
	name := g.typeName(path)
	fn := g.dictFns(path)
	var fields []*dictField
	byName := map[string]*dictField{}
	var newM *Member
	for _, m := range g.dictMembers(path) {
		if m.Role != "import" {
			continue
		}
		switch m.Kind {
		case "new":
			if newM == nil && len(m.Sig.Core.Params) == 0 {
				newM = m
			}
		case "get", "set":
			f := byName[m.Name]
			if f == nil {
				f = &dictField{name: exported(m.Name)}
				byName[m.Name] = f
				fields = append(fields, f)
			}
			if m.Kind == "get" && f.get == nil {
				f.get = m
			} else if m.Kind == "set" && len(m.Sig.Params) == 2 {
				if f.set == nil {
					f.set = m
				}
				dup := false
				for _, x := range f.sets {
					dup = dup || x.Key == m.Key
				}
				if !dup {
					f.sets = append(f.sets, m)
				}
			}
		}
	}
	// Field types.
	var kept []*dictField
	used := map[string]bool{}
	for _, f := range fields {
		ok := g.try(path+"."+f.name, func() {
			var r *Repr
			if f.get != nil {
				r = f.get.Sig.Results[0].Repr
			} else if f.set != nil {
				r = f.set.Sig.Params[1].Repr
			}
			if r == nil {
				fail("a property without a getter or a one-value setter")
			}
			switch {
			case r.Kind == "fn" || (f.set != nil && f.set.Sig.Params[1].Repr.Kind == "fn"):
				sr := r
				if f.set != nil {
					sr = f.set.Sig.Params[1].Repr
				}
				f.typ = g.funcType(sr)
			case r.Kind == "host" && r.Of == "any", r.Kind == "erased":
				f.typ = "any"
			case (r.Kind == "scalar" || r.Kind == "str") && r.Nullable:
				f.typ = g.goType(r.withNullable(false), false)
				f.scalar = true
			case r.Kind == "enum" && r.Enum.Shape.Kind == "carrier" && r.Nullable:
				f.typ = g.goType(r.withNullable(false), false)
				f.scalar = true
			case isHostRef(r) && !g.isClassLike(r.Path) && !g.isDict(r.Path):
				f.typ = "JSValue"
			case r.Kind == "host" && r.Of == "box" && !isStrBox(r):
				f.typ = "JSValue"
			default:
				f.typ = g.goType(r, false)
			}
		})
		if ok {
			for used[f.name] {
				f.name += "_"
			}
			used[f.name] = true
			kept = append(kept, f)
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "// %s is the dictionary `%s`. A zero field is left unset.\ntype %s struct {\n", name, path, name)
	for _, f := range kept {
		doc := ""
		if f.get != nil && f.get.Doc != nil {
			doc = docComment("", f.get.Doc, "\t")
		}
		fmt.Fprintf(&b, "%s\t%s %s\n", doc, f.name, f.typ)
	}
	b.WriteString("}\n")
	g.out = append(g.out, b.String())

	// To JS: a new object, then each set field's setter.
	if newM != nil {
		var body []string
		okAll := g.try(path+" (to JS)", func() {
			newOp := g.importOp(moduleOf(newM), newM.Key, newM.Sig.Core.Params, newM.Sig.Core.Results, nil)
			body = append(body, fmt.Sprintf("if _st := %s(retPtr()); _st != 0 { fail(_st) }", newOp.C), "_o := retI32(0)")
			for _, f := range kept {
				if f.set == nil {
					continue
				}
				f := f
				g.try(path+"."+f.name+" (set)", func() {
					body = append(body, g.dictSetter(f)...)
				})
			}
		})
		if okAll {
			g.out = append(g.out, fmt.Sprintf("// %s makes the JS object of v; the caller frees its slot.\nfunc %s(v %s) int32 {\n\t%s\n\treturn _o\n}", fn.to, fn.to, name, strings.Join(body, "\n\t")))
		} else {
			g.out = append(g.out, fmt.Sprintf("func %s(v %s) int32 { panic(\"ts-gen: %s can't be built\") }", fn.to, name, name))
		}
	} else {
		g.out = append(g.out, fmt.Sprintf("func %s(v %s) int32 { panic(\"ts-gen: %s has no constructor\") }", fn.to, name, name))
	}

	// From JS: each field's getter.
	var body []string
	for _, f := range kept {
		if f.get == nil || strings.HasPrefix(f.typ, "func(") {
			continue
		}
		f := f
		g.try(path+"."+f.name+" (get)", func() {
			r := f.get.Sig.Results[0].Repr
			op := g.importOp(moduleOf(f.get), f.get.Key, f.get.Sig.Core.Params, f.get.Sig.Core.Results, nil)
			var lines []string
			lines = append(lines, fmt.Sprintf("if _st := %s(slot, retPtr()); _st != 0 { refFree(slot, 1); fail(_st) }", op.C))
			var vals []string
			for i, w := range f.get.Sig.Core.Results {
				v := fmt.Sprintf("_r%d", g.tmpID())
				lines = append(lines, fmt.Sprintf("%s := %s(%d)", v, retRead[w], i))
				vals = append(vals, v)
			}
			g.liftCode = nil
			e := g.lift(r, vals)
			lines = append(lines, g.liftCode...)
			g.liftCode = nil
			if f.scalar {
				lines = append(lines, fmt.Sprintf("if _p := %s; _p != nil { v.%s = *_p }", e, f.name))
			} else if f.typ == "any" || f.typ == "JSValue" {
				lines = append(lines, fmt.Sprintf("if _p := %s; _p != nil { v.%s = _p }", e, f.name))
			} else {
				lines = append(lines, fmt.Sprintf("v.%s = %s", f.name, e))
			}
			body = append(body, "{\n\t\t"+strings.Join(lines, "\n\t\t")+"\n\t}")
		})
	}
	g.out = append(g.out, fmt.Sprintf("// %s reads the dictionary in slot, and frees the slot.\nfunc %s(slot int32) (v %s) {\n\t%s\n\trefFree(slot, 1)\n\treturn v\n}", fn.from, fn.from, name, strings.Join(body, "\n\t")))
}

// dictSetter sets field f of v on the object _o, when it's set.
func (g *Gen) dictSetter(f *dictField) []string {
	var body []string
	call := func(set *Member, l lowered, indent string) {
		op := g.importOp(moduleOf(set), set.Key, set.Sig.Core.Params, set.Sig.Core.Results, tagInfo(set.Sig.Throws))
		// A func set on a dictionary is a callback JS can call once the
		// setter is used.
		if r := set.Sig.Params[1].Repr; r.Kind == "fn" && !contains(op.Callbacks, r.Trampoline) {
			op.Callbacks = append(op.Callbacks, r.Trampoline)
			sort.Strings(op.Callbacks)
		}
		for _, c := range l.code {
			body = append(body, indent+c)
		}
		body = append(body, fmt.Sprintf("%sif _st := %s(%s); _st != 0 { refFree(_o, 1); fail(_st) }", indent, op.C, strings.Join(append(append([]string{"_o"}, l.vals...), "retPtr()"), ", ")))
		for _, p := range l.post {
			body = append(body, indent+p)
		}
	}
	var gr *Repr
	if f.get != nil {
		gr = f.get.Sig.Results[0].Repr
	}
	// A union read back, set through one setter per arm: switch on the arm.
	if gr != nil && gr.Kind == "enum" && gr.Enum.Shape.Kind == "payload" {
		direct := false
		for _, set := range f.sets {
			if pr := set.Sig.Params[1].Repr; pr.Kind == "enum" && pr.Enum.Path == gr.Enum.Path {
				direct = true
			}
		}
		if !direct {
			body = append(body, fmt.Sprintf("switch _u := v.%s.(type) {", f.name))
			done := map[string]bool{}
			for _, set := range f.sets {
				pr := set.Sig.Params[1].Repr
				pt := g.goType(pr.withNullable(false), true)
				if done[pt] {
					continue
				}
				done[pt] = true
				for _, a := range gr.Enum.Arms {
					t, field := g.unionArm(gr.Enum, a)
					if t != pt && !(field != "" && len(a.Payload) == 1 && g.goType(a.Payload[0], false) == pt) {
						continue
					}
					e := "_u"
					if field != "" {
						e = "_u.V"
					} else if t == "Str" || t == "Num" || t == "Bool" {
						e = scalarGo2(pr) + "(_u)"
					}
					body = append(body, "case "+t+":")
					call(set, g.lower(pr.withNullable(false), e), "\t")
					break
				}
			}
			return append(body, "}")
		}
	}
	pr := f.set.Sig.Params[1].Repr
	e := "v." + f.name
	if f.scalar && pr.Nullable {
		e = "ptrTo(v." + f.name + ")"
	}
	if isHostRef(pr) && g.isDict(pr.Path) && !pr.Nullable && strings.HasPrefix(f.typ, "*") {
		e = "*v." + f.name
	}
	if (f.typ == "any" || f.typ == "JSValue") && pr.Kind != "host" && pr.Kind != "erased" {
		fail("setter %s", pr.Ty)
	}
	var cond string
	switch {
	case f.typ == "string":
		cond = "v." + f.name + ` != ""`
	case f.typ == "bool":
		cond = "v." + f.name
	case scalarIsNum(f.typ) || (f.scalar && !strings.HasPrefix(f.typ, "*")):
		cond = "v." + f.name + " != 0"
	case strings.HasPrefix(f.typ, "*") || strings.HasPrefix(f.typ, "[]") || strings.HasPrefix(f.typ, "func(") || f.typ == "any" || f.typ == "JSValue":
		cond = "v." + f.name + " != nil"
	case pr.Kind == "enum" && pr.Enum.Shape.Kind == "index":
		cond = "v." + f.name + " != 0"
	case pr.Kind == "enum":
		cond = "v." + f.name + " != nil"
	default:
		cond = "true"
	}
	if (f.typ == "any" || f.typ == "JSValue") && pr.Kind == "host" && pr.Of != "any" {
		body = append(body, fmt.Sprintf("if _jv, ok := v.%s.(JSValue); ok && _jv != nil {", f.name))
		call(f.set, lowered{vals: []string{"slotJS(_jv)"}}, "\t")
	} else {
		l := g.lower(pr, e)
		body = append(body, "if "+cond+" {")
		call(f.set, l, "\t")
	}
	return append(body, "}")
}

func moduleOf(m *Member) string {
	if m.Module != nil {
		return *m.Module
	}
	return "tw:js/global"
}

// Globals and namespaces

func (g *Gen) emitGlobals() {
	taken := map[string]bool{}
	for _, m := range g.byOwner[""] {
		if g.globals[m.Key] {
			g.emitMember(m, "", taken)
		}
	}
	for _, k := range sortedKeys(g.byOwner) {
		if !strings.HasPrefix(k, "ns:") || strings.HasPrefix(k, "ns:Tsgen") || k == "ns:default" {
			continue
		}
		// A namespace's members are functions named for it:
		// `crypto.randomUUID()` is CryptoRandomUUID.
		prefix := exported(strings.ReplaceAll(strings.TrimPrefix(k, "ns:"), ".", "_"))
		g.inNamespace = true
		for _, m := range g.byOwner[k] {
			if m.Role == "import" && g.globals[m.Key] {
				g.emitMember(m, prefix, taken)
			}
		}
		g.inNamespace = false
	}
}
