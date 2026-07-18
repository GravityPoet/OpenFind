#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: customer builds require macOS." >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_SIGNING_CERT_SHA1="3E146B469F41DEB31E45C28D0E9C512B3E5A41C1"
SPARKLE_FEED_URL="https://github.com/GravityPoet/OpenFind/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="cEyTyoGRNVCvBrxRPdVYVhz6n8vqYQ3faOoAZfkt48E="

if ! security find-identity -v -p codesigning \
    | grep -F "$EXPECTED_SIGNING_CERT_SHA1" \
    | grep -Fq '"OpenFind Customer Code Signing"'; then
    echo "Error: the pinned OpenFind customer signing identity is unavailable." >&2
    exit 2
fi

DISTRIBUTION=customer \
SIGN_IDENTITY="$EXPECTED_SIGNING_CERT_SHA1" \
EXPECTED_SIGNING_CERT_SHA1="$EXPECTED_SIGNING_CERT_SHA1" \
SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
bash "$ROOT_DIR/Scripts/build_app.sh"
