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
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
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

SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "打包失败：找不到 Sparkle.framework" >&2
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
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/ByteTraceApp"
cp "$PLIST_SOURCE" "$CONTENTS_DIR/Info.plist"
# CFBundleShortVersionString 是版本真值，Sparkle 的构建版本同步为相同版本。
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SOURCE")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_DIR/Info.plist"
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    BUILTIN_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST_SOURCE")"
    if [[ "$BUILTIN_PUBLIC_KEY" != "$SPARKLE_PUBLIC_ED_KEY" ]]; then
        echo "打包失败：项目公钥与 SPARKLE_PUBLIC_ED_KEY 不一致" >&2
        exit 1
    fi
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
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
# 保留 XPC 服务各自的 entitlement，由内向外签名，不能用 --deep 代替。
SPARKLE_CONTENTS="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
if [[ ! -x "$SPARKLE_CONTENTS/Autoupdate" || ! -d "$SPARKLE_CONTENTS/Updater.app" ]]; then
    echo "打包失败：Sparkle 安装助手缺失" >&2
    exit 1
fi
for service in "$SPARKLE_CONTENTS"/XPCServices/*.xpc; do
    [[ -d "$service" ]] || continue
    codesign "${CODE_SIGN_ARGS[@]}" --preserve-metadata=entitlements "$service"
done
codesign "${CODE_SIGN_ARGS[@]}" "$SPARKLE_CONTENTS/Autoupdate"
codesign "${CODE_SIGN_ARGS[@]}" "$SPARKLE_CONTENTS/Updater.app"
codesign "${CODE_SIGN_ARGS[@]}" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign "${CODE_SIGN_ARGS[@]}" --entitlements "$ROOT_DIR/Packaging/ByteTrace.entitlements" "$APP_DIR"

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
diskutil image create from \
    --volumeName "ByteTrace" \
    --format UDZO \
    "$DMG_STAGING_DIR" \
    "$DMG_PATH"

echo "[package] dmg=$DMG_PATH"
echo "[package] architecture=$(file -b "$MACOS_DIR/ByteTraceApp")"
echo "[package] signature=$(codesign -dv --verbose=1 "$APP_DIR" 2>&1 | awk -F= '/^(Authority|Signature)=/ { print; exit }')"
