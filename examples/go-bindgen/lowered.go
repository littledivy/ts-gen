package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// The JSON `ts-gen-abi lower` writes: declarations, and each member's
// signature with every value's wire layout (IR.md §11-§19).

type Lowered struct {
	Profile map[string]string `json:"profile"`
	Lib     *string           `json:"lib"`
	Decls   []*Decl           `json:"decls"`
	Members []*Member         `json:"members"`
}

type Decl struct {
	Kind    string      `json:"kind"`
	Path    string      `json:"path"`
	Module  *string     `json:"module"`
	Name    string      `json:"name"`
	JSName  *string     `json:"jsName"`
	Export  bool        `json:"export"`
	Tparams []Tparam    `json:"tparams"`
	Extends []string    `json:"extends"`
	Doc     *string     `json:"doc"`
	Layout  *EnumLayout `json:"layout"`
}

type Tparam struct {
	Name string `json:"name"`
}

type Member struct {
	Key       string      `json:"key"`
	Role      string      `json:"role"`
	Module    *string     `json:"module"`
	Owner     *string     `json:"owner"`
	Namespace []string    `json:"namespace"`
	Kind      string      `json:"kind"`
	Name      string      `json:"name"`
	Variant   string      `json:"variant"`
	Static    bool        `json:"static"`
	JSName    *string     `json:"jsName"`
	Tparams   []Tparam    `json:"tparams"`
	Params    []ParamMeta `json:"params"`
	Doc       *string     `json:"doc"`
	Sig       Sig         `json:"sig"`
}

func (m *Member) owner() string {
	if m.Owner == nil {
		return ""
	}
	return *m.Owner
}

type ParamMeta struct {
	Name   string `json:"name"`
	Spread bool   `json:"spread"`
	Once   bool   `json:"once"`
}

type Sig struct {
	Params  []SigParam  `json:"params"`
	Results []SigResult `json:"results"`
	Throws  *Throws     `json:"throws"`
	Core    Core        `json:"core"`
}

type SigParam struct {
	Role  string   `json:"role"`
	Index int      `json:"index"`
	Repr  *Repr    `json:"repr"`
	Wire  []string `json:"wire"`
}

type SigResult struct {
	Role string `json:"role"`
	Repr *Repr  `json:"repr"`
}

type Throws struct {
	Tag  Op          `json:"tag"`
	Enum *EnumLayout `json:"enum"`
}

type Core struct {
	Params  []string `json:"params"`
	Results []string `json:"results"`
}

// Op names a protocol import. A function type's box and unbox nest it
// under "import".
type Op struct {
	Module string `json:"module"`
	Name   string `json:"name"`
	Import *Op    `json:"import"`
}

func (o *Op) imp() Op {
	if o.Import != nil {
		return *o.Import
	}
	return Op{Module: o.Module, Name: o.Name}
}

// Repr is one value's representation: its kind and wire, and what the kind
// adds (IR.md §3, §10-§18).
type Repr struct {
	Ty       string          `json:"ty"`
	Wire     []string        `json:"wire"`
	Kind     string          `json:"kind"`
	Nullable bool            `json:"nullable"`
	Scalar   string          `json:"scalar"`
	Niche    json.RawMessage `json:"niche"`
	Carrier  string          `json:"carrier"`
	Of       string          `json:"of"`
	Path     string          `json:"path"`
	Inner    *Repr           `json:"inner"`
	Box      *Op             `json:"box"`
	Unbox    *Op             `json:"unbox"`
	// future
	Value     *Repr       `json:"value"`
	Rejection *EnumLayout `json:"rejection"`
	Take      *Op         `json:"take"`
	ErrorOp   *Op         `json:"errorOp"`
	// array (a Repr) or vec (a scalar name)
	RawElem json.RawMessage `json:"elem"`
	Elems   []*Repr         `json:"elems"`
	// fn
	Params     []*Repr `json:"params"`
	Result     *Repr   `json:"result"`
	FnThrows   *Throws `json:"throws"`
	Trampoline string  `json:"trampoline"`
	Call       *Op     `json:"call"`
	// handle
	Class string `json:"class"`
	// enum
	Enum *EnumLayout `json:"enum"`

	elem    *Repr
	vecElem string
}

func (r *Repr) hasNiche() bool {
	return len(r.Niche) > 0 && string(r.Niche) != "null"
}

// Elem is an array's element.
func (r *Repr) Elem() *Repr {
	if r.elem == nil && len(r.RawElem) > 0 && r.RawElem[0] == '{' {
		r.elem = new(Repr)
		if err := json.Unmarshal(r.RawElem, r.elem); err != nil {
			panic(err)
		}
	}
	return r.elem
}

// VecElem is a typed array's element scalar.
func (r *Repr) VecElem() string {
	if r.vecElem == "" && len(r.RawElem) > 0 && r.RawElem[0] == '"' {
		_ = json.Unmarshal(r.RawElem, &r.vecElem)
	}
	return r.vecElem
}

func (r *Repr) withNullable(n bool) *Repr {
	c := *r
	c.Nullable = n
	return &c
}

type EnumLayout struct {
	Path   string `json:"path"`
	Origin string `json:"origin"`
	Shape  struct {
		Kind   string   `json:"kind"`
		Slots  []string `json:"slots"`
		Scalar string   `json:"scalar"`
	} `json:"shape"`
	Arms []*Arm `json:"arms"`
}

type Arm struct {
	Name     string          `json:"name"`
	Index    int64           `json:"index"`
	Fallback bool            `json:"fallback"`
	Literal  json.RawMessage `json:"literal"`
	Payload  []*Repr         `json:"payload"`
	Slots    []int           `json:"slots"`
}

func readLowered(path string) (*Lowered, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var l Lowered
	if err := json.Unmarshal(b, &l); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &l, nil
}
