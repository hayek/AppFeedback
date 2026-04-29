#!/bin/bash
# Downloads AppleDB's device list and writes a slim {identifier: name} map
# into the app bundle so launches always have something to show before the
# first runtime fetch completes.
set -euo pipefail

OUT="${1:-AppFeedback/AppleDevices.json}"
TMP="$(mktemp -t appledb.XXXXXX).json"

mkdir -p "$(dirname "$OUT")"

# Skip the network round-trip on incremental builds: the runtime fetcher
# refreshes the catalog weekly anyway, so a fresh-enough bundle is fine.
if [ -f "$OUT" ] && [ "$(( $(date +%s) - $(stat -f %m "$OUT") ))" -lt 604800 ]; then
    echo "AppleDevices.json: cached (<7 days), skipping fetch" >&2
    exit 0
fi

curl --fail --silent --show-error --location \
    --max-time 30 \
    "https://api.appledb.dev/device/main.json" \
    -o "$TMP"

python3 - "$TMP" "$OUT" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
KEEP = {
    "iPhone","iPad","iPad Air","iPad Pro","iPad mini","iPod touch",
    "MacBook","MacBook Air","MacBook Pro","MacBook Neo",
    "Mac mini","Mac Pro","Mac Studio","iMac",
    "Apple Watch","Apple TV","HomePod","Headset",
}
data = json.load(open(src))
out = {}
for x in data:
    if x.get("type") not in KEEP: continue
    name = x.get("name")
    if not name: continue
    for ident in x.get("identifier") or []:
        if isinstance(ident, str) and ident:
            out[ident] = name
with open(dst, "w") as f:
    json.dump(out, f, separators=(",",":"), sort_keys=True)
print(f"AppleDevices.json: {len(out)} mappings", file=sys.stderr)
PY

rm -f "$TMP"
