//go:build tsgen_runtime

// JSON for Value.Decode and anySlot, over reflect: a subset of
// encoding/json's mapping (struct fields by `json` tag or, case-folded, by
// name; omitempty; "-"; embedded structs; []byte as base64; MarshalJSON and
// UnmarshalJSON), without encoding/json's size.

package tsgenruntime

import (
	"encoding/base64"
	"errors"
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

type jsonMarshaler interface{ MarshalJSON() ([]byte, error) }
type jsonUnmarshaler interface{ UnmarshalJSON([]byte) error }

var (
	marshalerType   = reflect.TypeFor[jsonMarshaler]()
	unmarshalerType = reflect.TypeFor[jsonUnmarshaler]()
)

func jsonMarshal(v any) ([]byte, error) {
	var b []byte
	return appendJSON(b, reflect.ValueOf(v))
}

func appendJSON(b []byte, v reflect.Value) ([]byte, error) {
	if !v.IsValid() {
		return append(b, "null"...), nil
	}
	if v.Type().Implements(marshalerType) && !(v.Kind() == reflect.Pointer && v.IsNil()) {
		m, err := v.Interface().(jsonMarshaler).MarshalJSON()
		return append(b, m...), err
	}
	switch v.Kind() {
	case reflect.Bool:
		return strconv.AppendBool(b, v.Bool()), nil
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return strconv.AppendInt(b, v.Int(), 10), nil
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		return strconv.AppendUint(b, v.Uint(), 10), nil
	case reflect.Float32, reflect.Float64:
		f := v.Float()
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return b, errors.New("ts-gen: JSON has no " + strconv.FormatFloat(f, 'g', -1, 64))
		}
		if a := math.Abs(f); a != 0 && (a < 1e-6 || a >= 1e21) {
			// As encoding/json writes it: e-07 is e-7.
			n := len(b)
			b = strconv.AppendFloat(b, f, 'e', -1, 64)
			if m := len(b) - n; m >= 4 && b[len(b)-4] == 'e' && b[len(b)-3] == '-' && b[len(b)-2] == '0' {
				b[len(b)-2] = b[len(b)-1]
				b = b[:len(b)-1]
			}
			return b, nil
		}
		return strconv.AppendFloat(b, f, 'f', -1, 64), nil
	case reflect.String:
		return appendJSONString(b, v.String()), nil
	case reflect.Interface, reflect.Pointer:
		if v.IsNil() {
			return append(b, "null"...), nil
		}
		return appendJSON(b, v.Elem())
	case reflect.Slice:
		if v.IsNil() {
			return append(b, "null"...), nil
		}
		if v.Type().Elem().Kind() == reflect.Uint8 {
			return appendJSONString(b, base64.StdEncoding.EncodeToString(v.Bytes())), nil
		}
		fallthrough
	case reflect.Array:
		b = append(b, '[')
		for i := range v.Len() {
			if i > 0 {
				b = append(b, ',')
			}
			var err error
			if b, err = appendJSON(b, v.Index(i)); err != nil {
				return b, err
			}
		}
		return append(b, ']'), nil
	case reflect.Map:
		if v.IsNil() {
			return append(b, "null"...), nil
		}
		keys := v.MapKeys()
		ks := make([]string, len(keys))
		for i, k := range keys {
			switch k.Kind() {
			case reflect.String:
				ks[i] = k.String()
			case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
				ks[i] = strconv.FormatInt(k.Int(), 10)
			case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
				ks[i] = strconv.FormatUint(k.Uint(), 10)
			default:
				return b, errors.New("ts-gen: JSON object keys are strings, not " + k.Type().String())
			}
		}
		idx := make([]int, len(keys))
		for i := range idx {
			idx[i] = i
		}
		sort.Slice(idx, func(i, j int) bool { return ks[idx[i]] < ks[idx[j]] })
		b = append(b, '{')
		for n, i := range idx {
			if n > 0 {
				b = append(b, ',')
			}
			b = append(appendJSONString(b, ks[i]), ':')
			var err error
			if b, err = appendJSON(b, v.MapIndex(keys[i])); err != nil {
				return b, err
			}
		}
		return append(b, '}'), nil
	case reflect.Struct:
		b = append(b, '{')
		first := true
		for _, f := range jsonFields(v.Type()) {
			fv, ok := fieldByIndex(v, f.index)
			if !ok || (f.omitEmpty && fv.IsZero()) {
				continue
			}
			if !first {
				b = append(b, ',')
			}
			first = false
			b = append(appendJSONString(b, f.name), ':')
			var err error
			if b, err = appendJSON(b, fv); err != nil {
				return b, err
			}
		}
		return append(b, '}'), nil
	}
	return b, errors.New("ts-gen: no JSON for " + v.Type().String())
}

