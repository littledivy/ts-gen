package main

import (
	"fmt"
	"sort"
	"strings"
)

// Gen maps a lowered IR to Go (IR.md):
//
//	class, interface      *T, a struct embedding Object (or its first
//	                      class-like parent). Getters are methods, setters
//	                      SetX, `new` is NewT, statics are T-prefixed funcs
//	interface with        a plain struct T of its properties (a
//	@js(object) new()     dictionary): zero fields are left unset
//	enum (index)          a named int32 with constants; 0 is none
//	enum (payload)        a sealed interface its arms' types implement
//	enum (carrier)        a named number with constants
//	enum in `throws`      *T, an error with Kind and Message (errors.As)
//	T?                    *T for scalars and strings; nil otherwise
//	future<T, E>          blocks (await): (T, error)
//	throws E              (T, error)
//	fn(A) -> R            func(A) R; a handle while JS holds it
//	T (a type parameter)  `any` in, *Value out, plus a generic func that
//	                      decodes T (encoding/json): First[Row](stmt)
//	Any                   `any` in, *Value out
//	arr<T>, T[], (A, B)   []T, []T, TupleN[A, B]
//	export namespace,     fields of Exports, which the generated main
//	export class          glue fills with the app's funcs and types
type Gen struct {
	pkg     string
	decls   map[string]*Decl
	members []*Member
	byOwner map[string][]*Member

	exportedClasses map[string]bool
	selected        map[string]bool
	globals         map[string]bool

	imports   map[string]*ImportOp // module\0name
	importSeq []*ImportOp
	exports   []*ExportOp

	callbacks        map[string]*Repr    // trampoline -> fn repr (nil while failing)
	callbackCode     map[string][]string // trampoline -> declarations
	keepCallbacksFor map[string]bool     // shim imports the app uses (nil: keep all)

	enumsUsed  map[string]*EnumLayout
	enumOrder  []string
	errorEnums map[string]*EnumLayout
	unionArms  map[string]map[string]string // union path -> arm name -> Go type

	names     map[string]string // decl path -> Go type name
	pkgNames  map[string]bool   // package-level names taken
	out       []string
	skipped   []Skip
	emitted   int
	tmp       int
	liftCode  []string
	memberCbs map[string]bool
	// own: the declarations and member keys of the IR being generated, not
	// its libs. Without roots, these are what's generated.
	own map[string]bool
	// inNamespace: the member being emitted belongs to a namespace.
	inNamespace bool

	generics  []*genericFn
	dictsUsed map[string]bool

	aliases       map[string]bool
	enumDecls     []string
	exportFields  []exportField
	g_ops         string
	keepCallbacks map[string]bool
	enumOK        map[string]string
}

type Skip struct {
	Key string `json:"key"`
	Why string `json:"why"`
}

// ImportOp is one shim import: the Go side calls `tsgen_i<n>(params...,
// ret) status`, the shim calls (Module, Name).
type ImportOp struct {
	C         string   `json:"c"`
	Module    string   `json:"module"`
	Name      string   `json:"name"`
	Params    []string `json:"params"`
	Results   []string `json:"results"`
	Throws    *TagInfo `json:"throws"`
	Callbacks []string `json:"callbacks,omitempty"`
}

// ExportOp is one export: the shim exports Name, calling Go's C.
type ExportOp struct {
	C       string   `json:"c"`
	Name    string   `json:"name"`
	Params  []string `json:"params"`
	Results []string `json:"results"`
	Throws  *TagInfo `json:"throws"`
	Async   bool     `json:"async"`
	Owner   string   `json:"owner,omitempty"`
	Member  string   `json:"member,omitempty"`
	Kind    string   `json:"kind,omitempty"`
}

type TagInfo struct {
	Module string      `json:"module"`
	Name   string      `json:"name"`
	Params []string    `json:"params"`
	enum   *EnumLayout `json:"-"`
}

type unsupported struct{ why string }

func fail(format string, args ...any) { panic(unsupported{fmt.Sprintf(format, args...)}) }

