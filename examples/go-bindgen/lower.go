package main

import (
	"fmt"
	"strings"
)

// Lowering turns a Go expression into wire values for a call; lifting turns
// wire values back into a Go expression. Both emit statements: lowering
// returns them, lifting appends them to g.liftCode.

type lowered struct {
	code []string
	vals []string
	post []string
}

func (l *lowered) add(o lowered) {
	l.code = append(l.code, o.code...)
	l.vals = append(l.vals, o.vals...)
	l.post = append(l.post, o.post...)
}

func scalarLower(s, e string) string {
	switch s {
	case "bool":
		return "b2i(" + e + ")"
	case "f64":
		return "float64(" + e + ")"
	case "f32":
		return "float32(" + e + ")"
	case "i53", "u53", "i64", "u64":
		return "int64(" + e + ")"
	}
	return "int32(" + e + ")"
}

func scalarLift(s, v string) string {
	switch s {
	case "bool":
		return "(" + v + " != 0)"
	case "f64", "f32":
		return v
	}
	return scalarGo[s] + "(" + v + ")"
}

func nicheOf(r *Repr) string {
	if r.Scalar == "bool" {
		return "2"
	}
	if len(r.Wire) > 0 && r.Wire[0] == "i64" {
		return "-9223372036854775808"
	}
	return "-2147483648"
}

func (g *Gen) lower(r *Repr, e string) lowered {
	id := g.tmpID()
	switch r.Kind {
	case "unit":
		return lowered{}
	case "scalar":
		if !r.Nullable {
			return lowered{vals: []string{scalarLower(r.Scalar, e)}}
		}
		w := wireGo[r.Wire[len(r.Wire)-1]]
		if r.hasNiche() {
			v := fmt.Sprintf("_n%d", id)
			return lowered{code: []string{fmt.Sprintf("var %s %s = %s", v, w, nicheOf(r)), fmt.Sprintf("if %s != nil { %s = %s }", e, v, scalarLower(r.Scalar, "*"+e))}, vals: []string{v}}
		}
		v := fmt.Sprintf("_n%d", id)
		return lowered{code: []string{fmt.Sprintf("var %s int32", v), fmt.Sprintf("var %sv %s", v, w), fmt.Sprintf("if %s != nil { %s, %sv = 1, %s }", e, v, v, scalarLower(r.Scalar, "*"+e))}, vals: []string{v, v + "v"}}
	case "str":
		s := fmt.Sprintf("_s%d", id)
		if !r.Nullable {
			return lowered{code: []string{fmt.Sprintf("%s := %s", s, e)}, vals: []string{"strPtr(" + s + ")", "int32(len(" + s + "))"}, post: []string{"runtime.KeepAlive(" + s + ")"}}
		}
		return lowered{
			code: []string{fmt.Sprintf("%s := %s", s, e), fmt.Sprintf("%sp, %sn := int32(1), int32(-1)", s, s), fmt.Sprintf("if %s != nil { %sp, %sn = strPtr(*%s), int32(len(*%s)) }", s, s, s, s, s)},
			vals: []string{s + "p", s + "n"}, post: []string{"runtime.KeepAlive(" + s + ")"},
		}
	case "enum":
		return g.lowerEnum(r, e)
	case "host":
		switch r.Of {
		case "class", "interface":
			if g.isDict(r.Path) {
				o := fmt.Sprintf("_o%d", id)
				fn := g.dictFns(r.Path)
				if r.Nullable {
					return lowered{code: []string{fmt.Sprintf("var %s int32", o), fmt.Sprintf("if %s != nil { %s = %s(*%s) }", e, o, fn.to, e)}, vals: []string{o}, post: []string{fmt.Sprintf("refFree(%s, 1)", o)}}
				}
				return lowered{code: []string{fmt.Sprintf("%s := %s(%s)", o, fn.to, e)}, vals: []string{o}, post: []string{fmt.Sprintf("refFree(%s, 1)", o)}}
			}
			return lowered{vals: []string{"slotJS(" + e + ")"}}
		case "future":
			return lowered{vals: []string{"slotJS(" + e + ")"}}
		case "any":
			o := fmt.Sprintf("_o%d", id)
			return lowered{code: []string{fmt.Sprintf("%s, %sown := anySlot(%s)", o, o, e)}, vals: []string{o}, post: []string{fmt.Sprintf("if %sown { refFree(%s, 1) }", o, o)}}
		case "box":
			if isStrBox(r) {
				o := fmt.Sprintf("_o%d", id)
				if r.Nullable {
					return lowered{code: []string{fmt.Sprintf("var %s int32", o), fmt.Sprintf("if %s != nil { %s = opBoxStr(*%s) }", e, o, e)}, vals: []string{o}, post: []string{fmt.Sprintf("refFree(%s, 1)", o)}}
				}
				return lowered{code: []string{fmt.Sprintf("%s := opBoxStr(%s)", o, e)}, vals: []string{o}, post: []string{fmt.Sprintf("refFree(%s, 1)", o)}}
			}
			return lowered{vals: []string{"slotJS(" + e + ")"}}
		}
		fail("lower host %s", r.Of)
	case "erased":
		o := fmt.Sprintf("_o%d", id)
		return lowered{code: []string{fmt.Sprintf("%s, %sown := anySlot(%s)", o, o, e)}, vals: []string{o}, post: []string{fmt.Sprintf("if %sown { refFree(%s, 1) }", o, o)}}
	case "array":
		return g.lowerArray(r, e)
	case "vec":
		v := fmt.Sprintf("_v%d", id)
		n := fmt.Sprintf("int32(len(%s))", v)
		if r.Nullable {
			n = fmt.Sprintf("func() int32 { if %s == nil { return -1 }; return int32(len(%s)) }()", v, v)
		}
		return lowered{code: []string{fmt.Sprintf("%s := %s", v, e)}, vals: []string{fmt.Sprintf("bytesPtr(%s, %d)", v, vecSize[r.VecElem()]), n}, post: []string{"runtime.KeepAlive(" + v + ")"}}
	case "tuple":
		var l lowered
		t := fmt.Sprintf("_t%d", id)
		if r.Nullable {
			fail("nullable tuple")
		}
		l.code = append(l.code, fmt.Sprintf("%s := %s", t, e))
		for i, el := range r.Elems {
			l.add(g.lower(el, fmt.Sprintf("%s.V%d", t, i)))
		}
		return l
	case "fn":
		g.useCallback(r)
		if r.Nullable {
			h := fmt.Sprintf("_h%d", id)
			return lowered{code: []string{fmt.Sprintf("var %s int32", h), fmt.Sprintf("if %s != nil { %s = retain(%s) }", e, h, e)}, vals: []string{h}}
		}
		return lowered{vals: []string{"retain(" + e + ")"}}
	}
	fail("lower %s", r.Kind)
	return lowered{}
}

