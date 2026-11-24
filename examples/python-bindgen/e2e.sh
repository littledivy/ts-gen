#!/bin/bash
# Checks a running spec Worker (worker.py): e2e.sh <port> [Lang]. Each check
# is a route and the body it must match.
P=${1:?port}; L=${2:?Lang}; B=http://127.0.0.1:$P; fail=0
check() { # name, path, extended regex for the body
  local body; body=$(curl -s "$B$2")
  if [[ "$body" =~ $3 ]]; then printf "ok   %-8s %s\n" "$1" "$body"; else printf "FAIL %-8s got: %s\n" "$1" "$body"; fail=1; fi
}
check hello   /             "^Hello from $L!"
check kv      /kv           '^\{"count":[0-9]+,"keys":\["n"\]\}$'
check r2      /r2           "^\\{\"key\":\"hello.txt\",\"size\":[0-9]+,\"contentType\":\"text/plain\",\"body\":\"hi from $L\",\"listed\":[0-9]+\\}$"
check d1      /d1           '^\{"inserted":[0-9]+,"rows":[0-9]+\}$'
check do      /do/alice     '^\{"id":"[0-9a-f]{64}","count":[0-9]+,"hits":[0-9]+,"alarm":true\}$'
check do2     /do/alice     '^\{"id":"[0-9a-f]{64}","count":[0-9]+,"hits":[0-9]+,"alarm":true\}$'
check fetch   /fetch        "^\\{\"status\":200,\"body\":\"Hello from $L!\"\\}$"
check service /service      "^\\{\"status\":200,\"body\":\"Hello from $L!\"\\}$"
check queue   /queue        '^\{"sent":true\}$'
check log     /log          '^logged$'
code=$(curl -s -o /dev/null -w '%{http_code}' $B/nope); [ "$code" = 404 ] && echo "ok   404" || { echo "FAIL 404 got $code"; fail=1; }
exit $fail