// try runs f, turning an unsupported construct into a skip.
func (g *Gen) try(key string, f func()) (ok bool) {
	defer func() {
		if r := recover(); r != nil {
			u, isU := r.(unsupported)
			if !isU {
				panic(r)
			}
			g.skipped = append(g.skipped, Skip{key, u.why})
			ok = false
		}
	}()
	f()
	return true
}

func newGen(low *Lowered, libs []*Lowered, pkg string) *Gen {
	g := &Gen{
		pkg:             pkg,
		decls:           map[string]*Decl{},
		byOwner:         map[string][]*Member{},
		exportedClasses: map[string]bool{},
		imports:         map[string]*ImportOp{},
		callbacks:       map[string]*Repr{},
		callbackCode:    map[string][]string{},
		enumsUsed:       map[string]*EnumLayout{},
		errorEnums:      map[string]*EnumLayout{},
		unionArms:       map[string]map[string]string{},
		names:           map[string]string{},
		pkgNames:        map[string]bool{},
		dictsUsed:       map[string]bool{},
	}
	g.own = map[string]bool{}
	for _, d := range low.Decls {
		g.own[d.Path] = true
	}
	for _, m := range low.Members {
		g.own[m.Key] = true
	}
	for _, src := range append([]*Lowered{low}, libs...) {
		for _, d := range src.Decls {
			if _, ok := g.decls[d.Path]; !ok {
				g.decls[d.Path] = d
			}
		}
		g.members = append(g.members, src.Members...)
	}
	for _, m := range g.members {
		if m.Role == "export" && m.Owner != nil {
			g.exportedClasses[*m.Owner] = true
		}
		k := m.owner()
		if k == "" && len(m.Namespace) > 0 {
			k = "ns:" + strings.Join(m.Namespace, ".")
		}
		g.byOwner[k] = append(g.byOwner[k], m)
	}
	for _, ms := range g.byOwner {
		renameOverloads(ms)
	}
	for n := range reservedTypes {
		g.pkgNames[n] = true
	}
	return g
}

// renameOverloads gives an overload set's plain name to the overload with
// the fewest parameters, as Go callers expect (`First[T](stmt)`,
// `bucket.Get(key)`), in place of the numbered variant the lowering picks
// for it; the overload that had the plain name is named for the parameters
// it adds (`FirstWithColName`).
func renameOverloads(ms []*Member) {
	type key struct {
		kind, name string
		static     bool
	}
	groups := map[key][]*Member{}
	for _, m := range ms {
		if m.Kind == "get" || m.Kind == "set" || m.Kind == "new" {
			continue
		}
		k := key{m.Kind, m.Name, m.Static}
		groups[k] = append(groups[k], m)
	}
	for _, g := range groups {
		var plain, short *Member
		used := map[string]bool{}
		for _, m := range g {
			used[m.Variant] = true
			if m.Variant == m.Name {
				plain = m
			}
			if short == nil || len(m.Params) < len(short.Params) {
				short = m
			}
		}
		if plain == nil || short == plain || len(short.Params) == len(plain.Params) ||
			!numbered(short.Variant, short.Name) {
			continue
		}
		var extra []string
		for _, p := range plain.Params[len(short.Params):] {
			extra = append(extra, exported(p.Name))
		}
		name := plain.Name + "With" + strings.Join(extra, "And")
		if used[name] {
			continue
		}
		short.Variant, plain.Variant = plain.Name, name
	}
}

