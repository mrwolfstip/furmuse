#!/bin/sh
# Creates the manifest needed for an HTTPS itms-services installation link.
set -eu

test "$#" -ge 2 && test "$#" -le 3 || {
  echo "usage: $0 signed.ipa https://example.com/path/furmuse-signed.ipa [manifest.plist]" >&2
  exit 64
}

IPA=$1
IPA_URL=$2
OUTPUT=${3:-manifest.plist}
case "$IPA_URL" in https://*) ;; *) echo "error: IPA URL must use HTTPS" >&2; exit 64 ;; esac
test -f "$IPA" || { echo "error: IPA not found: $IPA" >&2; exit 66; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/furmuse-manifest.XXXXXX")
cleanup() {
  case "$WORK" in "${TMPDIR:-/tmp}"/furmuse-manifest.*) rm -rf -- "$WORK" ;; esac
}
trap cleanup EXIT HUP INT TERM

ditto -x -k "$IPA" "$WORK"
APP=$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)
test -n "$APP" || { echo "error: no app found in IPA" >&2; exit 65; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
TITLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null || echo furmuse)

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict/></plist>' > "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items array' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0 dict' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0:assets array' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0:assets:0 dict' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0:assets:0:kind string software-package' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :items:0:assets:0:url string $IPA_URL" "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0:metadata dict' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :items:0:metadata:bundle-identifier string $BUNDLE_ID" "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :items:0:metadata:bundle-version string $VERSION" "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c 'Add :items:0:metadata:kind string software' "$WORK/manifest.plist"
/usr/libexec/PlistBuddy -c "Add :items:0:metadata:title string $TITLE" "$WORK/manifest.plist"
plutil -lint "$WORK/manifest.plist" >/dev/null
mkdir -p "$(dirname "$OUTPUT")"
ditto "$WORK/manifest.plist" "$OUTPUT"
echo "$OUTPUT"
