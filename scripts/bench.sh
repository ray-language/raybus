#!/bin/sh
# raybus throughput: a fresh server on a random high port, a topic of 8 partitions, then
# `raybus bench` produces (each request answered after fsync) and reads everything back.
# Usage: scripts/bench.sh   (needs ./raybus: make build)
set -eu
BIN="$(cd "$(dirname "$0")/.." && pwd)/raybus"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/raybus-bench.XXXXXX")"
P=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
API="http://127.0.0.1:$P"
printf '[server]\nlisten = "127.0.0.1:%s"\ndata = "%s/data"\n' "$P" "$WORK" >"$WORK/raybus.toml"
"$BIN" serve --config "$WORK/raybus.toml" >"$WORK/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT
i=0; until curl -s -o /dev/null "$API/v1/topics"; do i=$((i + 1)); [ $i -gt 50 ] && exit 1; sleep 0.1; done
n=1
for run in "1 100 50000" "8 500 400000" "32 500 800000" "8 2000 800000"; do
    set -- $run
    curl -sf -o /dev/null -X PUT "$API/v1/topics/bench$n" -d '{"partitions": 8}'
    "$BIN" bench "bench$n" --api "$API" -c "$1" -b "$2" -n "$3"
    n=$((n + 1))
done
echo "server RSS $(( $(ps -o rss= -p "$SRV") / 1024 )) MiB"
