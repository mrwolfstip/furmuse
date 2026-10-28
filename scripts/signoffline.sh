#!/bin/sh
# Fully offline IPA signer for macOS.
#
#   usage: scripts/signoffline.sh app.ipa cert.p12 profile.mobileprovision [output.ipa] [--bundle-id com.example.app]
#
# The p12 password is read from $FURMUSE_P12_PASSWORD, or asked for on the terminal
# (it is never taken from the command line, so it does not show up in `ps` or shell history).
#
# What "offline" means here:
#   * this script runs no network command (no curl, no xcrun altool, no notarytool, no fastlane)
#   * codesign runs with --timestamp=none, so it never contacts Apple's timestamp server
#   * the certificate is imported into a throw-away keychain that is not in your keychain search list,
#     and identities are listed WITHOUT `-v`, so macOS does not run a trust / revocation check on them
#   * nothing is written outside the temp folder and the output ipa; the temp keychain is deleted on exit
#
# What it cannot do: your iPhone decides for itself, when you install or open the app, whether the
# certificate is still accepted. Signing offline does not change what Apple reports for the certificate.
#
# p12 import notes: macOS `security import` cannot read p12 files made with OpenSSL 3 defaults (AES-256),
# and reports that as "MAC verification failed (wrong password?)" even when the password is right.
# If the direct import fails, this script re-wraps the p12 with older encryption using any openssl it
# can find (Homebrew openssl@3 works best: `brew install openssl@3`), then retries.

set -eu
umask 077

usage() {
  echo "usage: $0 app.ipa cert.p12 profile.mobileprovision [output.ipa] [--bundle-id id]" >&2
  exit 64
}

# ---- arguments --------------------------------------------------------------------------------
BUNDLE_OVERRIDE=
N=0; A1=; A2=; A3=; A4=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle-id) [ "$#" -ge 2 ] || usage; BUNDLE_OVERRIDE=$2; shift 2 ;;
    -h|--help) usage ;;
    *) N=$((N + 1))
       case "$N" in 1) A1=$1 ;; 2) A2=$1 ;; 3) A3=$1 ;; 4) A4=$1 ;; *) usage ;; esac
       shift ;;
  esac
done
[ "$N" -ge 3 ] || usage

abspath() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")"); }

INPUT_IPA=$(abspath "$A1")
P12=$(abspath "$A2")
PROFILE=$(abspath "$A3")
OUTPUT_IPA=$(abspath "${A4:-./build/furmuse-signed.ipa}")

[ -f "$INPUT_IPA" ] || { echo "error: ipa not found: $INPUT_IPA" >&2; exit 66; }
[ -f "$P12" ]       || { echo "error: p12 not found: $P12" >&2; exit 66; }
[ -f "$PROFILE" ]   || { echo "error: mobileprovision not found: $PROFILE" >&2; exit 66; }
[ "$INPUT_IPA" != "$OUTPUT_IPA" ] || { echo "error: output must differ from input" >&2; exit 64; }

for tool in security codesign plutil ditto zip uuidgen shasum base64 /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing macOS tool: $tool (this script must run on a Mac)" >&2; exit 69; }
done

# ---- password ---------------------------------------------------------------------------------
if [ -z "${FURMUSE_P12_PASSWORD:-}" ]; then
  printf "p12 password (leave empty if none): " >/dev/tty
  stty -echo </dev/tty
  IFS= read -r FURMUSE_P12_PASSWORD </dev/tty || true
  stty echo </dev/tty
  printf "\n" >/dev/tty
fi
# strip a stray carriage return (pasted passwords sometimes carry one)
FURMUSE_P12_PASSWORD=$(printf '%s' "$FURMUSE_P12_PASSWORD" | tr -d '\r')
export FURMUSE_P12_PASSWORD
# macOS often rejects p12 files with an EMPTY password, so re-wrapped files always get a non-empty one
REWRAP_PASS=${FURMUSE_P12_PASSWORD:-rewrap-temp-pass}
export REWRAP_PASS

# ---- temp workspace ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/furmuse-offline.XXXXXX")
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)-$(uuidgen)"
UNPACKED="$WORK/unpacked"
PROFILE_PLIST="$WORK/profile.plist"
ENTITLEMENTS="$WORK/entitlements.plist"
ERRLOG="$WORK/import-errors.log"
: > "$ERRLOG"

cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  case "$WORK" in
    "${TMPDIR:-/tmp}"/furmuse-offline.*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

