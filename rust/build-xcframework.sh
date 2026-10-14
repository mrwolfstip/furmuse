#!/bin/sh
# builds the librespot ffi static library for ios and wraps it as an xcframework (NOT RUN in the authoring environment).
# needs: rustup, targets aarch64-apple-ios and aarch64-apple-ios-sim, xcode command line tools.
# librespot's own rust-toolchain.toml / rust-version decides the minimum rust; check librespot-0.8.0/Cargo.toml.
set -e
cd "$(dirname "$0")/wolfified-librespot-ffi"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
mkdir -p build/headers
cp include/wolf_librespot.h build/headers/
cp module.modulemap build/headers/module.modulemap
rm -rf ../../CWolfLibrespot.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libwolfified_librespot_ffi.a -headers build/headers \
  -library target/aarch64-apple-ios-sim/release/libwolfified_librespot_ffi.a -headers build/headers \
  -output ../../CWolfLibrespot.xcframework
echo "CWolfLibrespot.xcframework ready. add it to the wolfified target (Frameworks, Libraries, and Embedded Content)."