func isIdent(s string) bool {
	for i, c := range s {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '.')) {
			return false
		}
	}
	return s != ""
}

// lowerOwned lowers a result Go hands over: its reference slots are the
// receiver's to free.
func (g *Gen) lowerOwned(r *Repr, e string) lowered {
	id := g.tmpID()
	switch {
	case r.Kind == "erased" || r.Kind == "host" && r.Of == "any":
		o := fmt.Sprintf("_o%d", id)
		return lowered{code: []string{fmt.Sprintf("%s, %sown := anySlot(%s)", o, o, e), fmt.Sprintf("if !%sown { %s = refDup(%s) }", o, o, o)}, vals: []string{o}}
	case isStrBox(r) && !r.Nullable:
		return lowered{vals: []string{"opBoxStr(" + e + ")"}}
	case isHostRef(r) && g.isDict(r.Path):
		l := g.lower(r, e)
		l.post = nil
		return l
	case r.Kind == "host":
		return lowered{vals: []string{"refDup(slotJS(" + e + "))"}}
	case r.Kind == "array" || r.Kind == "tuple" || r.Kind == "enum" && r.Enum.Shape.Kind == "payload":
		fail("%s as a result Go returns", r.Kind)
	}
	return g.lower(r, e)
}

// lift turns wire values (Go expressions) of r into a Go expression.
func (g *Gen) lift(r *Repr, vals []string) string {
	id := g.tmpID()
	switch r.Kind {
	case "unit":
		return ""
	case "scalar":
		if !r.Nullable {
			return scalarLift(r.Scalar, vals[0])
		}
		v := fmt.Sprintf("_l%d", id)
		if r.hasNiche() {
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s *%s", v, scalarGo[r.Scalar]), fmt.Sprintf("if %s != %s { %s = ptrTo(%s) }", vals[0], nicheOf(r), v, scalarLift(r.Scalar, vals[0])))
		} else {
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s *%s", v, scalarGo[r.Scalar]), fmt.Sprintf("if %s != 0 { %s = ptrTo(%s) }", vals[0], v, scalarLift(r.Scalar, vals[1])))
		}
		return v
	case "str":
		if r.Nullable {
			return fmt.Sprintf("takeOptString(%s, %s)", vals[0], vals[1])
		}
		return fmt.Sprintf("takeString(%s, %s)", vals[0], vals[1])
	case "enum":
		return g.liftEnum(r, vals)
	case "host", "erased":
		if r.Kind == "host" && r.Of == "future" {
			fail("future in a nested position")
		}
		return g.refLift(r, vals[0], false)
	case "array":
		return g.liftArray(r, vals)
	case "vec":
		t := vecGo[r.VecElem()]
		if r.Nullable {
			v := fmt.Sprintf("_l%d", id)
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s []%s", v, t), fmt.Sprintf("if %s != -1 { %s = takeVec[%s](%s, %s) }", vals[1], v, t, vals[0], vals[1]))
			return v
		}
		return fmt.Sprintf("takeVec[%s](%s, %s)", t, vals[0], vals[1])
	case "tuple":
		k := 0
		var fields []string
		var ts []string
		for i, el := range r.Elems {
			w := vals[k : k+len(el.Wire)]
			k += len(el.Wire)
			fields = append(fields, fmt.Sprintf("V%d: %s", i, g.lift(el, w)))
			ts = append(ts, g.goType(el, false))
		}
		return fmt.Sprintf("Tuple%d[%s]{%s}", len(r.Elems), strings.Join(ts, ", "), strings.Join(fields, ", "))
	case "handle":
		return fmt.Sprintf("handle[%s](%s)", g.goType(r, false), vals[0])
	case "fn":
		return g.refLift(r, vals[0], false)
	}
	fail("lift %s", r.Kind)
	return ""
}

