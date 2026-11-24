#!/bin/bash
# Runs probe.py on Pyodide (workerd's Python Workers, wrangler.toml) and on
# this Worker (wrangler-ours.toml), and diffs the two outputs:
#
#   ffi-diff/run.sh [pyodide-port] [ours-port]
#
# Each side gets three requests: the probe, then /stash and /after, which
# check what a function passed to JS in one request does in the next.
# Exits non-zero on any difference.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P1=${1:-9000} P2=${2:-9001}
WRANGLER=${WRANGLER:-$HERE/../node_modules/.bin/wrangler}
[ -n "${SKIP_BUILD:-}" ] || (cd "$HERE/.." && APP=ffi-diff OUTDIR=ffi-diff/out ./build.sh >/dev/null)
run() { # label, port, config
  local log=/tmp/ffi-diff-$1.log
  (cd "$HERE" && rm -rf .wrangler && WRANGLER_SEND_METRICS=false "$WRANGLER" dev -c "$3" --port "$2" --ip 127.0.0.1 >"$log" 2>&1) &
  local pid=$!
  for _ in $(seq 300); do grep -q "Ready on" "$log" && break; sleep 0.5; done
  curl -s "http://127.0.0.1:$2/" >"$HERE/out-$1.txt"
  curl -s "http://127.0.0.1:$2/stash" >/dev/null
  curl -s "http://127.0.0.1:$2/after" >>"$HERE/out-$1.txt"
  pkill -P $pid 2>/dev/null || true
  kill $pid 2>/dev/null || true
  for p in $(lsof -nP -t -iTCP:"$2" -sTCP:LISTEN 2>/dev/null); do kill "$p" 2>/dev/null || true; done
}
[ -n "${SKIP_PYODIDE:-}" ] || run pyodide "$P1" wrangler.toml
run ours "$P2" wrangler-ours.toml
if diff -u "$HERE/out-pyodide.txt" "$HERE/out-ours.txt"; then
  echo "ffi-diff: $(wc -l <"$HERE/out-ours.txt" | tr -d ' ') lines, no differences"
else
  exit 1
fi