func appendJSONString(b []byte, s string) []byte {
	const hex = "0123456789abcdef"
	b = append(b, '"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch {
			case c == '"' || c == '\\':
				b = append(b, '\\', c)
			case c == '\n':
				b = append(b, '\\', 'n')
			case c == '\r':
				b = append(b, '\\', 'r')
			case c == '\t':
				b = append(b, '\\', 't')
			case c < 0x20 || c == '<' || c == '>' || c == '&':
				// HTML-safe, as encoding/json writes it.
				b = append(b, '\\', 'u', '0', '0', hex[c>>4], hex[c&15])
			default:
				b = append(b, c)
			}
			i++
			continue
		}
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			b = append(b, `�`...)
		} else {
			b = append(b, s[i:i+n]...)
		}
		i += n
	}
	return append(b, '"')
}

type jsonField struct {
	name      string
	index     []int
	omitEmpty bool
}

var fieldCache = map[reflect.Type][]jsonField{}

// jsonFields are a struct's JSON fields in field order, embedded structs'
// fields in place of them; of fields with one name, the shallowest wins,
// as in encoding/json.
func jsonFields(t reflect.Type) []jsonField {
	if fs, ok := fieldCache[t]; ok {
		return fs
	}
	type cand struct {
		f     jsonField
		depth int
	}
	var all []cand
	var walk func(t reflect.Type, index []int, depth int)
	walk = func(t reflect.Type, index []int, depth int) {
		for i := range t.NumField() {
			sf := t.Field(i)
			tag := sf.Tag.Get("json")
			if tag == "-" {
				continue
			}
			name, opts, _ := strings.Cut(tag, ",")
			idx := append(append([]int{}, index...), i)
			if sf.Anonymous && name == "" {
				ft := sf.Type
				if ft.Kind() == reflect.Pointer {
					ft = ft.Elem()
				}
				if ft.Kind() == reflect.Struct {
					walk(ft, idx, depth+1)
					continue
				}
			}
			if !sf.IsExported() {
				continue
			}
			if name == "" {
				name = sf.Name
			}
			all = append(all, cand{jsonField{name, idx, strings.Contains(","+opts+",", ",omitempty,")}, depth})
		}
	}
	walk(t, nil, 0)
	best := map[string]int{}
	for _, c := range all {
		if d, ok := best[c.f.name]; !ok || c.depth < d {
			best[c.f.name] = c.depth
		}
	}
	var fs []jsonField
	seen := map[string]bool{}
	for _, c := range all {
		if c.depth == best[c.f.name] && !seen[c.f.name] {
			seen[c.f.name] = true
			fs = append(fs, c.f)
		}
	}
	fieldCache[t] = fs
	return fs
}

// fieldByIndex is v's field, or false through a nil embedded pointer.
func fieldByIndex(v reflect.Value, index []int) (reflect.Value, bool) {
	for i, x := range index {
		if i > 0 && v.Kind() == reflect.Pointer {
			if v.IsNil() {
				return reflect.Value{}, false
			}
			v = v.Elem()
		}
		v = v.Field(x)
	}
	return v, true
}

func jsonUnmarshal(data []byte, dst any) error {
	rv := reflect.ValueOf(dst)
	if rv.Kind() != reflect.Pointer || rv.IsNil() {
		return errors.New("ts-gen: Decode needs a non-nil pointer")
	}
	p := &jsonParser{s: data}
	t, err := p.value()
	if err != nil {
		return err
	}
	if p.skip(); p.i != len(p.s) {
		return p.err("text after the value")
	}
	return assignJSON(rv.Elem(), t)
}

// A parsed JSON value: nil, bool, float64, string, []any, or *jsonObject.
type jsonObject struct {
	keys []string
	vals map[string]any
}

type jsonParser struct {
	s []byte
	i int
}

func (p *jsonParser) err(what string) error {
	return errors.New("ts-gen: bad JSON at " + strconv.Itoa(p.i) + ": " + what)
}

func (p *jsonParser) skip() {
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\n' || p.s[p.i] == '\r' || p.s[p.i] == '\t') {
		p.i++
	}
}

func (p *jsonParser) lit(word string, v any) (any, error) {
	if !strings.HasPrefix(string(p.s[p.i:]), word) {
		return nil, p.err("a value")
	}
	p.i += len(word)
	return v, nil
}

