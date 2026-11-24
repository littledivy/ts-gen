#!/usr/bin/env bash
# Builds probe.ir's exports in Go through the bridge into out/, then runs
# test.mjs against them in node:
#   ts-gen-abi lower -> go-bindgen -> go build (wasip1 reactor) -> the
#   generated shim, merged in -> ts-gen-bridge generate.
# Needs Go 1.24+, wasm-tools and binaryen's wasm-merge.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
B="$DIR/build"
OUT="$DIR/out"
BIN="$ROOT/target/debug"
PROFILE="all-linear, jspi = on"

(cd "$ROOT" && cargo build --quiet --bins -p ts-gen-abi -p ts-gen-bridge)
rm -rf "$B" "$OUT"
mkdir -p "$B/app/probe" "$OUT"
GEN="$B/go-bindgen"
(cd "$DIR/../.." && go build -o "$GEN" .)
cat "$DIR/probe.ir" > "$B/probe.ir"
"$GEN" runtime-ir >> "$B/probe.ir"
"$BIN/ts-gen-abi" lower "$B/probe.ir" --profile "$PROFILE" > "$B/probe.json"
cp "$DIR/app.go" "$B/app/"
printf 'module app\n\ngo 1.24\n' > "$B/app/go.mod"
bindings() { "$GEN" bindings "$B/probe.json" --out "$B/app/probe" --package probe --main "$B/app/exports.go" --import app/probe "$@" >/dev/null; }
gobuild() { (cd "$B/app" && GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o "$1" .); }
# Twice: callbacks' trampolines are kept for the imports the app uses.
bindings --no-callbacks
gobuild "$B/pass1.wasm"
bindings --callbacks-for "$B/pass1.wasm"
gobuild "$B/go.wasm"
"$GEN" shim "$B/app/probe/manifest.json" "$B/go.wasm" -o "$B/shim.wat"
wasm-tools parse "$B/shim.wat" -o "$B/shim.wasm"
wasm-merge "$B/go.wasm" go "$B/shim.wasm" shim -o "$OUT/probe.wasm" \
  --enable-reference-types --enable-exception-handling --enable-multivalue --enable-bulk-memory \
  --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int --enable-simd 2>&1 | grep -v "name subsection" || true
"$BIN/ts-gen-bridge" generate "$B/probe.ir" "$OUT/probe.wasm" --profile "$PROFILE" -o "$OUT"
cp "$DIR/test.mjs" "$OUT/"
node "$OUT/test.mjs"
