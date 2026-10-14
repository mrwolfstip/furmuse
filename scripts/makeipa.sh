#!/bin/sh
# builds an unsigned ipa for sideloadly (it signs with your apple id).
set -e
cd "$(dirname "$0")/.."
rm -rf build
./rust/build.sh device   # librespot static lib for aarch64-apple-ios; the Release xcconfig links it
xcodebuild -project furmuse.xcodeproj -scheme furmuse -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build
mkdir -p build/Payload
cp -R build/Build/Products/Release-iphoneos/furmuse.app build/Payload/
(cd build && zip -qry furmuse.ipa Payload)
echo "build/furmuse.ipa"