// refLift takes the owned slot s of a reference value. maybeNull says the
// slot itself may hold null (an array element) rather than being 0.
func (g *Gen) refLift(r *Repr, s string, maybeNull bool) string {
	id := g.tmpID()
	if isStrBox(r) {
		op := g.importOp(r.Unbox.imp().Module, r.Unbox.imp().Name, []string{"externref"}, []string{"i32", "i32"}, nil)
		u := fmt.Sprintf("_u%d", id)
		if r.Nullable {
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s *string", u),
				fmt.Sprintf("if %s != 0 && tsgenRefIsNull(%s) == 0 { if _st := %s(%s, retPtr()); _st != 0 { fail(_st) }; %s = ptrTo(takeString(retI32(0), retI32(1))) }", s, s, op.C, s, u),
				fmt.Sprintf("refFree(%s, 1)", s))
		} else {
			g.liftCode = append(g.liftCode, fmt.Sprintf("if _st := %s(%s, retPtr()); _st != 0 { fail(_st) }", op.C, s), fmt.Sprintf("%s := takeString(retI32(0), retI32(1))", u), fmt.Sprintf("refFree(%s, 1)", s))
		}
		return u
	}
	if isHostRef(r) && g.isDict(r.Path) {
		fn := g.dictFns(r.Path)
		if r.Nullable || maybeNull {
			v := fmt.Sprintf("_d%d", id)
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s *%s", v, g.typeName(r.Path)), fmt.Sprintf("if %s != 0 && tsgenRefIsNull(%s) == 0 { %s = ptrTo(%s(%s)) } else { refFree(%s, 1) }", s, s, v, fn.from, s, s))
			if !r.Nullable {
				return "*" + v
			}
			return v
		}
		return fmt.Sprintf("%s(%s)", fn.from, s)
	}
	t := strings.TrimPrefix(g.goType(r.withNullable(false), false), "*")
	if maybeNull {
		return fmt.Sprintf("wrapMaybe[%s](%s)", t, s)
	}
	return fmt.Sprintf("wrap[%s](%s)", t, s)
}