# ---- profile (read locally; `security cms` only decodes the file) -----------------------------
security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
  || { echo "error: could not decode the mobileprovision (is it a real .mobileprovision?)" >&2; exit 65; }
plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" "$PROFILE_PLIST"

pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PROFILE_PLIST" 2>/dev/null; }
APP_IDENTIFIER=$(pb Entitlements:application-identifier)
TEAM_IDENTIFIER=$(pb Entitlements:com.apple.developer.team-identifier || pb TeamIdentifier:0)
PROFILE_NAME=$(pb Name || echo "?")
PROFILE_BUNDLE_ID=${APP_IDENTIFIER#"$TEAM_IDENTIFIER".}

# local-clock expiry check (a warning only, nothing is sent anywhere)
EXPIRY_RAW=$(pb ExpirationDate || echo "")
if [ -n "$EXPIRY_RAW" ]; then
  EXP_EPOCH=$(date -j -f "%a %b %d %T %Z %Y" "$EXPIRY_RAW" +%s 2>/dev/null || echo 0)
  if [ "$EXP_EPOCH" -gt 0 ] && [ "$EXP_EPOCH" -lt "$(date +%s)" ]; then
    echo "warning: the provisioning profile expired on $EXPIRY_RAW; the app will not open on a device" >&2
  fi
fi

# ---- unpack the ipa ---------------------------------------------------------------------------
mkdir -p "$UNPACKED"
ditto -x -k "$INPUT_IPA" "$UNPACKED"
APP_COUNT=$(find "$UNPACKED/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')
[ "$APP_COUNT" = "1" ] || { echo "error: the ipa must contain exactly one Payload/*.app" >&2; exit 65; }
APP=$(find "$UNPACKED/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)
CURRENT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

if [ -n "$BUNDLE_OVERRIDE" ]; then
  case "$PROFILE_BUNDLE_ID" in
    '*') SIGNED_BUNDLE_ID=$BUNDLE_OVERRIDE ;;
    *'*') case "$BUNDLE_OVERRIDE" in "${PROFILE_BUNDLE_ID%\*}"*) SIGNED_BUNDLE_ID=$BUNDLE_OVERRIDE ;;
            *) echo "error: --bundle-id $BUNDLE_OVERRIDE does not match the profile ($APP_IDENTIFIER)" >&2; exit 65 ;; esac ;;
    *) [ "$BUNDLE_OVERRIDE" = "$PROFILE_BUNDLE_ID" ] || { echo "error: this profile is only valid for $PROFILE_BUNDLE_ID" >&2; exit 65; }
       SIGNED_BUNDLE_ID=$PROFILE_BUNDLE_ID ;;
  esac
else
  case "$PROFILE_BUNDLE_ID" in
    '*') SIGNED_BUNDLE_ID=$CURRENT_BUNDLE_ID ;;
    *'*') SIGNED_BUNDLE_ID=$CURRENT_BUNDLE_ID
          case "$CURRENT_BUNDLE_ID" in "${PROFILE_BUNDLE_ID%\*}"*) ;; *)
            echo "error: profile is $APP_IDENTIFIER but the app is $CURRENT_BUNDLE_ID; pass --bundle-id" >&2; exit 65 ;; esac ;;
    *) SIGNED_BUNDLE_ID=$PROFILE_BUNDLE_ID ;;
  esac
fi

# ---- import the p12 into a private keychain ---------------------------------------------------
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# $1 = p12 file, $2 = its password. Errors are kept in $ERRLOG instead of being thrown away.
import_p12() {
  { echo "--- security import $(basename "$1")"; } >> "$ERRLOG"
  security import "$1" -k "$KEYCHAIN" -P "$2" -T /usr/bin/codesign -T /usr/bin/security >>"$ERRLOG" 2>&1
}

# every openssl we can find (Homebrew first, because the stock macOS one is LibreSSL)
openssl_candidates() {
  for c in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
           /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
}

