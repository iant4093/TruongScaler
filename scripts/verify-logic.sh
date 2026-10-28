#!/usr/bin/env bash
# Mac package regressions, trained references, and packaging fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export TRUONGSCALER_QUALITY_EVIDENCE_DIR="$ROOT/build/test-results/quality/mac"
mkdir -p "$ROOT/build/logs" "$TRUONGSCALER_QUALITY_EVIDENCE_DIR"
python3 scripts/run_bounded.py package-tests 8192 \
  swift test --disable-sandbox -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 ModelConversionTools/verify_production_assets.py --checkpoints-dir ModelConversionTools/checkpoints