func (p *jsonParser) value() (any, error) {
	p.skip()
	if p.i >= len(p.s) {
		return nil, p.err("end of input")
	}
	switch c := p.s[p.i]; {
	case c == 'n':
		return p.lit("null", nil)
	case c == 't':
		return p.lit("true", true)
	case c == 'f':
		return p.lit("false", false)
	case c == '"':
		return p.str()
	case c == '[':
		p.i++
		arr := []any{}
		if p.skip(); p.i < len(p.s) && p.s[p.i] == ']' {
			p.i++
			return arr, nil
		}
		for {
			v, err := p.value()
			if err != nil {
				return nil, err
			}
			arr = append(arr, v)
			p.skip()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == ']' {
				p.i++
				return arr, nil
			}
			return nil, p.err("',' or ']'")
		}
	case c == '{':
		p.i++
		obj := &jsonObject{vals: map[string]any{}}
		if p.skip(); p.i < len(p.s) && p.s[p.i] == '}' {
			p.i++
			return obj, nil
		}
		for {
			if p.skip(); p.i >= len(p.s) || p.s[p.i] != '"' {
				return nil, p.err("a key")
			}
			k, err := p.str()
			if err != nil {
				return nil, err
			}
			if p.skip(); p.i >= len(p.s) || p.s[p.i] != ':' {
				return nil, p.err("':'")
			}
			p.i++
			v, err := p.value()
			if err != nil {
				return nil, err
			}
			if _, dup := obj.vals[k]; !dup {
				obj.keys = append(obj.keys, k)
			}
			obj.vals[k] = v
			p.skip()
			if p.i < len(p.s) && p.s[p.i] == ',' {
				p.i++
				continue
			}
			if p.i < len(p.s) && p.s[p.i] == '}' {
				p.i++
				return obj, nil
			}
			return nil, p.err("',' or '}'")
		}
	default:
		start := p.i
		for p.i < len(p.s) && strings.IndexByte("+-0123456789.eE", p.s[p.i]) >= 0 {
			p.i++
		}
		f, err := strconv.ParseFloat(string(p.s[start:p.i]), 64)
		if err != nil || start == p.i {
			p.i = start
			return nil, p.err("a value")
		}
		return f, nil
	}
}

func (p *jsonParser) str() (string, error) {
	p.i++
	var b []byte
	for p.i < len(p.s) {
		c := p.s[p.i]
		switch {
		case c == '"':
			p.i++
			return string(b), nil
		case c == '\\':
			if p.i+1 >= len(p.s) {
				return "", p.err("an escape")
			}
			e := p.s[p.i+1]
			p.i += 2
			switch e {
			case 'b':
				b = append(b, '\b')
			case 'f':
				b = append(b, '\f')
			case 'n':
				b = append(b, '\n')
			case 'r':
				b = append(b, '\r')
			case 't':
				b = append(b, '\t')
			case 'u':
				r, ok := p.hex4()
				if !ok {
					return "", p.err("a \\u escape")
				}
				if r >= 0xd800 && r < 0xdc00 && p.i+1 < len(p.s) && p.s[p.i] == '\\' && p.s[p.i+1] == 'u' {
					p.i += 2
					lo, ok := p.hex4()
					if ok && lo >= 0xdc00 && lo < 0xe000 {
						r = 0x10000 + (r-0xd800)<<10 + (lo - 0xdc00)
					} else {
						r = utf8.RuneError
					}
				}
				b = utf8.AppendRune(b, r)
			default:
				b = append(b, e)
			}
		default:
			b = append(b, c)
			p.i++
		}
	}
	return "", p.err("an unterminated string")
}

func (p *jsonParser) hex4() (rune, bool) {
	if p.i+4 > len(p.s) {
		return 0, false
	}
	n, err := strconv.ParseUint(string(p.s[p.i:p.i+4]), 16, 32)
	p.i += 4
	return rune(n), err == nil
}

// plain is a parsed value as encoding/json gives it to an `any`.
func plain(t any) any {
	switch x := t.(type) {
	case *jsonObject:
		m := make(map[string]any, len(x.vals))
		for k, v := range x.vals {
			m[k] = plain(v)
		}
		return m
	case []any:
		for i, v := range x {
			x[i] = plain(v)
		}
	}
	return t
}

