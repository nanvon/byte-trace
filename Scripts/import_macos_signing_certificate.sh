#!/bin/bash

set -euo pipefail

: "${MACOS_CERTIFICATE_P12_BASE64:?MACOS_CERTIFICATE_P12_BASE64 is required}"
: "${MACOS_CERTIFICATE_PASSWORD:?MACOS_CERTIFICATE_PASSWORD is required}"
: "${MACOS_KEYCHAIN_PASSWORD:?MACOS_KEYCHAIN_PASSWORD is required}"
: "${APPLE_DEVELOPER_ID_APPLICATION:?APPLE_DEVELOPER_ID_APPLICATION is required}"

TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
KEYCHAIN_PATH="$TEMP_ROOT/byte-trace-signing.keychain-db"
CERT_PATH="$TEMP_ROOT/byte-trace-signing.p12"

printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 -D > "$CERT_PATH"
security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$MACOS_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$MACOS_KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | grep -Fq "\"$APPLE_DEVELOPER_ID_APPLICATION\""; then
    echo "imported keychain does not contain the requested Developer ID identity" >&2
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" >&2 || true
    exit 1
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        echo "BYTE_TRACE_KEYCHAIN_PATH=$KEYCHAIN_PATH"
        echo "BYTE_TRACE_CERT_PATH=$CERT_PATH"
    } >> "$GITHUB_ENV"
fi

echo "[signing] imported Developer ID identity: $APPLE_DEVELOPER_ID_APPLICATION"