# $1 = openssl binary. Reads $P12, writes $LEGACY (older encryption, non-empty password $REWRAP_PASS).
LEGACY="$WORK/legacy.p12"
PEM="$WORK/all.pem"
rewrap_p12() {
  _o=$1
  rm -f "$LEGACY" "$PEM"
  { echo "--- re-wrap with $_o ($("$_o" version 2>&1 | head -n 1))"; } >> "$ERRLOG"
  # OpenSSL 3 needs -legacy to READ old RC2/3DES p12 files; newer p12 files read fine without it
  { "$_o" pkcs12 -in "$P12" -passin env:FURMUSE_P12_PASSWORD -nodes -out "$PEM" 2>>"$ERRLOG" \
    || "$_o" pkcs12 -legacy -in "$P12" -passin env:FURMUSE_P12_PASSWORD -nodes -out "$PEM" 2>>"$ERRLOG"; } || return 1
  [ -s "$PEM" ] || return 1
  # WRITE with algorithms macOS understands (-legacy on OpenSSL 3; LibreSSL's default is already fine)
  { "$_o" pkcs12 -export -legacy -in "$PEM" -out "$LEGACY" -passout env:REWRAP_PASS 2>>"$ERRLOG" \
    || "$_o" pkcs12 -export -in "$PEM" -out "$LEGACY" -passout env:REWRAP_PASS 2>>"$ERRLOG"; } || return 1
  rm -f "$PEM"
  [ -s "$LEGACY" ]
}

IMPORTED=no
if import_p12 "$P12" "$FURMUSE_P12_PASSWORD"; then
  IMPORTED=yes
else
  echo "note: direct p12 import failed, retrying with a re-wrapped copy (older encryption)..." >&2
  for OSSL in $(openssl_candidates); do
    if rewrap_p12 "$OSSL" && import_p12 "$LEGACY" "$REWRAP_PASS"; then
      IMPORTED=yes
      break
    fi
  done
fi

if [ "$IMPORTED" != yes ]; then
  echo "error: could not import the p12. What macOS / openssl said:" >&2
  sed 's/^/    /' "$ERRLOG" >&2
  echo >&2
  if grep -qi 'mac verify\|invalid password\|mac verification' "$ERRLOG"; then
    echo "hint: every attempt complained about the password. Double-check it (case, trailing spaces)," >&2
    echo "      and that this p12 really belongs to that password." >&2
  fi
  echo "hint: for the best chance run:  brew install openssl@3   and try again." >&2
  exit 65
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true

# No `-v`: list every identity, valid or not, so macOS never decides for us that the cert is "revoked" or "untrusted".
IDENTITY_LINE=$(security find-identity -p codesigning "$KEYCHAIN" | grep -E '^[[:space:]]*[0-9]+\)' | head -n 1 || true)
IDENTITY=$(printf '%s' "$IDENTITY_LINE" | awk '{print $2}')
[ -n "$IDENTITY" ] || { echo "error: the p12 contains no code-signing identity (certificate + private key)" >&2; exit 65; }
IDENTITY_NAME=$(printf '%s' "$IDENTITY_LINE" | sed -E 's/^[^"]*"([^"]*)".*/\1/')

# ---- does this certificate belong to this profile? (compare SHA-1 locally) --------------------
MATCH=no
i=0
while DER_B64=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$PROFILE_PLIST" 2>/dev/null); do
  HASH=$(printf '%s' "$DER_B64" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')
  [ "$HASH" = "$IDENTITY" ] && { MATCH=yes; break; }
  i=$((i + 1))
done
if [ "$MATCH" != yes ]; then
  echo "warning: this certificate is NOT listed in the provisioning profile. codesign will work, but the phone will refuse the app." >&2
  echo "         use the .mobileprovision that was created with this exact certificate." >&2
fi

# ---- sign -------------------------------------------------------------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SIGNED_BUNDLE_ID" "$APP/Info.plist"
ditto "$PROFILE" "$APP/embedded.mobileprovision"

SIGN() { codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$@"; }

# loose libraries first, then nested bundles inside-out, then the app itself
find "$APP" -type f -name '*.dylib' -print | while IFS= read -r item; do SIGN "$item"; done

find "$APP" -mindepth 1 -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \) -print \
  | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r item; do SIGN "$item"; done

SIGN --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---- zip --------------------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_IPA")"
TEMP_OUTPUT="$WORK/signed.ipa"
(cd "$UNPACKED" && /usr/bin/zip -qry "$TEMP_OUTPUT" Payload)
rm -f -- "$OUTPUT_IPA"
ditto "$TEMP_OUTPUT" "$OUTPUT_IPA"

echo
echo "signed ipa:           $OUTPUT_IPA"
echo "certificate:          $IDENTITY_NAME"
echo "certificate matches profile: $MATCH"
echo "profile:              $PROFILE_NAME"
echo "bundle id:            $SIGNED_BUNDLE_ID"
echo "profile expires:      ${EXPIRY_RAW:-unknown}"
echo "network used:         none"
