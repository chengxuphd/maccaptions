#!/bin/bash
# Builds with the developer tools and runs the self-tests. No audio devices, network, API keys or model servers needed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -Xswiftc -DDEVTOOLS
BIN="$(swift build -Xswiftc -DDEVTOOLS --show-bin-path)/MacCaptions"
SUITE=maccaptions-tests                       # throw-away settings: the real app's are never touched
trap 'defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
OUT="$(MACCAPTIONS_DEFAULTS_SUITE=$SUITE MACCAPTIONS_SELFTEST=1 "$BIN" 2>&1)"
echo "$OUT" | grep -E '^FAIL|SELF-TEST' || true
echo "$(echo "$OUT" | grep -c '^PASS') checks passed"
echo "$OUT" | grep -q '^ALL SELF-TESTS PASSED'