// Enums

func (g *Gen) lowerEnum(r *Repr, e string) lowered {
	L := r.Enum
	switch L.Shape.Kind {
	case "index":
		return lowered{vals: []string{"int32(" + e + ")"}}
	case "carrier":
		if r.Nullable {
			// A presence flag, then the value (as a nullable scalar).
			id := g.tmpID()
			v := fmt.Sprintf("_n%d", id)
			return lowered{code: []string{fmt.Sprintf("var %s int32", v), fmt.Sprintf("var %sv %s", v, wireGo[r.Wire[1]]), fmt.Sprintf("if %s != nil { %s, %sv = 1, %s }", e, v, v, scalarLower(L.Shape.Scalar, "*"+e))}, vals: []string{v, v + "v"}}
		}
		return lowered{vals: []string{scalarLower(L.Shape.Scalar, e)}}
	}
	if g.errorEnums[L.Path] != nil {
		fail("an error enum as a value")
	}
	id := g.tmpID()
	arm := fmt.Sprintf("_a%d", id)
	slots := make([]string, len(L.Shape.Slots))
	code := []string{fmt.Sprintf("var %s int32", arm)}
	for i, w := range L.Shape.Slots {
		slots[i] = fmt.Sprintf("_e%d_%d", id, i)
		code = append(code, fmt.Sprintf("var %s %s", slots[i], wireGo[w]))
	}
	cl := fmt.Sprintf("_cl%d", id)
	x := fmt.Sprintf("_x%d", id)
	cleanup := false
	var cases []string
	classArm := -1
	for ai, a := range L.Arms {
		t, field := g.unionArm(L, a)
		body := []string{fmt.Sprintf("%s = %d", arm, a.Index)}
		k := 0
		for i, p := range a.Payload {
			src := x
			if field != "" {
				src = x + "." + field
				if len(a.Payload) > 1 {
					src = fmt.Sprintf("%s.V%d", x, i)
				}
			} else if t == "Str" || t == "Num" || t == "Bool" {
				src = scalarGo2(p) + "(" + x + ")"
			}
			l := g.lower(p, src)
			body = append(body, l.code...)
			for _, v := range l.vals {
				body = append(body, fmt.Sprintf("%s = %s", slots[a.Slots[k]], v))
				k++
			}
			if len(l.post) > 0 {
				cleanup = true
				body = append(body, fmt.Sprintf("%s = append(%s, func() { %s })", cl, cl, strings.Join(l.post, "; ")))
			}
		}
		if len(a.Payload) == 1 && isHostRef(a.Payload[0]) && g.isClassLike(a.Payload[0].Path) && classArm < 0 {
			classArm = ai
		}
		if len(a.Payload) == 0 {
			body = append(body, "_ = "+x)
		}
		cases = append(cases, "case "+t+":")
		for _, b := range body {
			cases = append(cases, "\t"+b)
		}
	}
	if r.Nullable {
		cases = append(cases, "case nil:")
	}
	// A subclass of a class arm passes as that arm.
	def := fmt.Sprintf("noArm(%s, %s)", x, goString(g.typeName(L.Path)))
	if classArm >= 0 {
		a := L.Arms[classArm]
		def = fmt.Sprintf("if _j, ok := %s.(JSValue); ok { %s = %d; %s = slotJS(_j) } else { %s }", x, arm, a.Index, slots[a.Slots[0]], def)
	}
	cases = append(cases, "default:", "\t"+def)
	if cleanup {
		code = append(code, fmt.Sprintf("var %s []func()", cl))
	}
	code = append(code, fmt.Sprintf("switch %s := %s.(type) {", x, e))
	code = append(code, cases...)
	code = append(code, "}")
	l := lowered{code: code, vals: append([]string{arm}, slots...)}
	if cleanup {
		l.post = []string{fmt.Sprintf("for _, c := range %s { c() }", cl)}
	}
	return l
}

