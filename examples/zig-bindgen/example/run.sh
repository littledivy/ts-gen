#!/usr/bin/env bash
# Builds the Zig worker end to end into out/:
#   ts-gen --ir (+ zig-bindgen runtime-ir) -> ts-gen-abi lower
#   -> zig-bindgen bindings -> zig build-exe -> zig-bindgen shim
#   -> wasm-merge -> ts-gen-bridge generate --factory.
# `./run.sh serve` then serves it in workerd and curls every route;
# `./run.sh node` runs the routes node can serve.
#
# Env: WORKERD (else `workerd` on PATH); TSGEN_ZIG_BUILT when zig-bindgen
# is already built. Needs Zig 0.17 and binaryen's wasm-merge.
set -euo pipefail
EX="$(cd "$(dirname "$0")" && pwd)"
ZB="$(cd "$EX/.." && pwd)"
ROOT="$(cd "$EX/../../.." && pwd)"
B="$EX/build"
OUT="$EX/out"
BIN="$ROOT/target/debug"
STD="$ROOT/std/std.ir"
PROFILE="all-linear, jspi = on"
GEN="$ZB/zig-out/bin/zig-bindgen"

(cd "$ROOT" && cargo build --quiet --bins -p ts-gen -p ts-gen-abi -p ts-gen-bridge)
[ -n "${TSGEN_ZIG_BUILT:-}" ] || (cd "$ZB" && zig build)
rm -rf "$B" "$OUT"
mkdir -p "$B" "$OUT"

# 1. The IR: workers-types and the bindings of env.d.ts, with the ABI
#    choices of annotate.d.ts, the JS standard library resolved against
#    std.ir, and what the module provides (provides.d.ts); then the
#    declarations the Zig runtime needs.
"$BIN/ts-gen" -i "$ROOT/tests/fixtures/workers-types.d.ts" -i "$EX/env.d.ts" \
  --annotate "$EX/annotate.d.ts" --with "$STD" \
  --provides "$EX/provides.d.ts" --ir "$B/worker.ir" 2>/dev/null
"$GEN" runtime-ir >> "$B/worker.ir"

# 2. The bindings, for the declarations the app starts from and everything
#    their members reach.
"$BIN/ts-gen-abi" lower "$STD" --profile "$PROFILE" > "$B/std.json"
"$BIN/ts-gen-abi" lower "$B/worker.ir" --with "$STD" --profile "$PROFILE" > "$B/worker.json"
ROOTS=URL,URLSearchParams,Request,Response,Headers,Fetcher,DurableObjectNamespace,DurableObjectState,HTMLRewriter,atob
"$GEN" bindings "$B/worker.json" --lib "$B/std.json" --out "$B/gen" --roots "$ROOTS" --runtime 2>/dev/null
(cd "$EX" && zig build-exe app.zig -target wasm32-freestanding -fno-entry -rdynamic -O ReleaseSmall \
  --cache-dir "$B/zig-cache" -femit-bin="$B/zig.wasm")

# 3. The shim, for exactly what the module imports and exports, merged in
#    (binaryen's wasm-merge; each feature named, as `-all` writes import
#    encodings V8 doesn't read): Zig can't name externref, so the shim
#    holds JS values in the table and hands Zig their slots. Then the
#    exports only the shim used go.
"$GEN" shim "$B/gen/manifest.json" "$B/zig.wasm" -o "$B/shim.wat"
wasm-merge "$B/zig.wasm" zig "$B/shim.wat" shim -o "$B/merged.wasm" \
  --enable-reference-types --enable-exception-handling --enable-multivalue --enable-bulk-memory \
  --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int 2>&1 \
  | { grep -v "name subsection" || true; }
"$GEN" strip "$B/merged.wasm" -o "$OUT/worker.wasm"

# 4. The bridge, as a factory: loader.js keeps a pool of instances.
"$BIN/ts-gen-bridge" generate "$B/worker.ir" "$OUT/worker.wasm" --with "$STD" --profile "$PROFILE" --factory -o "$OUT"
cp "$EX/loader.js" "$EX/backend.js" "$EX/config.capnp" "$EX/node.mjs" "$OUT/"
echo "built $OUT"

case "${1:-}" in
  node) node "$OUT/node.mjs" ;;
  serve)
    mkdir -p "$OUT/storage"
    (cd "$OUT" && exec "${WORKERD:-workerd}" serve config.capnp --experimental 2> workerd.log) &
    pid=$!
    trap 'kill $pid 2>/dev/null' EXIT
    U=http://127.0.0.1:8962
    for _ in $(seq 1 50); do curl -s -o /dev/null $U/ && break; sleep 0.2; done
    curl -s -o /dev/null $U/ || { cat "$OUT/workerd.log" >&2; exit 1; }

    # The tour: each route's reply, under the request that got it.
    get() { printf '\n== %s\n' "$1"; shift; curl -s "$@"; }
    get 'GET /' $U/
    get 'POST /echo' -H 'x-zig: hi' -d 'Hello!' $U/echo
    get 'GET /url?tag=a&tag=b&q=zig' "$U/url?tag=a&tag=b&q=zig"
    get 'POST /json' -d '{"item":"tea","quantity":2,"tags":["hot","green"]}' $U/json
    echo
    get 'POST /json (not an order)' -d '{"item":"tea"}' $U/json
    echo
    get 'GET /rewrite' $U/rewrite
    get 'GET /errors' $U/errors
    get 'GET /fetch' $U/fetch
    get 'GET /counter' $U/counter
    get 'GET /counter (again)' $U/counter
    ;;
esac
