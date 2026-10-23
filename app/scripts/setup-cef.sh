#!/bin/bash
# Puts the pinned CEF (Chromium Embedded Framework) build into ThirdParty/cef and compiles
# libcef_dll_wrapper.a. Safe to re-run; it skips work that is already done.
#
# If CEF_SOURCE points at an already extracted copy of the same version, that copy is used
# instead of downloading the archive.
set -euo pipefail

CEF_VERSION="154.0.33+ga03e714+chromium-154.0.8037.94"
CEF_PLATFORM="macosarm64"
CEF_SHA1="bfa2358a5fba8d0a016118941d9cda0bf2d06f20"
CEF_ARCHIVE="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$CEF_ARCHIVE")"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THIRD_PARTY="$ROOT/ThirdParty"
CEF_DIR="$THIRD_PARTY/cef"
DOWNLOADS="$THIRD_PARTY/.downloads"
WRAPPER_LIB="$CEF_DIR/build/libcef_dll_wrapper.a"
MIN_MACOS="15.0"

mkdir -p "$DOWNLOADS"

if [ ! -f "$CEF_DIR/.version" ] || [ "$(cat "$CEF_DIR/.version")" != "$CEF_VERSION" ]; then
  if [ -n "${CEF_SOURCE:-}" ] && [ -f "$CEF_SOURCE/.version" ] && [ "$(cat "$CEF_SOURCE/.version")" = "$CEF_VERSION" ]; then
    echo "Copying CEF from $CEF_SOURCE ..."
    rm -rf "$CEF_DIR"
    cp -R "$CEF_SOURCE" "$CEF_DIR"
  else
    if [ ! -f "$DOWNLOADS/$CEF_ARCHIVE" ]; then
      echo "Downloading $CEF_ARCHIVE ..."
      curl -fL --progress-bar -C - -o "$DOWNLOADS/$CEF_ARCHIVE.part" "$CEF_URL"
      mv "$DOWNLOADS/$CEF_ARCHIVE.part" "$DOWNLOADS/$CEF_ARCHIVE"
    fi

    echo "Verifying checksum ..."
    echo "$CEF_SHA1  $DOWNLOADS/$CEF_ARCHIVE" | shasum -a 1 -c -

    echo "Extracting ..."
    rm -rf "$CEF_DIR" "$THIRD_PARTY/.extract"
    mkdir -p "$THIRD_PARTY/.extract"
    tar -xjf "$DOWNLOADS/$CEF_ARCHIVE" -C "$THIRD_PARTY/.extract"
    mv "$THIRD_PARTY/.extract/"cef_binary_* "$CEF_DIR"
    rmdir "$THIRD_PARTY/.extract"
    echo "$CEF_VERSION" > "$CEF_DIR/.version"
  fi
fi

if [ ! -f "$WRAPPER_LIB" ]; then
  echo "Compiling libcef_dll_wrapper ..."
  OBJ_DIR="$CEF_DIR/build/obj"
  rm -rf "$OBJ_DIR"
  mkdir -p "$OBJ_DIR"

  SDK="$(xcrun --sdk macosx --show-sdk-path)"
  COMMON_FLAGS=(
    -arch arm64 -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS"
    -I"$CEF_DIR" -DWRAPPING_CEF_SHARED -DNDEBUG -O2 -fPIC
    -fno-strict-aliasing -fstack-protector -fvisibility=hidden -w
  )

  # Compile in parallel; each source becomes a uniquely named object.
  export CEF_DIR OBJ_DIR
  export COMMON_FLAGS_STR="${COMMON_FLAGS[*]}"
  find "$CEF_DIR/libcef_dll" \( -name '*.cc' -o -name '*.mm' \) -print0 |
    xargs -0 -n 1 -P "$(sysctl -n hw.ncpu)" bash -c '
      src="$1"
      rel="${src#$CEF_DIR/}"
      obj="$OBJ_DIR/$(echo "$rel" | tr "/" "_").o"
      case "$src" in
        *.mm) lang=(-x objective-c++ -fobjc-arc) ;;
        *)    lang=(-x c++) ;;
      esac
      xcrun clang++ "${lang[@]}" -std=c++20 -stdlib=libc++ $COMMON_FLAGS_STR -c "$src" -o "$obj"
    ' _

  xcrun libtool -static -o "$WRAPPER_LIB" "$OBJ_DIR"/*.o
  rm -rf "$OBJ_DIR"
fi

echo "CEF ready: $CEF_DIR ($CEF_VERSION)"
