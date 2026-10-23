#!/bin/bash
# Builds build/AcornBrowser.app: the Swift UI, the Objective-C++ Chromium bridge, the CEF
# framework, and the five helper apps Chromium needs. Signed ad hoc, for running on this Mac.
#
#   scripts/build.sh            build
#   scripts/build.sh run        build, then open the app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PRODUCT="AcornBrowser"
BUNDLE_ID="com.acorn.browser"
MIN_MACOS="15.0"
CEF_DIR="$ROOT/ThirdParty/cef"
WRAPPER_LIB="$CEF_DIR/build/libcef_dll_wrapper.a"
FRAMEWORK_NAME="Chromium Embedded Framework.framework"
BUILD="$ROOT/build"
APP="$BUILD/$PRODUCT.app"
OBJ="$BUILD/obj"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

"$ROOT/scripts/setup-cef.sh"

mkdir -p "$OBJ"

# 1. Objective-C++: the Chromium bridge.
CXXFLAGS=(-std=c++20 -stdlib=libc++ -fobjc-arc -O2 -arch arm64 -isysroot "$SDK"
          -mmacosx-version-min="$MIN_MACOS" -I"$CEF_DIR" -ISources/Chromium
          -DWRAPPING_CEF_SHARED -fno-rtti -w)
for src in Sources/Chromium/*.mm; do
  name="$(basename "$src" .mm)"
  if [ ! -f "$OBJ/$name.o" ] || [ "$src" -nt "$OBJ/$name.o" ] || [ Sources/Chromium/ChromiumBridge.h -nt "$OBJ/$name.o" ] || [ Sources/Chromium/ChromiumInternal.h -nt "$OBJ/$name.o" ]; then
    echo "Compiling $name.mm"
    xcrun clang++ "${CXXFLAGS[@]}" -x objective-c++ -c "$src" -o "$OBJ/$name.o"
  fi
done

# 2. The helper executable (one binary, copied into five helper bundles).
HELPER_BINARY="$OBJ/helper"
if [ ! -f "$HELPER_BINARY" ] || [ Helper/main.cc -nt "$HELPER_BINARY" ] || [ "$WRAPPER_LIB" -nt "$HELPER_BINARY" ]; then
  echo "Compiling helper"
  xcrun clang++ -std=c++20 -stdlib=libc++ -O2 -arch arm64 -isysroot "$SDK" \
    -mmacosx-version-min="$MIN_MACOS" -I"$CEF_DIR" -fno-exceptions -fno-rtti -w \
    Helper/main.cc "$WRAPPER_LIB" -framework AppKit -o "$HELPER_BINARY"
fi

# 3. Swift: the UI, linked with the bridge and the CEF wrapper library.
echo "Compiling Swift"
xcrun swiftc -O -swift-version 5 -target "arm64-apple-macos$MIN_MACOS" -sdk "$SDK" \
  -import-objc-header Sources/Chromium/Bridging-Header.h \
  -Xcc -ISources/Chromium -Xcc -I"$CEF_DIR" \
  Sources/App/*.swift "$OBJ"/ChromiumEngine.o "$OBJ"/ChromiumBrowserView.o "$OBJ"/ChromiumInput.o "$WRAPPER_LIB" \
  -Xlinker -lc++ -framework AppKit -framework SwiftUI -framework Carbon \
  -o "$OBJ/$PRODUCT"

# 4. The app bundle.
echo "Assembling $PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$OBJ/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp Config/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The agent runner (the harness), built on its own in ../runner and carried inside the app.
RUNNER_DIR="$ROOT/../runner"
if [ -d "$RUNNER_DIR" ]; then
  echo "Building the agent runner"
  (cd "$RUNNER_DIR" && { cargo build --release --offline >/dev/null 2>&1 || cargo build --release; })
  cp "$RUNNER_DIR/target/release/acorn-runner" "$APP/Contents/Resources/acorn-runner"
fi

# CEF ships a flat bundle; install it with the versioned macOS layout codesign expects.
FRAMEWORK="$APP/Contents/Frameworks/$FRAMEWORK_NAME"
mkdir -p "$FRAMEWORK/Versions/A"
rsync -a --delete "$CEF_DIR/Release/$FRAMEWORK_NAME/" "$FRAMEWORK/Versions/A/"
ln -sfn A "$FRAMEWORK/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
  ln -sfn "Versions/Current/$item" "$FRAMEWORK/$item"
done

# Helper bundles: "<Product> Helper.app", "... (GPU).app", and so on.
HELPERS=()
for variant in ":" " (Alerts):.alerts" " (GPU):.gpu" " (Plugin):.plugin" " (Renderer):.renderer"; do
  name_suffix="${variant%%:*}"
  id_suffix="${variant#*:}"
  helper_name="$PRODUCT Helper$name_suffix"
  bundle="$APP/Contents/Frameworks/$helper_name.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$HELPER_BINARY" "$bundle/Contents/MacOS/$helper_name"
  sed -e "s|\${HELPER_NAME}|$helper_name|g" \
      -e "s|\${HELPER_BUNDLE_ID}|$BUNDLE_ID.helper$id_suffix|g" \
      -e "s|\${VERSION}|0.1.0|g" -e "s|\${BUILD}|1|g" -e "s|\${MIN_MACOS}|$MIN_MACOS|g" \
      Helper/Info.plist > "$bundle/Contents/Info.plist"
  printf 'APPL????' > "$bundle/Contents/PkgInfo"
  HELPERS+=("$bundle")
done

# 5. Sign inside-out, ad hoc.
SIGN=(codesign --force --sign - --timestamp=none)
for dylib in "$FRAMEWORK/Versions/A/Libraries/"*.dylib; do "${SIGN[@]}" "$dylib"; done
"${SIGN[@]}" "$FRAMEWORK"
for bundle in "${HELPERS[@]}"; do
  "${SIGN[@]}" --options runtime --entitlements Helper/Helper.entitlements "$bundle"
done
[ -f "$APP/Contents/Resources/acorn-runner" ] && "${SIGN[@]}" "$APP/Contents/Resources/acorn-runner"
"${SIGN[@]}" --options runtime --entitlements Config/App.entitlements "$APP"

echo "Built $APP"

if [ "${1:-}" = "run" ]; then
  open "$APP"
fi