// scalarGo2 is the Go type a Str, Num or Bool arm converts to.
func scalarGo2(p *Repr) string {
	if p.Kind == "str" {
		return "string"
	}
	return scalarGo[p.Scalar]
}

func (g *Gen) liftEnum(r *Repr, vals []string) string {
	L := r.Enum
	name := g.typeName(L.Path)
	switch L.Shape.Kind {
	case "index":
		return name + "(" + vals[0] + ")"
	case "carrier":
		if r.Nullable {
			v := fmt.Sprintf("_c%d", g.tmpID())
			g.liftCode = append(g.liftCode, fmt.Sprintf("var %s *%s", v, name), fmt.Sprintf("if %s != 0 { %s = ptrTo(%s(%s)) }", vals[0], v, name, scalarLift(L.Shape.Scalar, vals[1])))
			return v
		}
		return name + "(" + scalarLift(L.Shape.Scalar, vals[0]) + ")"
	}
	id := g.tmpID()
	v := fmt.Sprintf("_v%d", id)
	ws := make([]string, len(vals))
	code := []string{}
	for i, x := range vals {
		ws[i] = fmt.Sprintf("_w%d_%d", id, i)
		code = append(code, fmt.Sprintf("%s := %s", ws[i], x))
	}
	code = append(code, fmt.Sprintf("var %s %s", v, name), fmt.Sprintf("switch %s {", ws[0]))
	outer := g.liftCode
	for _, a := range L.Arms {
		t, field := g.unionArm(L, a)
		g.liftCode = nil
		k := 0
		var ps []string
		for _, p := range a.Payload {
			w := make([]string, len(p.Wire))
			for j := range p.Wire {
				w[j] = ws[1+a.Slots[k]]
				k++
			}
			ps = append(ps, g.lift(p, w))
		}
		var expr string
		switch {
		case len(a.Payload) == 0:
			expr = t + "{}"
		case field == "":
			if t == "Str" || t == "Num" || t == "Bool" {
				expr = t + "(" + ps[0] + ")"
			} else {
				expr = ps[0]
			}
		case len(ps) == 1:
			expr = fmt.Sprintf("%s{V: %s}", t, ps[0])
		default:
			var fs []string
			for i, p := range ps {
				fs = append(fs, fmt.Sprintf("V%d: %s", i, p))
			}
			expr = t + "{" + strings.Join(fs, ", ") + "}"
		}
		code = append(code, fmt.Sprintf("case %d:", a.Index))
		for _, l := range g.liftCode {
			code = append(code, "\t"+l)
		}
		code = append(code, fmt.Sprintf("\t%s = %s", v, expr))
	}
	g.liftCode = append(outer, code...)
	g.liftCode = append(g.liftCode, "}")
	return v
}

// unionArm is the Go type of a payload enum's arm, and the field of a
// wrapper struct ("" when the type is the payload's own).
func (g *Gen) unionArm(L *EnumLayout, a *Arm) (string, string) {
	arms := g.unionArms[L.Path]
	if arms == nil {
		arms = map[string]string{}
		g.unionArms[L.Path] = arms
		used := map[string]bool{}
		for _, arm := range L.Arms {
			t := ""
			if len(arm.Payload) == 1 {
				p := arm.Payload[0]
				switch {
				case isHostRef(p) && !p.Nullable && g.isClassLike(p.Path):
					t = "*" + g.typeName(p.Path)
				case isHostRef(p) && !p.Nullable && g.isDict(p.Path):
					t = g.typeName(p.Path)
					g.dictsUsed[p.Path] = true
				case p.Kind == "str" && !p.Nullable:
					t = "Str"
				case p.Kind == "scalar" && !p.Nullable && p.Scalar == "f64":
					t = "Num"
				case p.Kind == "scalar" && !p.Nullable && p.Scalar == "bool":
					t = "Bool"
				}
			}
			if t == "" || used[t] {
				t = "=" + g.typeName(L.Path) + exported(arm.Name)
			}
			used[t] = true
			arms[arm.Name] = t
		}
	}
	t := arms[a.Name]
	if strings.HasPrefix(t, "=") {
		if len(a.Payload) == 0 {
			return t[1:], ""
		}
		return t[1:], "V"
	}
	return t, ""
}

