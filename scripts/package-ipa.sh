#!/usr/bin/env bash
# Package an unsigned Release device app and its matching app/widget symbols.
# ZIP compression is streamed by one process at a time; no signing or install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_NAME="TruongScalerApp"
WIDGET_NAME="TruongScalerLiveActivityExtension"
DERIVED="${TRUONGSCALER_DERIVED_DATA:-$ROOT/build/DerivedData}"
PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
APP="$PRODUCTS/$APP_NAME.app"
WIDGET="$APP/PlugIns/$WIDGET_NAME.appex"
OUT_DIR="${TRUONGSCALER_IPA_OUTPUT_DIR:-$ROOT/build/ipa}"

if [ ! -d "$APP" ]; then
  echo "Release app not found at $APP. Run scripts/build.sh release first." >&2
  exit 1
fi
python3 scripts/validate_built_metadata.py --app "$APP" --expect-config Release
python3 ModelConversionTools/verify_production_assets.py --built-app "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
WIDGET_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WIDGET/Info.plist")"
WIDGET_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET/Info.plist")"
if [ "$VERSION" != "$WIDGET_VERSION" ] || [ "$BUILD" != "$WIDGET_BUILD" ]; then
  echo "FAIL: app/widget version or build numbers differ" >&2
  exit 1
fi

validate_bundle() {
  local bundle="$1" name="$2" dsym="$3"
  local binary="$bundle/$name"
  if [ ! -s "$binary" ]; then
    echo "FAIL: missing or empty executable $binary" >&2
    return 1
  fi
  if /usr/bin/codesign -d "$bundle" >/dev/null 2>&1 || [ -e "$bundle/_CodeSignature" ] || [ -e "$bundle/embedded.mobileprovision" ]; then
    echo "FAIL: unsigned packaging rejects signed or provisioned bundles: $bundle" >&2
    return 1
  fi
  bash scripts/validate-device-binary.sh "$binary" || return 1
  local binary_uuid dsym_uuid
  binary_uuid="$(xcrun dwarfdump --uuid "$binary" | /usr/bin/awk '/^UUID:/ {print $2, $3}')" || return 1
  dsym_uuid="$(xcrun dwarfdump --uuid "$dsym" | /usr/bin/awk '/^UUID:/ {print $2, $3}')" || return 1
  if [ -z "$binary_uuid" ] || [ "$binary_uuid" != "$dsym_uuid" ]; then
    echo "FAIL: missing or mismatched external dSYM: $dsym" >&2
    return 1
  fi
  echo "PASS: unsigned device bundle and matching external symbols: $name ($binary_uuid)"
}

validate_bundle "$APP" "$APP_NAME" "$PRODUCTS/$APP_NAME.app.dSYM"
validate_bundle "$WIDGET" "$WIDGET_NAME" "$PRODUCTS/$WIDGET_NAME.appex.dSYM"
if [ -n "$(/usr/bin/find "$APP" -name '*.dSYM' -print -quit)" ]; then
  echo "FAIL: crash symbols must stay outside the installed app" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
STAGE="$(mktemp -d "$OUT_DIR/.packaging.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
/usr/bin/ditto "$APP" "$STAGE/Payload/$APP_NAME.app"
(
  cd "$STAGE"
  /usr/bin/zip -9qry TruongScaler.ipa Payload
  /usr/bin/unzip -tq TruongScaler.ipa
)
(
  cd "$PRODUCTS"
  /usr/bin/zip -9qry "$STAGE/TruongScaler.dSYM.zip" "$APP_NAME.app.dSYM" "$WIDGET_NAME.appex.dSYM"
)
(
  cd "$STAGE"
  /usr/bin/unzip -tq TruongScaler.dSYM.zip
  /usr/bin/shasum -a 256 TruongScaler.ipa TruongScaler.dSYM.zip > SHA256SUMS
  /usr/bin/shasum -a 256 --check SHA256SUMS
)
mv -f "$STAGE/TruongScaler.ipa" "$STAGE/TruongScaler.dSYM.zip" "$STAGE/SHA256SUMS" "$OUT_DIR/"
echo "PASS: unsigned TruongScaler $VERSION ($BUILD), app/widget symbols and SHA256SUMS"
echo "artifacts: $OUT_DIR"
echo "Sign the IPA with your own sideloading tool before installation."
