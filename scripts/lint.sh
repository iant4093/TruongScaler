#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.65.1
checksum=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
tools="${TRUONGSCALER_TOOLS_DIR:-$PWD/build/tools}"
mkdir -p "$tools"
if [ ! -x "$tools/swiftlint-$version/swiftlint" ]; then
  archive="$tools/swiftlint-$version.zip"
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/realm/SwiftLint/releases/download/$version/portable_swiftlint.zip" -o "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
  mkdir -p "$tools/swiftlint-$version"
  unzip -q "$archive" -d "$tools/swiftlint-$version"
fi
"$tools/swiftlint-$version/swiftlint" lint --strict --config .swiftlint.yml