func typeErr(t any, to reflect.Type) error {
	what := "null"
	switch t.(type) {
	case bool:
		what = "a boolean"
	case float64:
		what = "a number"
	case string:
		what = "a string"
	case []any:
		what = "an array"
	case *jsonObject:
		what = "an object"
	}
	return errors.New("ts-gen: can't decode " + what + " into " + to.String())
}

func assignJSON(v reflect.Value, t any) error {
	if v.CanAddr() && v.Addr().Type().Implements(unmarshalerType) {
		b, err := jsonMarshal(plain(t))
		if err != nil {
			return err
		}
		return v.Addr().Interface().(jsonUnmarshaler).UnmarshalJSON(b)
	}
	if t == nil {
		switch v.Kind() {
		case reflect.Interface, reflect.Pointer, reflect.Map, reflect.Slice:
			v.SetZero()
		}
		return nil
	}
	switch v.Kind() {
	case reflect.Pointer:
		if v.IsNil() {
			v.Set(reflect.New(v.Type().Elem()))
		}
		return assignJSON(v.Elem(), t)
	case reflect.Interface:
		if v.NumMethod() != 0 {
			return typeErr(t, v.Type())
		}
		v.Set(reflect.ValueOf(plain(t)))
		return nil
	case reflect.Bool:
		if x, ok := t.(bool); ok {
			v.SetBool(x)
			return nil
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if x, ok := t.(float64); ok && x == math.Trunc(x) && !v.OverflowInt(int64(x)) {
			v.SetInt(int64(x))
			return nil
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		if x, ok := t.(float64); ok && x >= 0 && x == math.Trunc(x) && !v.OverflowUint(uint64(x)) {
			v.SetUint(uint64(x))
			return nil
		}
	case reflect.Float32, reflect.Float64:
		if x, ok := t.(float64); ok {
			v.SetFloat(x)
			return nil
		}
	case reflect.String:
		if x, ok := t.(string); ok {
			v.SetString(x)
			return nil
		}
	case reflect.Slice:
		if x, ok := t.(string); ok && v.Type().Elem().Kind() == reflect.Uint8 {
			b, err := base64.StdEncoding.DecodeString(x)
			if err != nil {
				return err
			}
			v.SetBytes(b)
			return nil
		}
		if x, ok := t.([]any); ok {
			s := reflect.MakeSlice(v.Type(), len(x), len(x))
			for i, e := range x {
				if err := assignJSON(s.Index(i), e); err != nil {
					return err
				}
			}
			v.Set(s)
			return nil
		}
	case reflect.Array:
		if x, ok := t.([]any); ok {
			for i := range v.Len() {
				if i < len(x) {
					if err := assignJSON(v.Index(i), x[i]); err != nil {
						return err
					}
				} else {
					v.Index(i).SetZero()
				}
			}
			return nil
		}
	case reflect.Map:
		if x, ok := t.(*jsonObject); ok {
			kt := v.Type().Key()
			if v.IsNil() {
				v.Set(reflect.MakeMapWithSize(v.Type(), len(x.keys)))
			}
			for _, k := range x.keys {
				kv := reflect.New(kt).Elem()
				switch kt.Kind() {
				case reflect.String:
					kv.SetString(k)
				case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
					n, err := strconv.ParseInt(k, 10, 64)
					if err != nil {
						return err
					}
					kv.SetInt(n)
				case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
					n, err := strconv.ParseUint(k, 10, 64)
					if err != nil {
						return err
					}
					kv.SetUint(n)
				default:
					return typeErr(t, v.Type())
				}
				ev := reflect.New(v.Type().Elem()).Elem()
				if err := assignJSON(ev, x.vals[k]); err != nil {
					return err
				}
				v.SetMapIndex(kv, ev)
			}
			return nil
		}
	case reflect.Struct:
		if x, ok := t.(*jsonObject); ok {
			fs := jsonFields(v.Type())
			for _, k := range x.keys {
				var f *jsonField
				for i := range fs {
					if fs[i].name == k {
						f = &fs[i]
						break
					}
				}
				if f == nil {
					for i := range fs {
						if strings.EqualFold(fs[i].name, k) {
							f = &fs[i]
							break
						}
					}
				}
				if f == nil {
					continue
				}
				fv := v
				for n, idx := range f.index {
					if n > 0 && fv.Kind() == reflect.Pointer {
						if fv.IsNil() {
							fv.Set(reflect.New(fv.Type().Elem()))
						}
						fv = fv.Elem()
					}
					fv = fv.Field(idx)
				}
				if err := assignJSON(fv, x.vals[k]); err != nil {
					return err
				}
			}
			return nil
		}
	}
	return typeErr(t, v.Type())
}
