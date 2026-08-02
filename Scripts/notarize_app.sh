#!/bin/bash

set -euo pipefail

APP_PATH="${1:?usage: notarize_app.sh /path/to/ByteTrace.app}"
if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
    echo "expected an existing .app directory: $APP_PATH" >&2
    exit 1
fi

: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}"
: "${APPLE_API_KEY_BASE64:?APPLE_API_KEY_BASE64 is required}"

TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
API_KEY_PATH="$TEMP_ROOT/AuthKey_${APPLE_API_KEY_ID}.p8"
ZIP_PATH="${APP_PATH%.app}.zip"

cleanup() {
    rm -f "$API_KEY_PATH"
}
trap cleanup EXIT

printf '%s' "$APPLE_API_KEY_BASE64" | base64 -D > "$API_KEY_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[notary] submitting $(basename "$ZIP_PATH")"
xcrun notarytool submit "$ZIP_PATH" \
    --key "$API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

# Stapling changes the bundle; recreate the distributable archive afterwards.
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "[notary] notarized and stapled: $APP_PATH"