// Arrays (IR.md §11): numeric fields packed in memory, references in the
// table.

type arrField struct {
	kind string // str, scalar, enum, ref
	off  int
	ref  int
	r    *Repr
}

type arrLayout struct {
	fields []arrField
	size   int
	refs   int
	align  int
}

func (g *Gen) arrayLayout(elem *Repr) arrLayout {
	var L arrLayout
	L.align = 1
	var add func(r *Repr)
	add = func(r *Repr) {
		switch {
		case r.Kind == "str" && !r.Nullable:
			L.fields = append(L.fields, arrField{kind: "str", off: L.size, r: r})
			L.size += 8
			L.align = max(L.align, 4)
		case r.Kind == "scalar" && !r.Nullable:
			s := scalarSize[r.Scalar]
			L.fields = append(L.fields, arrField{kind: "scalar", off: L.size, r: r})
			L.size += s
			L.align = max(L.align, s)
		case r.Kind == "enum" && r.Enum.Shape.Kind == "index" && !r.Nullable:
			L.fields = append(L.fields, arrField{kind: "enum", off: L.size, r: r})
			L.size += 4
			L.align = max(L.align, 4)
		case (r.Kind == "host" && (r.Of == "class" || r.Of == "interface" || r.Of == "any" || r.Of == "box")) || r.Kind == "erased":
			if isStrBox(r) {
				fail("Str in arr")
			}
			L.fields = append(L.fields, arrField{kind: "ref", ref: L.refs, r: r})
			L.refs++
		case r.Kind == "tuple" && !r.Nullable:
			for _, e := range r.Elems {
				add(e)
			}
		default:
			fail("arr element %s", r.Ty)
		}
	}
	add(elem)
	return L
}

func (g *Gen) lowerArray(r *Repr, e string) lowered {
	L := g.arrayLayout(r.Elem())
	id := g.tmpID()
	src := fmt.Sprintf("_x%d", id)
	n, mem, base := fmt.Sprintf("_n%d", id), fmt.Sprintf("_m%d", id), fmt.Sprintf("_b%d", id)
	code := []string{fmt.Sprintf("%s := %s", src, e), fmt.Sprintf("%s := int32(len(%s))", n, src)}
	post := []string{"runtime.KeepAlive(" + src + ")"}
	if L.size > 0 {
		code = append(code, fmt.Sprintf("%s := make([]byte, %d*int(%s))", mem, L.size, n))
		post = append(post, "runtime.KeepAlive("+mem+")")
	}
	if L.refs > 0 {
		code = append(code, fmt.Sprintf("%s := refAlloc(%d * %s)", base, L.refs, n))
		post = append(post, fmt.Sprintf("refFree(%s, %d*%s)", base, L.refs, n))
	}
	// Tuple fields flatten in order.
	var paths []string
	var walk func(r *Repr, path string)
	walk = func(r *Repr, path string) {
		if r.Kind == "tuple" {
			for i, el := range r.Elems {
				walk(el, fmt.Sprintf("%s.V%d", path, i))
			}
		} else {
			paths = append(paths, path)
		}
	}
	walk(r.Elem(), "_it")
	var body []string
	for fi, f := range L.fields {
		v := paths[fi]
		off := fmt.Sprintf("_i*%d+%d", L.size, f.off)
		switch f.kind {
		case "str":
			body = append(body, fmt.Sprintf("stI32(%s, %s, strPtr(%s)); stI32(%s, %s+4, int32(len(%s)))", mem, off, v, mem, off, v))
		case "scalar":
			sv := v
			if f.r.Scalar == "bool" {
				sv = "uint8(b2i(" + v + "))"
			}
			body = append(body, fmt.Sprintf("st%s(%s, %s, %s)", scalarMem[f.r.Scalar], mem, off, sv))
		case "enum":
			body = append(body, fmt.Sprintf("stI32(%s, %s, int32(%s))", mem, off, v))
		default:
			l := g.lower(f.r, v)
			body = append(body, l.code...)
			body = append(body, fmt.Sprintf("tsgenRefCopy(%s+int32(_i)*%d+%d, %s)", base, L.refs, f.ref, l.vals[0]))
			body = append(body, l.post...)
		}
	}
	code = append(code, fmt.Sprintf("for _i, _it := range %s {", src))
	for _, b := range body {
		code = append(code, "\t"+b)
	}
	code = append(code, "\t_ = _it", "}")
	var vals []string
	if L.size > 0 {
		vals = append(vals, fmt.Sprintf("bytesPtr(%s, %d)", mem, L.align))
	}
	if L.refs > 0 {
		vals = append(vals, base)
	}
	if r.Nullable {
		vals = append(vals, fmt.Sprintf("func() int32 { if %s == nil { return -1 }; return %s }()", src, n))
	} else {
		vals = append(vals, n)
	}
	return lowered{code: code, vals: vals, post: post}
}

