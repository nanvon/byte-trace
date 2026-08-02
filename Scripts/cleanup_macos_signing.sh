#!/bin/bash

set -euo pipefail

if [[ -n "${BYTE_TRACE_KEYCHAIN_PATH:-}" && -f "$BYTE_TRACE_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$BYTE_TRACE_KEYCHAIN_PATH" || true
fi
if [[ -n "${BYTE_TRACE_CERT_PATH:-}" ]]; then
    rm -f "$BYTE_TRACE_CERT_PATH"
fi
