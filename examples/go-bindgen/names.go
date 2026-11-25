package main

import (
	"regexp"
	"strings"
	"unicode"
)

var goKeywords = set("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")

// Predeclared names and the runtime's own package-level names, which a
// parameter must not shadow.
var reservedLocals = set("any bool byte cap clear close complex copy delete error false float32 float64 imag int int8 int16 int32 int64 iota len make max min new nil panic print println real recover rune string true uint uint8 uint16 uint32 uint64 uintptr " +
	"runtime unsafe json fmt math strconv " +
	"wrap wrapMaybe take takeString takeOptString takeVec strPtr bytesPtr memAt refAlloc refFree refDup retPtr retI32 retI64 retF32 retF64 setRetI32 setRetI64 setRetF32 setRetF64 b2i " +
	"anySlot retain handle release exception fail describe await enter leave exports itoa x")

// Exported names of the runtime and of the generated package's fixed API.
var reservedTypes = set("Object Value JSValue Cast Decode ValueOf Exception Exports SetExports Str Num Bool Tuple2 Tuple3 Tuple4 Tuple5")

// Go's initialisms, uppercased whole inside names (`getJson` is GetJSON).
var initialisms = set("ACL API ASCII CPU CSS DNS EOF GUID HTML HTTP HTTPS ID IP JSON LHS QPS RAM RHS RPC SLA SMTP SQL SSH TCP TLS TTL UDP UI UID UUID URI URL UTF8 VM XML XMPP XSRF XSS")

func set(s string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(s) {
		m[w] = true
	}
	return m
}

var nonIdent = regexp.MustCompile(`[^A-Za-z0-9_]+`)

// words splits an identifier at underscores and case changes.
func words(s string) []string {
	s = nonIdent.ReplaceAllString(s, "_")
	var out []string
	for _, part := range strings.Split(s, "_") {
		if part == "" {
			continue
		}
		rs := []rune(part)
		start := 0
		for i := 1; i < len(rs); i++ {
			lower := func(r rune) bool { return unicode.IsLower(r) || unicode.IsDigit(r) }
			// aB | ABc
			if (lower(rs[i-1]) && unicode.IsUpper(rs[i])) ||
				(i+1 < len(rs) && unicode.IsUpper(rs[i-1]) && unicode.IsUpper(rs[i]) && unicode.IsLower(rs[i+1])) {
				out = append(out, string(rs[start:i]))
				start = i
			}
		}
		out = append(out, string(rs[start:]))
	}
	return out
}

// exported is a member or field name as an exported Go name.
func exported(s string) string {
	var b strings.Builder
	for _, w := range words(s) {
		switch {
		case initialisms[strings.ToUpper(w)]:
			b.WriteString(strings.ToUpper(w))
		case len(w) > 3 && w == strings.ToUpper(w) && strings.ToLower(w) != w:
			// A shouted name (`GREETING`) reads as a word in Go.
			b.WriteString(w[:1] + strings.ToLower(w[1:]))
		default:
			b.WriteString(strings.ToUpper(w[:1]) + w[1:])
		}
	}
	out := b.String()
	if out == "" {
		return "X"
	}
	if out[0] >= '0' && out[0] <= '9' {
		out = "N" + out
	}
	return out
}

// local is a parameter name.
func local(s string) string {
	ws := words(s)
	if len(ws) == 0 {
		return "p"
	}
	var b strings.Builder
	for i, w := range ws {
		if i == 0 {
			b.WriteString(strings.ToLower(w[:1]) + w[1:])
		} else if initialisms[strings.ToUpper(w)] {
			b.WriteString(strings.ToUpper(w))
		} else {
			b.WriteString(strings.ToUpper(w[:1]) + w[1:])
		}
	}
	out := b.String()
	if out[0] >= '0' && out[0] <= '9' {
		out = "p" + out
	}
	if goKeywords[out] || reservedLocals[out] {
		out += "_"
	}
	return out
}

// typeIdent is a declaration path as a Go type name, without uniqueness.
func typeIdent(path string) string {
	if path == "err" {
		return "JSError"
	}
	p := path
	prefix := ""
	if strings.HasPrefix(p, `"`) {
		if i := strings.Index(p[1:], `"`); i >= 0 {
			spec := p[1 : i+1]
			if j := strings.Index(spec, ":"); j >= 0 {
				spec = spec[j+1:]
			}
			prefix = exportedKeep(spec)
			p = strings.TrimPrefix(p[i+2:], ".")
		}
	}
	var b strings.Builder
	b.WriteString(prefix)
	for _, seg := range strings.Split(p, ".") {
		b.WriteString(exportedKeep(seg))
	}
	out := b.String()
	if out == "" || (out[0] >= '0' && out[0] <= '9') {
		out = "T" + out
	}
	if reservedTypes[out] {
		out = "JS" + out
	}
	return out
}

// exportedKeep keeps a TypeScript name's own casing, capitalized.
func exportedKeep(s string) string {
	var b strings.Builder
	for _, w := range words(s) {
		b.WriteString(strings.ToUpper(w[:1]) + w[1:])
	}
	return b.String()
}

func goString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r < 0x20:
			b.WriteString(`\x`)
			b.WriteString(strings.ToLower(string("0123456789abcdef"[r>>4])) + string("0123456789abcdef"[r&15]))
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func docComment(name string, doc *string, indent string) string {
	if doc == nil || *doc == "" {
		return ""
	}
	var b strings.Builder
	for i, l := range strings.Split(*doc, "\n") {
		if i == 0 && name != "" {
			l = name + ": " + l
		}
		b.WriteString(indent + "// " + strings.TrimRight(l, " ") + "\n")
	}
	return b.String()
}
