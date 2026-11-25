#!/usr/bin/env bash
# Builds the Swift worker end to end into out/:
#   ts-gen --ir (+ swift-bindgen runtime-ir) -> ts-gen-abi lower
#   -> swift-bindgen bindings -> swiftc -> swift-bindgen shim -> wasm-merge
#   -> ts-gen-bridge generate --factory.
# `./run.sh serve` then serves it in workerd and curls every route;
# `./run.sh node` runs the routes node can serve.
#
# Env: WORKERD (else `workerd` on PATH); PORT (else 8951) for `serve`; SWIFT_TOOLCHAIN and SWIFT_SDK as
# ../swiftc-wasm.sh reads them; TSGEN_SWIFT_BUILT when swift-bindgen is
# already built.
set -euo pipefail
EX="$(cd "$(dirname "$0")" && pwd)"
SB="$(cd "$EX/.." && pwd)"
ROOT="$(cd "$EX/../../.." && pwd)"
B="$EX/build"
OUT="$EX/out"
BIN="$ROOT/target/debug"
STD="$ROOT/std/std.ir"
PROFILE="all-linear, jspi = on"
GEN="${SWIFT_BINDGEN:-$SB/.build/release/swift-bindgen}"

(cd "$ROOT" && cargo build --quiet --bins -p ts-gen -p ts-gen-abi -p ts-gen-bridge)
[ -n "${TSGEN_SWIFT_BUILT:-}" ] || swift build --quiet -c release --package-path "$SB"
rm -rf "$B" "$OUT"
mkdir -p "$B/gen" "$OUT"

# 1. The IR: workers-types and the bindings of env.d.ts, with the ABI
#    choices of annotate.d.ts, the JS standard library resolved against
#    std.ir, and what the module provides (provides.d.ts); then the
#    declarations the Swift runtime needs.
"$BIN/ts-gen" -i "$ROOT/tests/fixtures/workers-types.d.ts" -i "$EX/env.d.ts" \
  --annotate "$EX/annotate.d.ts" --with "$STD" \
  --provides "$EX/provides.d.ts" --ir "$B/worker.ir" 2>/dev/null
"$GEN" runtime-ir >> "$B/worker.ir"

# 2. The bindings, for the declarations the app starts from and everything
#    their members reach. Twice: a callback's trampoline is exported only
#    for the imports the app uses, which the first link tells.
"$BIN/ts-gen-abi" lower "$STD" --profile "$PROFILE" > "$B/std.json"
"$BIN/ts-gen-abi" lower "$B/worker.ir" --with "$STD" --profile "$PROFILE" > "$B/worker.json"
ROOTS=URL,Request,Response,Headers,Fetcher,DurableObjectNamespace,DurableObjectState,HTMLRewriter,Crypto,Scheduler,crypto,scheduler,atob
bindings() { "$GEN" bindings "$B/worker.json" --lib "$B/std.json" --out "$B/gen" --roots "$ROOTS" --runtime "$@" >/dev/null; }
swiftc() {
  "$SB/swiftc-wasm.sh" -module-name SwiftWorker \
    -Xcc -fmodule-map-file="$B/gen/include/module.modulemap" -I "$B/gen/include" \
    "$EX/App.swift" "$B/gen/Runtime.swift" "$B/gen/Bindings.swift" "$@"
}
bindings --no-callbacks
swiftc -o "$B/pass1.wasm"
bindings --callbacks-for "$B/pass1.wasm"
swiftc -o "$B/swift.wasm"

# 3. The shim, for exactly what the module imports and exports, merged in
#    (binaryen's wasm-merge; each feature named, as `-all` writes import
#    encodings V8 doesn't read): Swift can't name externref, so the shim
#    holds JS values in the table and hands Swift their slots.
"$GEN" shim "$B/gen/manifest.json" "$B/swift.wasm" -o "$B/shim.wat"
wasm-merge "$B/swift.wasm" swift "$B/shim.wat" shim -o "$OUT/worker.wasm" \
  --enable-reference-types --enable-exception-handling --enable-multivalue --enable-bulk-memory \
  --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int --enable-simd 2>&1 \
  | { grep -v "name subsection" || true; }

# 4. The bridge, as a factory: loader.js keeps a pool of instances.
"$BIN/ts-gen-bridge" generate "$B/worker.ir" "$OUT/worker.wasm" --with "$STD" --profile "$PROFILE" --factory -o "$OUT"
cp "$EX/loader.js" "$EX/wasi.js" "$EX/backend.js" "$EX/config.capnp" "$EX/node.mjs" "$OUT/"
echo "built $OUT"

case "${1:-}" in
  node) node "$OUT/node.mjs" ;;
  serve)
    mkdir -p "$OUT/storage"
    PORT="${PORT:-8951}"
    (cd "$OUT" && exec "${WORKERD:-workerd}" serve config.capnp --experimental --socket-addr "http=127.0.0.1:$PORT" 2> workerd.log) &
    pid=$!
    trap 'kill $pid 2>/dev/null' EXIT
    U=http://127.0.0.1:$PORT
    for _ in $(seq 1 50); do curl -s -o /dev/null $U/ && break; sleep 0.2; done
    curl -s -o /dev/null $U/ || { cat "$OUT/workerd.log" >&2; exit 1; }

    # The tour: each route's reply, under the request that got it.
    get() { printf '\n== %s\n' "$1"; shift; curl -s "$@"; }
    get 'GET /' $U/
    get 'POST /echo' -H 'x-swift: hi' -d 'Hello!' $U/echo
    get 'GET /url?tag=a&tag=b&q=swift' "$U/url?tag=a&tag=b&q=swift"
    get 'POST /json' -d '{"item":"tea","quantity":2,"tags":["hot","green"]}' $U/json
    get 'POST /json (not an order)' -d '{"item":"tea"}' $U/json
    get 'GET /crypto' $U/crypto
    get 'GET /timers' $U/timers
    get 'GET /rewrite' $U/rewrite
    get 'GET /errors' $U/errors
    get 'GET /fetch' $U/fetch
    get 'GET /counter' $U/counter
    get 'GET /counter (again)' $U/counter
    ;;
esac
