#!/bin/sh
# raybus under kill -9: a producer outside raybus (stdlib Python) records every record raybus
# acknowledged; raybus is killed with SIGKILL in the middle of producing; after a restart, every
# acknowledged record must be at its partition and offset, and every partition's offsets must run
# without gaps or repeats. Three rounds on the same data directory.
# Usage: scripts/crash.sh [ROUNDS]   (needs ./raybus: make build)
set -eu
BIN="$(cd "$(dirname "$0")/.." && pwd)/raybus"
ROUNDS="${1:-3}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/raybus-crash.XXXXXX")"
P=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
API="http://127.0.0.1:$P"
printf '[server]\nlisten = "127.0.0.1:%s"\ndata = "%s/data"\nsegment_mb = 1\n' "$P" "$WORK" >"$WORK/raybus.toml"
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; [ -n "$SRV" ] && wait "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
up() {
    "$BIN" serve --config "$WORK/raybus.toml" >>"$WORK/serve.log" 2>&1 &
    SRV=$!
    i=0; until curl -s -o /dev/null "$API/v1/topics"; do i=$((i + 1)); [ $i -gt 50 ] && { cat "$WORK/serve.log"; exit 1; }; sleep 0.1; done
}

cat >"$WORK/produce.py" <<'EOF'
# Produce batches until raybus stops answering; append every acknowledged record to acked.tsv.
import json, sys, urllib.request
api, start, out = sys.argv[1], int(sys.argv[2]), open(sys.argv[3], "a")
n = start
while True:
    recs = [{"key": "k%d" % ((n + i) % 37), "value": "seq %d" % (n + i)} for i in range(200)]
    req = urllib.request.Request(api + "/v1/topics/events/records", json.dumps({"records": recs}).encode(), {"Content-Type": "application/json"})
    try:
        offs = json.load(urllib.request.urlopen(req, timeout=5))["offsets"]
    except Exception:
        break
    for r, o in zip(recs, offs):
        out.write("%d\t%d\t%s\n" % (o["partition"], o["offset"], r["value"]))
    out.flush()
    n += 200
print(n)
EOF

cat >"$WORK/check.py" <<'EOF'
# Read every partition from the start; every acknowledged record must be where raybus said.
import json, sys, urllib.request
api, acked = sys.argv[1], sys.argv[2]
topics = json.load(urllib.request.urlopen(api + "/v1/topics"))["topics"]
parts = [t for t in topics if t["topic"] == "events"][0]["partitions"]
log = {}
for p in range(len(parts)):
    at, prev = "earliest", -1
    while True:
        j = json.load(urllib.request.urlopen("%s/v1/topics/events/%d?offset=%s&max_bytes=4194304" % (api, p, at)))
        if not j["records"]:
            break
        for r in j["records"]:
            assert r["offset"] == prev + 1, "partition %d: offset %d after %d" % (p, r["offset"], prev)
            prev = r["offset"]
            log[(p, r["offset"])] = r["value"]
        at = j["next_offset"]
missing = wrong = 0
n = 0
for line in open(acked):
    p, o, v = line.rstrip("\n").split("\t")
    n += 1
    got = log.get((int(p), int(o)))
    if got is None:
        missing += 1
    elif got != v:
        wrong += 1
print("%d acknowledged, %d in the log, %d missing, %d wrong" % (n, len(log), missing, wrong))
sys.exit(1 if missing or wrong else 0)
EOF

up
curl -sf -o /dev/null -X PUT "$API/v1/topics/events" -d '{"partitions": 4}'
seq=0
round=1
while [ $round -le "$ROUNDS" ]; do
    python3 "$WORK/produce.py" "$API" "$seq" "$WORK/acked.tsv" >"$WORK/next" &
    PROD=$!
    sleep 1.5
    kill -9 "$SRV"; wait "$SRV" 2>/dev/null || true
    SRV=""
    wait "$PROD" || true
    seq=$(cat "$WORK/next")
    up
    printf "round %d: killed -9 mid-produce; " "$round"
    python3 "$WORK/check.py" "$API" "$WORK/acked.tsv"
    grep 'recovered' "$WORK/serve.log" | tail -4 | sed 's/^/        /' || true
    : >"$WORK/serve.log"
    round=$((round + 1))
done
echo "all rounds: every acknowledged record survived kill -9"