// numbered reports whether variant is name followed by digits.
func numbered(variant, name string) bool {
	rest, ok := strings.CutPrefix(variant, name)
	if !ok || rest == "" {
		return false
	}
	for _, c := range rest {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// select limits the bindings to roots (declarations and global members) and
// everything their members reach; exports always count.
func (g *Gen) selectRoots(roots []string) {
	sel := map[string]bool{}
	var queue []string
	addDecl := func(p string) {
		if p == "" || sel[p] {
			return
		}
		if _, ok := g.decls[p]; !ok {
			return
		}
		sel[p] = true
		queue = append(queue, p)
	}
	var walk func(r *Repr)
	walk = func(r *Repr) {
		if r == nil {
			return
		}
		if r.Path != "" {
			addDecl(r.Path)
		}
		walk(r.Inner)
		walk(r.Value)
		walk(r.Elem())
		for _, e := range r.Elems {
			walk(e)
		}
		for _, p := range r.Params {
			walk(p)
		}
		walk(r.Result)
		if r.Enum != nil {
			addDecl(r.Enum.Path)
			for _, a := range r.Enum.Arms {
				for _, p := range a.Payload {
					walk(p)
				}
			}
		}
	}
	walkMember := func(m *Member) {
		for _, p := range m.Sig.Params {
			walk(p.Repr)
		}
		for _, r := range m.Sig.Results {
			walk(r.Repr)
		}
	}
	for _, m := range g.members {
		if m.Role == "export" {
			walkMember(m)
		}
	}
	for _, r := range []string{"TsgenError"} {
		addDecl(r)
	}
	all := roots == nil
	globals := map[string]bool{}
	if all {
		for p := range g.decls {
			if g.own[p] {
				addDecl(p)
			}
		}
	}
	for _, r := range roots {
		if _, ok := g.decls[r]; ok {
			addDecl(r)
		} else {
			globals[r] = true
		}
	}
	g.globals = map[string]bool{}
	for _, m := range g.byOwner[""] {
		if m.Role == "import" && (all && g.own[m.Key] || globals[m.Name]) {
			g.globals[m.Key] = true
			walkMember(m)
		}
	}
	for k, ms := range g.byOwner {
		if strings.HasPrefix(k, "ns:") {
			for _, m := range ms {
				if m.Role == "import" && (all && g.own[m.Key] || globals[strings.TrimPrefix(k, "ns:")] || k == "ns:TsgenJSON") {
					g.globals[m.Key] = true
					walkMember(m)
				}
			}
		}
	}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		d := g.decls[p]
		for _, e := range d.Extends {
			addDecl(stripArgs(e))
		}
		for _, m := range g.byOwner[p] {
			if m.Role == "import" {
				walkMember(m)
			}
		}
		if d.Kind == "enum" && d.Layout != nil {
			for _, a := range d.Layout.Arms {
				for _, pl := range a.Payload {
					walk(pl)
				}
			}
		}
	}
	g.selected = sel
}

func stripArgs(s string) string {
	if i := strings.Index(s, "<"); i >= 0 {
		return s[:i]
	}
	return s
}

// The kinds of declarations.

func (g *Gen) isDict(path string) bool {
	d := g.decls[path]
	if d == nil || d.Kind != "interface" || !g.selected[path] || g.exportedClasses[path] {
		return false
	}
	ok := false
	for _, m := range g.byOwner[path] {
		if m.Kind == "new" && m.Role == "import" && len(m.Sig.Core.Params) == 0 && m.JSName == nil {
			ok = true
		}
	}
	// A dictionary is plain data: what it extends must be too, or it is an
	// object with methods (`DurableObjectStub extends Fetcher`).
	for _, e := range d.Extends {
		if ok && !g.isDict(stripArgs(e)) && !g.dataOnly(stripArgs(e)) {
			ok = false
		}
	}
	return ok
}

// dataOnly reports whether a declaration has only accessors, so it can be
// a dictionary's parent.
func (g *Gen) dataOnly(path string) bool {
	if g.decls[path] == nil {
		return false
	}
	for _, m := range g.byOwner[path] {
		if m.Kind != "get" && m.Kind != "set" && m.Kind != "new" {
			return false
		}
	}
	for _, e := range g.decls[path].Extends {
		if !g.dataOnly(stripArgs(e)) {
			return false
		}
	}
	return true
}

func (g *Gen) isClassLike(path string) bool {
	d := g.decls[path]
	return d != nil && (d.Kind == "class" || d.Kind == "interface") && g.selected[path] && !g.exportedClasses[path] && !g.isDict(path)
}

// typeName is a declaration's Go name, unique in the package.
func (g *Gen) typeName(path string) string {
	if n, ok := g.names[path]; ok {
		return n
	}
	base := typeIdent(path)
	n := base
	for i := 2; g.pkgNames[n]; i++ {
		n = fmt.Sprintf("%s%d", base, i)
	}
	g.pkgNames[n] = true
	g.names[path] = n
	return n
}

// funcName claims a package-level name for a function.
func (g *Gen) funcName(base string) string {
	n := base
	for i := 2; g.pkgNames[n]; i++ {
		n = fmt.Sprintf("%s%d", base, i)
	}
	g.pkgNames[n] = true
	return n
}

func (g *Gen) primaryParent(p string) string {
	for _, e := range g.decls[p].Extends {
		q := stripArgs(e)
		if g.isClassLike(q) {
			return q
		}
	}
	return ""
}

func (g *Gen) ancestors(p string) []string {
	var out []string
	for q := g.primaryParent(p); q != ""; q = g.primaryParent(q) {
		out = append(out, q)
	}
	return out
}

// Type mapping

var scalarGo = map[string]string{"bool": "bool", "i8": "int8", "u8": "uint8", "i16": "int16", "u16": "uint16", "i32": "int32", "u32": "uint32", "i53": "int64", "u53": "int64", "i64": "int64", "u64": "uint64", "f32": "float32", "f64": "float64"}
var scalarSize = map[string]int{"bool": 1, "i8": 1, "u8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "f32": 4, "f64": 8, "i53": 8, "u53": 8, "i64": 8, "u64": 8}
var scalarMem = map[string]string{"bool": "U8", "i8": "I8", "u8": "U8", "i16": "I16", "u16": "U16", "i32": "I32", "u32": "U32", "f32": "F32", "f64": "F64", "i53": "I64", "u53": "I64", "i64": "I64", "u64": "U64"}
var vecGo = map[string]string{"i8": "int8", "u8": "byte", "i16": "int16", "u16": "uint16", "i32": "int32", "u32": "uint32", "i64": "int64", "u64": "uint64", "f32": "float32", "f64": "float64"}
var vecSize = map[string]int{"i8": 1, "u8": 1, "i16": 2, "u16": 2, "i32": 4, "u32": 4, "i64": 8, "u64": 8, "f32": 4, "f64": 8}
var wireGo = map[string]string{"i32": "int32", "i64": "int64", "f32": "float32", "f64": "float64", "externref": "int32"}
var retRead = map[string]string{"i32": "retI32", "i64": "retI64", "f32": "retF32", "f64": "retF64", "externref": "retI32"}
var retSet = map[string]string{"i32": "setRetI32", "i64": "setRetI64", "f32": "setRetF32", "f64": "setRetF64", "externref": "setRetI32"}

func isHostRef(r *Repr) bool {
	return r.Kind == "host" && (r.Of == "class" || r.Of == "interface")
}

func isStrBox(r *Repr) bool {
	return r.Kind == "host" && r.Of == "box" && r.Inner != nil && r.Inner.Kind == "str"
}

// goType is the Go type of a value; in says it's a parameter.
func (g *Gen) goType(r *Repr, in bool) string {
	opt := func(t string) string {
		if r.Nullable {
			return "*" + t
		}
		return t
	}
	switch r.Kind {
	case "unit":
		return ""
	case "scalar":
		t, ok := scalarGo[r.Scalar]
		if !ok {
			fail("scalar %s", r.Scalar)
		}
		return opt(t)
	case "str":
		return opt("string")
	case "enum":
		if strings.HasSuffix(r.Enum.Path, "??") {
			fail("T??")
		}
		g.checkEnum(r.Enum)
		g.useEnum(r.Enum)
		name := g.typeName(r.Enum.Path)
		if r.Enum.Shape.Kind == "carrier" {
			return opt(name)
		}
		return name
	case "host":
		switch r.Of {
		case "class", "interface":
			if g.isClassLike(r.Path) {
				return "*" + g.typeName(r.Path)
			}
			if g.isDict(r.Path) {
				g.dictsUsed[r.Path] = true
				return opt(g.typeName(r.Path))
			}
			if in {
				return "JSValue"
			}
			return "*Value"
		case "any":
			if in {
				return "any"
			}
			return "*Value"
		case "box":
			if isStrBox(r) {
				return opt("string")
			}
			if in {
				return "JSValue"
			}
			return "*Value"
		case "future":
			if in {
				return "JSValue"
			}
			fail("future in a nested position")
		}
		fail("host %s", r.Of)
	case "erased":
		if in {
			return "any"
		}
		return "*Value"
	case "array":
		g.arrayLayout(r.Elem())
		return "[]" + g.goType(r.Elem(), in)
	case "vec":
		t, ok := vecGo[r.VecElem()]
		if !ok {
			fail("vec %s", r.VecElem())
		}
		return "[]" + t
	case "tuple":
		if len(r.Elems) < 2 || len(r.Elems) > 5 {
			fail("tuple of %d", len(r.Elems))
		}
		var ts []string
		for _, e := range r.Elems {
			ts = append(ts, g.goType(e, in))
		}
		return opt(fmt.Sprintf("Tuple%d[%s]", len(r.Elems), strings.Join(ts, ", ")))
	case "fn":
		if !in {
			return "*Value"
		}
		return g.funcType(r)
	case "handle":
		if !g.exportedClasses[r.Class] {
			fail("handle %s", r.Class)
		}
		return g.typeName(r.Class) + "Export"
	}
	fail("kind %s", r.Kind)
	return ""
}

// funcType is a callback's Go type.
func (g *Gen) funcType(r *Repr) string {
	var ps []string
	for _, p := range r.Params {
		ps = append(ps, g.goType(p, false))
	}
	res := g.callbackResult(r.Result)
	results := ""
	switch {
	case r.FnThrows != nil && res != "":
		results = " (" + res + ", error)"
	case r.FnThrows != nil:
		results = " error"
	case res != "":
		results = " " + res
	}
	return "func(" + strings.Join(ps, ", ") + ")" + results
}

func (g *Gen) callbackResult(r *Repr) string {
	if r == nil || r.Kind == "unit" || (r.Kind == "host" && r.Of == "future" && r.Nullable) {
		return ""
	}
	return g.goType(r, true)
}

// checkEnum fails when an enum's payloads can't be mapped, so a member
// using it is skipped with it.
func (g *Gen) checkEnum(L *EnumLayout) {
	if g.enumOK == nil {
		g.enumOK = map[string]string{}
	}
	if why, ok := g.enumOK[L.Path]; ok {
		if why != "" {
			fail("%s", why)
		}
		return
	}
	g.enumOK[L.Path] = ""
	ok := true
	func() {
		defer func() {
			if r := recover(); r != nil {
				u, isU := r.(unsupported)
				if !isU {
					panic(r)
				}
				g.enumOK[L.Path] = "enum " + L.Path + ": " + u.why
				ok = false
			}
		}()
		for _, a := range L.Arms {
			for _, p := range a.Payload {
				g.goType(p, false)
				g.goType(p, true)
			}
		}
	}()
	if !ok {
		fail("%s", g.enumOK[L.Path])
	}
}

func (g *Gen) useEnum(L *EnumLayout) {
	if _, ok := g.enumsUsed[L.Path]; !ok {
		g.enumsUsed[L.Path] = L
		g.enumOrder = append(g.enumOrder, L.Path)
	}
}

// Shim operations

func (g *Gen) importOp(module, name string, params, results []string, throws *TagInfo) *ImportOp {
	k := module + "\x00" + name
	if e, ok := g.imports[k]; ok {
		return e
	}
	e := &ImportOp{C: fmt.Sprintf("tsgen_i%d", len(g.importSeq)), Module: module, Name: name, Params: params, Results: results, Throws: throws}
	g.imports[k] = e
	g.importSeq = append(g.importSeq, e)
	return e
}

func (g *Gen) exportOp(name string, params, results []string, throws *TagInfo) *ExportOp {
	e := &ExportOp{C: fmt.Sprintf("tsgen_x%d", len(g.exports)), Name: name, Params: params, Results: results, Throws: throws}
	g.exports = append(g.exports, e)
	return e
}

func tagInfo(t *Throws) *TagInfo {
	if t == nil {
		return nil
	}
	return &TagInfo{Module: t.Tag.Module, Name: t.Tag.Name, Params: append([]string{"i32"}, t.Enum.Shape.Slots...), enum: t.Enum}
}

func (g *Gen) tmpID() int {
	g.tmp++
	return g.tmp
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
