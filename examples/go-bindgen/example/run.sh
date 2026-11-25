#!/usr/bin/env bash
# Builds the Go worker end to end into out/:
#   ts-gen --ir -> ts-gen-abi lower -> go-bindgen -> go build (wasip1
#   reactor, twice) -> go-bindgen shim, merged in -> ts-gen-bridge generate.
# `./run.sh serve` then serves it in workerd and curls every route;
# `./run.sh node` runs them in node.
#
# Env: WORKERD (else `workerd` on PATH), PORT (else 8977). Needs Go 1.24+, wasm-tools and
# binaryen's wasm-merge.
set -euo pipefail
EX="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$EX/../../.." && pwd)"
B="$EX/build"
OUT="$EX/out"
BIN="$ROOT/target/debug"
STD="$ROOT/std/std.ir"
PROFILE="all-linear, jspi = on"
# What the bindings start from; everything their members reach comes along.
ROOTS=Request,Response,Headers,URL,DurableObjectNamespace,DurableObjectState,Fetcher,HTMLRewriter,atob

(cd "$ROOT" && cargo build --quiet --bins -p ts-gen -p ts-gen-abi -p ts-gen-bridge)
rm -rf "$B" "$OUT"
mkdir -p "$B" "$OUT"
GEN="$B/go-bindgen"
(cd "$EX/.." && go build -o "$GEN" .)

# 1. The IR: workers-types and the bindings of env.d.ts, with the errors
#    of annotate.d.ts, the JS standard library resolved against std.ir,
#    what the module provides (provides.d.ts), and go-bindgen's runtime
#    declarations.
"$BIN/ts-gen" -i "$ROOT/tests/fixtures/workers-types.d.ts" -i "$EX/env.d.ts" \
  --annotate "$EX/annotate.d.ts" --with "$STD" \
  --provides "$EX/provides.d.ts" --ir "$B/worker.ir" 2>/dev/null
"$GEN" runtime-ir >> "$B/worker.ir"

# 2. The bindings: one package, `workers`, with std's declarations the
#    worker's reach; and the package-main glue for app.go's handlers.
"$BIN/ts-gen-abi" lower "$STD" --profile "$PROFILE" > "$B/std.json"
"$BIN/ts-gen-abi" lower "$B/worker.ir" --with "$STD" --profile "$PROFILE" > "$B/worker.json"
bindings() {
  "$GEN" bindings "$B/worker.json" --lib "$B/std.json" --out "$EX/workers" --package workers \
    --roots "$ROOTS" --main "$EX/exports.go" --import example/workers "$@" >/dev/null
}

# 3. The module, twice: callbacks' trampolines are kept for the imports
#    the first build uses.
gobuild() { (cd "$EX" && GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -trimpath -ldflags="-s -w" -o "$1" .); }
bindings --no-callbacks
gobuild "$B/pass1.wasm"
bindings --callbacks-for "$B/pass1.wasm"
gobuild "$B/go.wasm"

# 4. The shim, for exactly the imports and exports the module has, merged
#    in; then the bridge for the result.
"$GEN" shim "$EX/workers/manifest.json" "$B/go.wasm" -o "$B/shim.wat"
wasm-tools parse "$B/shim.wat" -o "$B/shim.wasm"
wasm-merge "$B/go.wasm" go "$B/shim.wasm" shim -o "$OUT/worker.wasm" \
  --enable-reference-types --enable-exception-handling --enable-multivalue --enable-bulk-memory \
  --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int --enable-simd 2>&1 | grep -v "name subsection" || true
"$BIN/ts-gen-bridge" generate "$B/worker.ir" "$OUT/worker.wasm" --with "$STD" --profile "$PROFILE" -o "$OUT"
cp "$EX/loader.js" "$EX/wasi.js" "$EX/backend.js" "$EX/config.capnp" "$EX/node.mjs" "$EX/tour.mjs" "$OUT/"
echo "built $OUT ($(wc -c < "$OUT/worker.wasm" | tr -d " ") bytes)"

case "${1:-}" in
  node) node "$OUT/node.mjs" ;;
  serve)
    mkdir -p "$OUT/storage"
    (cd "$OUT" && exec "${WORKERD:-workerd}" serve config.capnp --experimental --socket-addr "http=127.0.0.1:${PORT:-8977}" 2> workerd.log) &
    pid=$!
    trap 'kill $pid 2>/dev/null' EXIT
    U=http://127.0.0.1:${PORT:-8977}
    for _ in $(seq 1 50); do curl -s -o /dev/null $U/ && break; sleep 0.2; done
    curl -s -o /dev/null $U/ || { cat "$OUT/workerd.log" >&2; exit 1; }
    node "$OUT/tour.mjs" $U
    ;;
esac
