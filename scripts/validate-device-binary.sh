#!/usr/bin/env bash
# Validate architecture AND Mach-O platform without needing a device/runtime.
set -euo pipefail
binary="${1:?usage: validate-device-binary.sh <executable>}"
architectures="$(/usr/bin/lipo -archs "$binary")"
case " $architectures " in
  *" arm64 "*) ;;
  *) echo "FAIL: executable has no arm64 slice" >&2; exit 1 ;;
esac
build_info="$(xcrun vtool -show-build "$binary")"
if ! awk '$1 == "platform" { count++; if ($2 != "IOS") bad = 1 }
          END { exit (count == 0 || bad ? 1 : 0) }' <<<"$build_info"; then
  echo "FAIL: executable is not exclusively platform IOS (simulator/macOS rejected)" >&2
  exit 1
fi
echo "PASS: arm64 device executable, Mach-O platform IOS"
