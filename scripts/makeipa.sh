#!/bin/sh
# Builds an unsigned device IPA. Signing is deliberately a separate step.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD_DIR=${FURMUSE_BUILD_DIR:-"$ROOT/build"}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/furmuse-ipa.XXXXXX")

cleanup() {
  case "$STAGE" in
    "${TMPDIR:-/tmp}"/furmuse-ipa.*) rm -rf -- "$STAGE" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT"
./rust/build.sh device
xcodebuild \
  -project furmuse.xcodeproj \
  -scheme furmuse \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY= \
  build

APP="$BUILD_DIR/Build/Products/Release-iphoneos/furmuse.app"
test -d "$APP" || { echo "error: built app was not found at $APP" >&2; exit 1; }

mkdir -p "$BUILD_DIR" "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/furmuse.app"
rm -f -- "$BUILD_DIR/furmuse.ipa"
(cd "$STAGE" && /usr/bin/zip -qry "$BUILD_DIR/furmuse.ipa" Payload)

echo "$BUILD_DIR/furmuse.ipa"
