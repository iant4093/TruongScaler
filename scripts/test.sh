#!/usr/bin/env bash
# Package regressions or real iPhone 17 Simulator + app-hosted UIKit tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mode=logic
if [ "$#" -gt 0 ]; then mode="$1"; fi
case "$mode" in
  logic) bash scripts/verify-logic.sh ;;
  native) python3 scripts/run_bounded.py native-tests 8192 python3 scripts/run_native_tests.py ;;
  *) swift test --disable-sandbox --filter "$1" ;;
esac
