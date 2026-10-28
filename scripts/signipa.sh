#!/bin/sh
# Offline IPA signer for macOS. No certificate, password, or IPA leaves this Mac.
set -eu
umask 077

usage() {
  echo "usage: $0 unsigned.ipa certificate.p12 profile.mobileprovision [signed.ipa]" >&2
  exit 64
}

test "$#" -ge 3 && test "$#" -le 4 || usage

INPUT_IPA=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
P12=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
PROFILE=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
OUTPUT_IPA=${4:-"$(pwd)/build/furmuse-signed.ipa"}
OUTPUT_DIR=$(dirname "$OUTPUT_IPA")
mkdir -p "$OUTPUT_DIR"
OUTPUT_IPA=$(cd "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_IPA")

test -f "$INPUT_IPA" || { echo "error: IPA not found: $INPUT_IPA" >&2; exit 66; }
test -f "$P12" || { echo "error: certificate not found: $P12" >&2; exit 66; }
test -f "$PROFILE" || { echo "error: provisioning profile not found: $PROFILE" >&2; exit 66; }
test "$INPUT_IPA" != "$OUTPUT_IPA" || { echo "error: output must be different from input" >&2; exit 64; }

for tool in security codesign plutil ditto zip uuidgen; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: required macOS tool is missing: $tool" >&2; exit 69; }
done

if test -z "${FURMUSE_P12_PASSWORD:-}"; then
  printf "p12 password: " >/dev/tty
  stty -echo </dev/tty
  IFS= read -r FURMUSE_P12_PASSWORD </dev/tty || true
  stty echo </dev/tty
  printf "\n" >/dev/tty
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/furmuse-sign.XXXXXX")
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)-$(uuidgen)"
UNPACKED="$WORK/unpacked"
PROFILE_PLIST="$WORK/profile.plist"
ENTITLEMENTS="$WORK/entitlements.plist"

cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  case "$WORK" in
    "${TMPDIR:-/tmp}"/furmuse-sign.*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$UNPACKED"
ditto -x -k "$INPUT_IPA" "$UNPACKED"

APP_COUNT=$(find "$UNPACKED/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')
test "$APP_COUNT" = "1" || { echo "error: IPA must contain exactly one top-level app" >&2; exit 65; }
APP=$(find "$UNPACKED/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)

security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" "$PROFILE_PLIST"
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")
TEAM_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")
PROFILE_BUNDLE_ID=${APP_IDENTIFIER#"$TEAM_IDENTIFIER".}
CURRENT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

case "$PROFILE_BUNDLE_ID" in
  '*') SIGNED_BUNDLE_ID=$CURRENT_BUNDLE_ID ;;
  *'*'*) echo "error: unsupported wildcard app identifier: $APP_IDENTIFIER" >&2; exit 65 ;;
  *) SIGNED_BUNDLE_ID=$PROFILE_BUNDLE_ID ;;
esac

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SIGNED_BUNDLE_ID" "$APP/Info.plist"
ditto "$PROFILE" "$APP/embedded.mobileprovision"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$FURMUSE_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/[0-9A-F]{40}/ {print $2; exit}')
test -n "$IDENTITY" || { echo "error: the p12 contains no usable code-signing identity" >&2; exit 65; }

# Sign embedded executable bundles from the inside out, then sign the main app.
find "$APP" -mindepth 1 -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) -print \
  | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r item; do
      codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$item"
    done

codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none \
  --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

TEMP_OUTPUT="$WORK/signed.ipa"
(cd "$UNPACKED" && /usr/bin/zip -qry "$TEMP_OUTPUT" Payload)
ditto "$TEMP_OUTPUT" "$OUTPUT_IPA"

EXPIRY=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST" 2>/dev/null || echo unknown)
echo "signed IPA: $OUTPUT_IPA"
echo "bundle id: $SIGNED_BUNDLE_ID"
echo "provisioning expires: $EXPIRY"
