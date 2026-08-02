#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/ByteTrace.app"
ZIP_PATH="$DIST_DIR/ByteTrace.zip"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_SOURCE="$ROOT_DIR/Packaging/Info.plist"
SIGNING_IDENTITY="${BYTE_TRACE_SIGNING_IDENTITY:--}"
SWIFT_TRIPLE="${BYTE_TRACE_SWIFT_TRIPLE:-}"

SWIFT_BUILD_ARGS=(
    --configuration release
    --product ByteTraceApp
    --package-path "$ROOT_DIR"
)
if [[ -n "$SWIFT_TRIPLE" ]]; then
    SWIFT_BUILD_ARGS+=(--triple "$SWIFT_TRIPLE")
fi

if [[ ! -f "$PLIST_SOURCE" ]]; then
    echo "missing packaging plist: $PLIST_SOURCE" >&2
    exit 1
fi

echo "[package] building ByteTraceApp in release mode"
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build --show-bin-path "${SWIFT_BUILD_ARGS[@]}")"
EXECUTABLE="$BIN_DIR/ByteTraceApp"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "missing release executable: $EXECUTABLE" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
if [[ -e "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/ByteTraceApp"
cp "$PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

plutil -convert binary1 "$CONTENTS_DIR/Info.plist"
xattr -cr "$APP_DIR"

echo "[package] signing with identity: $SIGNING_IDENTITY"
CODE_SIGN_ARGS=(
    --force
    --options runtime
    --sign "$SIGNING_IDENTITY"
)
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    CODE_SIGN_ARGS+=(--timestamp=none)
else
    CODE_SIGN_ARGS+=(--timestamp)
fi
codesign "${CODE_SIGN_ARGS[@]}" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc "$APP_DIR" "$ZIP_PATH"

echo "[package] app=$APP_DIR"
echo "[package] archive=$ZIP_PATH"
echo "[package] architecture=$(file -b "$MACOS_DIR/ByteTraceApp")"
echo "[package] signature=$(codesign -dv --verbose=1 "$APP_DIR" 2>&1 | awk -F= '/^(Authority|Signature)=/ { print; exit }')"
