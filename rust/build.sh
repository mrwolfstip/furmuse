#!/bin/sh
# builds the librespot bridge for the ios simulator and/or a real device into rust/out/.
# config/rust.xcconfig (static) links it; the Xcode Run Script phase calls this script with "xcode" on every build.
#
#   ./rust/build.sh sim       simulator only (what you need for testing in the emulator)
#   ./rust/build.sh device    real iphone only
#   ./rust/build.sh all       both
#   ./rust/build.sh clean     remove the rust output and the xcconfig (app goes back to "not linked")
#
# needs: rustup (rust 1.85 or newer) and xcode command line tools.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/rust/wolfified-librespot-ffi"
OUT="$ROOT/rust/out"
XCC="$ROOT/config/rust.xcconfig"
LIB=libwolfified_librespot_ffi.a
MODE="${1:-sim}"
# "xcode" = called from the Run Script build phase: pick the slice from the SDK Xcode is building for.
if [ "$MODE" = xcode ]; then
  case "${PLATFORM_NAME:-iphoneos}" in
    iphonesimulator)
      MODE=sim
      # Xcode can invoke this phase with only the host architecture in ARCHS and then
      # link additional simulator slices later. Always make the Xcode-produced archive
      # universal so generic builds work on both Apple-Silicon and Intel simulators.
      SIM_FAT=1
      ;;
    *) MODE=device ;;
  esac
  # Xcode's script environment has a minimal PATH; rustup/cargo live here
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
  # keep the cargo target dir out of the sandboxed build products and make it incremental between builds
  [ -n "${WOLF_REQUIRE_RUST:-}" ] || WOLF_REQUIRE_RUST=1
  # iOS already registers the authenticated device through Spotify's cloud Connect service.
  # Advertising a second LAN endpoint is redundant and can collide with another running build.
  [ -n "${WOLF_NO_ZEROCONF:-}" ] || WOLF_NO_ZEROCONF=1
fi

if [ "$MODE" = clean ]; then rm -rf "$OUT" "$CRATE/target"; echo "cleaned"; exit 0; fi

command -v cargo >/dev/null 2>&1 || { echo "cargo not found. install rust first:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   (then open a new terminal)"; exit 1; }
[ -f "$ROOT/librespot-0.8.0/core/Cargo.toml" ] || { echo "librespot-0.8.0/ is missing next to Sources/ (unzip librespot-0_8_0.zip into the project folder)"; exit 1; }
grep -q "WOLFIFIED PATCH" "$ROOT/librespot-0.8.0/core/src/config.rs" || { echo "librespot-0.8.0/core/src/config.rs is missing the WOLFIFIED PATCH (iOS must present as a desktop client or Spotify answers TryAnotherAP). copy the patched file from the project zip."; exit 1; }
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || { echo "xcode command line tools not found: xcode-select --install"; exit 1; }

export IPHONEOS_DEPLOYMENT_TARGET=15.0
# Xcode exports SDKROOT/CC/etc. for the app target; cargo must pick its own iOS toolchain per --target
unset SDKROOT CC CXX AR LD CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
# WOLF_NO_ZEROCONF=1 builds without the mDNS advertisement (spotify connect still registers through spotify's servers)
FEATURES=""
[ "${WOLF_NO_ZEROCONF:-0}" = 1 ] && FEATURES="--no-default-features"
cd "$CRATE"

build_sim() {
  # arm64 simulator on apple silicon, x86_64 on intel macs; SIM_FAT=1 builds both into one library
  HOST="$(uname -m)"
  if [ "$HOST" = arm64 ]; then T=aarch64-apple-ios-sim; OTHER=x86_64-apple-ios; else T=x86_64-apple-ios; OTHER=aarch64-apple-ios-sim; fi
  rustup target add "$T" >/dev/null
  cargo build --release $FEATURES --target "$T"
  mkdir -p "$OUT/sim"
  if [ "${SIM_FAT:-0}" = 1 ]; then
    rustup target add "$OTHER" >/dev/null
    cargo build --release $FEATURES --target "$OTHER"
    lipo -create "target/$T/release/$LIB" "target/$OTHER/release/$LIB" -output "$OUT/sim/$LIB"
  else
    cp "target/$T/release/$LIB" "$OUT/sim/$LIB"
  fi
  echo "simulator library: $OUT/sim/$LIB"
}

build_device() {
  rustup target add aarch64-apple-ios >/dev/null
  cargo build --release $FEATURES --target aarch64-apple-ios
  mkdir -p "$OUT/device"
  cp "target/aarch64-apple-ios/release/$LIB" "$OUT/device/$LIB"
  echo "device library: $OUT/device/$LIB"
}

case "$MODE" in
  sim) build_sim ;;
  device) build_device ;;
  all) build_sim; build_device ;;
  *) echo "usage: $0 sim|device|all|xcode|clean"; exit 1 ;;
esac

# config/rust.xcconfig is committed and static: it always points at rust/out/{sim,device}/. the Xcode Run Script phase
# ("Build librespot (rust)") runs this script with mode "xcode" before compiling, so the library exists by link time.
# if the library for the SDK being built is missing, linking fails loudly instead of silently building without Spotify.
echo "built. xcode links config/rust.xcconfig -> rust/out/"
