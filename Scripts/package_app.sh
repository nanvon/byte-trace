#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/ByteTrace.app"
ZIP_PATH="$DIST_DIR/ByteTrace.zip"
DMG_PATH="$DIST_DIR/ByteTrace.dmg"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_SOURCE="$ROOT_DIR/Packaging/Info.plist"
ICON_SOURCE="$ROOT_DIR/Packaging/Resources/ByteTrace.icns"
MENUBAR_ICON_DIR="$ROOT_DIR/Packaging/Resources/MenuBar"
SIGNING_IDENTITY="${BYTE_TRACE_SIGNING_IDENTITY:--}"
SWIFT_TRIPLE="${BYTE_TRACE_SWIFT_TRIPLE:-}"

SWIFT_BUILD_ARGS=(
    --configuration release
    --product ByteTraceApp
    --package-path "$ROOT_DIR"
)

if [[ ! -f "$PLIST_SOURCE" ]]; then
    echo "missing packaging plist: $PLIST_SOURCE" >&2
    exit 1
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "missing app icon: $ICON_SOURCE" >&2
    exit 1
fi
for menubar_scale in "" "@2x" "@3x"; do
    menubar_icon="$MENUBAR_ICON_DIR/MenuBarIcon${menubar_scale}.png"
    if [[ ! -f "$menubar_icon" ]]; then
        echo "missing menu bar icon: $menubar_icon" >&2
        exit 1
    fi
done

MACOS_MINIMUM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST_SOURCE")"
SWIFT_TRIPLE="${SWIFT_TRIPLE:-arm64-apple-macosx${MACOS_MINIMUM_VERSION}}"
if [[ "$SWIFT_TRIPLE" != "arm64-apple-macosx${MACOS_MINIMUM_VERSION}" ]]; then
    echo "打包失败：仅支持 arm64-apple-macosx${MACOS_MINIMUM_VERSION} 目标" >&2
    exit 1
fi
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Swift 6.4 默认构建系统可能把 SDK 错记为部署版本，影响 AppKit / SwiftUI 的系统外观。
# 显式传入实际 SDK 与最低系统版本，二者不能混用。
SWIFT_BUILD_ARGS+=(
    --triple "$SWIFT_TRIPLE"
    --sdk "$MACOS_SDK_PATH"
    -Xlinker -platform_version
    -Xlinker macos
    -Xlinker "$MACOS_MINIMUM_VERSION"
    -Xlinker "$MACOS_SDK_VERSION"
)

echo "[package] building ByteTraceApp in release mode"
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build --show-bin-path "${SWIFT_BUILD_ARGS[@]}")"
EXECUTABLE="$BIN_DIR/ByteTraceApp"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "missing release executable: $EXECUTABLE" >&2
    exit 1
fi

MACOS_BUILD_INFO="$(xcrun vtool -show-build "$EXECUTABLE")"
BUILT_MINIMUM_MACOS_VERSION="$(awk '$1 == "minos" { print $2 }' <<< "$MACOS_BUILD_INFO")"
BUILT_MACOS_SDK_VERSION="$(awk '$1 == "sdk" { print $2 }' <<< "$MACOS_BUILD_INFO")"
if [[ "$BUILT_MINIMUM_MACOS_VERSION" != "$MACOS_MINIMUM_VERSION" ||
      "$BUILT_MACOS_SDK_VERSION" != "$MACOS_SDK_VERSION" ]]; then
    echo "打包失败：二进制的最低系统或 SDK 版本与构建配置不一致" >&2
    printf '%s\n' "$MACOS_BUILD_INFO" >&2
    exit 1
fi
if [[ "$(lipo -archs "$EXECUTABLE")" != "arm64" ]]; then
    echo "打包失败：二进制必须仅包含 arm64 架构" >&2
    exit 1
fi
echo "[package] minimum macOS=$BUILT_MINIMUM_MACOS_VERSION, SDK=$BUILT_MACOS_SDK_VERSION"

mkdir -p "$DIST_DIR"
if [[ -e "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/ByteTraceApp"
cp "$PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
cp "$ICON_SOURCE" "$RESOURCES_DIR/ByteTrace.icns"
# 菜单栏图标按 1x/2x/3x 三档打包：url(forResource:) 不做 @2x 变体匹配，
# 由 ByteTraceMenuBarIcon 显式组装成多 representation 的 NSImage。
for menubar_scale in "" "@2x" "@3x"; do
    cp "$MENUBAR_ICON_DIR/MenuBarIcon${menubar_scale}.png" \
       "$RESOURCES_DIR/MenuBarIcon${menubar_scale}.png"
done
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
echo "[package] zip=$ZIP_PATH"

DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ByteTrace-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT
ditto "$APP_DIR" "$DMG_STAGING_DIR/ByteTrace.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "ByteTrace" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "[package] dmg=$DMG_PATH"
echo "[package] architecture=$(file -b "$MACOS_DIR/ByteTraceApp")"
echo "[package] signature=$(codesign -dv --verbose=1 "$APP_DIR" 2>&1 | awk -F= '/^(Authority|Signature)=/ { print; exit }')"
