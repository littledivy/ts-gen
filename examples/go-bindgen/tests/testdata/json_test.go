// A differential test of the runtime's JSON codec (runtime/json.go)
// against encoding/json. tests/go.rs copies both into one package and runs
// it natively: the codec names nothing wasm-only.
package codec

import (
	"encoding/json"
	"reflect"
	"testing"
)

type inner struct {
	A int `json:"a"`
}

type Embedded struct {
	E string
}

type sample struct {
	Embedded
	Name    string            `json:"name"`
	Skip    string            `json:"-"`
	Empty   string            `json:"empty,omitempty"`
	Num     float64           `json:"num"`
	Int     int64             `json:"int"`
	Uint    uint8             `json:"uint"`
	Ok      bool              `json:"ok"`
	Ptr     *inner            `json:"ptr"`
	Nil     *inner            `json:"nil"`
	List    []inner           `json:"list"`
	Bytes   []byte            `json:"bytes"`
	Map     map[string]int    `json:"map"`
	IntKeys map[int]string    `json:"intKeys"`
	Any     any               `json:"any"`
	Arr     [2]string         `json:"arr"`
	Nested  map[string][]bool `json:"nested"`
	private int
}

func values() []any {
	return []any{
		nil, true, 0, -3, 1.5, 1e21, 1e-7, 123456789.125, "", "a\"b\\c\n\t\x01<>&é😀",
		[]int{1, 2}, []string(nil), map[string]any{"z": 1, "a": []any{"x", nil}},
		sample{
			Embedded: Embedded{"e"}, Name: "n", Skip: "s", Num: 2.25, Int: -9, Uint: 7, Ok: true,
			Ptr: &inner{4}, List: []inner{{1}, {2}}, Bytes: []byte("hi"),
			Map: map[string]int{"b": 2, "a": 1}, IntKeys: map[int]string{2: "two", 10: "ten"},
			Any: map[string]any{"k": []any{1.0, "v"}}, Arr: [2]string{"x", "y"},
			Nested: map[string][]bool{"t": {true}},
		},
	}
}

func TestMarshal(t *testing.T) {
	for _, v := range values() {
		want, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		got, err := jsonMarshal(v)
		if err != nil {
			t.Fatalf("%#v: %v", v, err)
		}
		if string(got) != string(want) {
			t.Errorf("marshal %#v:\n got %s\nwant %s", v, got, want)
		}
	}
}

func TestUnmarshal(t *testing.T) {
	for _, v := range values() {
		text, _ := json.Marshal(v)
		for _, typ := range []reflect.Type{reflect.TypeOf(v), reflect.TypeFor[any]()} {
			if typ == nil {
				typ = reflect.TypeFor[any]()
			}
			want := reflect.New(typ)
			got := reflect.New(typ)
			if err := json.Unmarshal(text, want.Interface()); err != nil {
				t.Fatal(err)
			}
			if err := jsonUnmarshal(text, got.Interface()); err != nil {
				t.Fatalf("%s into %s: %v", text, typ, err)
			}
			if !reflect.DeepEqual(got.Elem().Interface(), want.Elem().Interface()) {
				t.Errorf("unmarshal %s into %s:\n got %#v\nwant %#v", text, typ, got.Elem().Interface(), want.Elem().Interface())
			}
		}
	}
	// Keys match fields case-insensitively, and unknown keys are ignored.
	var s struct{ UserName string }
	if err := jsonUnmarshal([]byte(`{"username":"u","other":1}`), &s); err != nil || s.UserName != "u" {
		t.Errorf("case-folded key: %+v %v", s, err)
	}
	// Escapes, surrogate pairs and whitespace.
	var str string
	if err := jsonUnmarshal([]byte(" \"\\u00e9\\ud83d\\ude00\\/\" "), &str); err != nil || str != "é😀/" {
		t.Errorf("escapes: %q %v", str, err)
	}
	for _, bad := range []string{``, `{`, `[1,]`, `"x`, `tru`, `1 2`, `{"a" 1}`} {
		var v any
		if jsonUnmarshal([]byte(bad), &v) == nil {
			t.Errorf("%q decoded", bad)
		}
	}
	var n int
	if jsonUnmarshal([]byte(`"7"`), &n) == nil {
		t.Error("a string decoded into an int")
	}
}
