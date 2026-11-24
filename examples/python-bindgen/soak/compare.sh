#!/bin/bash
# Cold start and load for one Worker under `wrangler dev`:
#
#   soak/compare.sh <label> <dir with wrangler.toml> <port> <routes> [body]
#
# Starts `wrangler dev` with fresh local state and waits for its "Ready"
# line. The first request then goes to the first route's path, timed by
# curl, with the CPU time (ps) of wrangler's workerd processes (a proxy and
# the one running the Worker) read at ready and after it. Then soak/load.mjs runs
# each route at -c 50 and -c 200 (Z, default 10s, each) after 2s of warmup.
# Results go to /tmp/compare-<label>.json.
set -euo pipefail
label=$1 dir=$2 port=$3 routes=$4 body=${5:-}
HERE=$(cd "$(dirname "$0")" && pwd)
WRANGLER=${WRANGLER:-$HERE/../node_modules/.bin/wrangler}
log=/tmp/compare-$label.log
if lsof -nP -t -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is in use" >&2; exit 1; fi
cd "$dir" && rm -rf .wrangler
t0=$(python3 -c 'import time; print(time.time())')
WRANGLER_SEND_METRICS=false "$WRANGLER" dev --port $port --ip 127.0.0.1 >"$log" 2>&1 &
pid=$!
stop() { pkill -P $pid 2>/dev/null || true; kill $pid 2>/dev/null || true; for p in $(lsof -nP -t -iTCP:$port -sTCP:LISTEN 2>/dev/null); do kill $p 2>/dev/null || true; done; }
trap stop EXIT
until grep -q "Ready on" "$log"; do
  grep -q -e "failed to start" -e "ERROR" "$log" && { cat "$log" >&2; exit 1; }
  sleep 0.05
done
t1=$(python3 -c 'import time; print(time.time())')
desc() { for c in $(pgrep -P "$1"); do echo "$c"; desc "$c"; done; }
wds=$(for p in $(desc $pid); do ps -o comm= -p $p | grep -q workerd && echo $p; done | tr '\n' ',' | sed 's/,$//')
cpu() { ps -o time= -p "$wds" | awk -F: '{s += $1*60+$2} END {print s}'; }
rss() { ps -o rss= -p "$wds" | sort -n | tail -1; }
first=${routes%%,*}
first=${first##* }
c0=$(cpu)
ft=$(curl -s -o /dev/null -w "%{time_total}" "http://127.0.0.1:$port$first")
c1=$(cpu)
python3 -c "print(f'$label: wrangler ready {($t1-$t0):.2f} s, workerd CPU to ready {float($c0):.2f} s, first request $first {float($ft)*1000:.1f} ms using {(float($c1)-float($c0))*1000:.0f} ms CPU, Worker process RSS {int($(rss))/1024:.0f} MiB')"
oha -z 2s -c 50 --no-tui --output-format quiet "http://127.0.0.1:$port$first"
args=(--c 50,200 --z "${Z:-10s}" --label "$label" --routes "$routes" --json "/tmp/compare-$label.json")
[ -n "$body" ] && args+=(--body "$body")
node "$HERE/load.mjs" "http://127.0.0.1:$port" "${args[@]}"
echo "$label: Worker process RSS after load $(( $(rss) / 1024 )) MiB"