func (g *Gen) liftArray(r *Repr, vals []string) string {
	L := g.arrayLayout(r.Elem())
	id := g.tmpID()
	k := 0
	mem, base := "", ""
	if L.size > 0 {
		mem = vals[k]
		k++
	}
	if L.refs > 0 {
		base = vals[k]
		k++
	}
	n := vals[k]
	out := fmt.Sprintf("_r%d", id)
	elemT := g.goType(r.Elem(), false)
	outer := g.liftCode
	g.liftCode = nil
	var fieldVals []string
	for _, f := range L.fields {
		off := fmt.Sprintf("int(_i)*%d+%d", L.size, f.off)
		switch f.kind {
		case "str":
			fieldVals = append(fieldVals, fmt.Sprintf("takeString(ldI32(%s, %s), ldI32(%s, %s+4))", mem, off, mem, off))
		case "scalar":
			v := fmt.Sprintf("ld%s(%s, %s)", scalarMem[f.r.Scalar], mem, off)
			if f.r.Scalar == "bool" {
				v = "(" + v + " != 0)"
			}
			fieldVals = append(fieldVals, v)
		case "enum":
			fieldVals = append(fieldVals, fmt.Sprintf("%s(ldI32(%s, %s))", g.typeName(f.r.Enum.Path), mem, off))
		default:
			fieldVals = append(fieldVals, g.refLift(f.r, fmt.Sprintf("(%s+_i*%d+%d)", base, L.refs, f.ref), true))
		}
	}
	elemCode := g.liftCode
	g.liftCode = outer
	fi := 0
	var build func(r *Repr) string
	build = func(r *Repr) string {
		if r.Kind == "tuple" {
			var fs, ts []string
			for i, el := range r.Elems {
				fs = append(fs, fmt.Sprintf("V%d: %s", i, build(el)))
				ts = append(ts, g.goType(el, false))
			}
			return fmt.Sprintf("Tuple%d[%s]{%s}", len(r.Elems), strings.Join(ts, ", "), strings.Join(fs, ", "))
		}
		v := fieldVals[fi]
		fi++
		return v
	}
	elemExpr := build(r.Elem())
	fill := []string{fmt.Sprintf("%s = make([]%s, %s)", out, elemT, n), fmt.Sprintf("for _i := int32(0); _i < %s; _i++ {", n)}
	for _, c := range elemCode {
		fill = append(fill, "\t"+c)
	}
	fill = append(fill, fmt.Sprintf("\t%s[_i] = %s", out, elemExpr), "}")
	if mem != "" {
		fill = append(fill, fmt.Sprintf("take(%s, %s)", mem, n))
	}
	code := []string{fmt.Sprintf("var %s []%s", out, elemT)}
	if r.Nullable {
		code = append(code, fmt.Sprintf("if %s != -1 {", n))
		for _, f := range fill {
			code = append(code, "\t"+f)
		}
		code = append(code, "}")
	} else {
		code = append(code, fill...)
	}
	g.liftCode = append(g.liftCode, code...)
	return out
}
