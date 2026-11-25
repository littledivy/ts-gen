package main

import (
	"encoding/json"
	"errors"
)

func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

// wasmInterface reads a module's imports (module, name) and export names.
func wasmInterface(b []byte) (imports [][2]string, exports []string, err error) {
	if len(b) < 8 || string(b[:4]) != "\x00asm" {
		return nil, nil, errors.New("not a Wasm module")
	}
	i := 8
	leb := func() uint32 {
		var v uint32
		var shift uint
		for {
			c := b[i]
			i++
			v |= uint32(c&0x7f) << shift
			if c&0x80 == 0 {
				return v
			}
			shift += 7
		}
	}
	name := func() string {
		n := int(leb())
		s := string(b[i : i+n])
		i += n
		return s
	}
	for i < len(b) {
		id := b[i]
		i++
		size := int(leb())
		end := i + size
		switch id {
		case 2:
			n := int(leb())
			for k := 0; k < n; k++ {
				mod, nm := name(), name()
				kind := b[i]
				i++
				switch kind {
				case 0:
					leb()
				case 1: // table: reftype, limits
					i++
					if b[i] == 1 {
						i++
						leb()
						leb()
					} else {
						i++
						leb()
					}
				case 2: // memory
					flags := b[i]
					i++
					leb()
					if flags&1 != 0 {
						leb()
					}
				case 3: // global
					i += 2
				case 4: // tag
					i++
					leb()
				}
				imports = append(imports, [2]string{mod, nm})
			}
		case 7:
			n := int(leb())
			for k := 0; k < n; k++ {
				exports = append(exports, name())
				i++
				leb()
			}
		}
		i = end
	}
	return imports, exports, nil
}
