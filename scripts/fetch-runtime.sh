#!/usr/bin/env bash
set -euo pipefail

# Nexus Phase 0 – Fetch Termux bootstrap
# Usage: bash scripts/fetch-runtime.sh [arch]
#
# Pin TARGET_TAG to a known-good release. Do not rely on floating "latest"
# for reproducible builds. Optionally set EXPECTED_SHA256 to verify.

ARCH="${1:-aarch64}"
ASSETS_DIR="studio/android/app/src/main/assets/bootstrap"
JNI_DIR="studio/android/app/src/main/jniLibs/arm64-v8a"

# Pin this for reproducible builds. Override with: TARGET_TAG=vX.Y.Z bash scripts/fetch-runtime.sh
TARGET_TAG="${TARGET_TAG:-}"
# Optional: EXPECTED_SHA256=... bash scripts/fetch-runtime.sh
EXPECTED_SHA256="${EXPECTED_SHA256:-}"

mkdir -p "$ASSETS_DIR" "$JNI_DIR"

if [ -z "$TARGET_TAG" ]; then
  echo "==> No TARGET_TAG set – resolving latest (not recommended for release builds)"
  TARGET_TAG=$(curl -fsSL "https://api.github.com/repos/termux/termux-packages/releases/latest" \
    | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("tag_name",""))' 2>/dev/null || true)
  if [ -z "$TARGET_TAG" ]; then
    echo "Failed to get latest release tag. Set TARGET_TAG=... explicitly."
    exit 1
  fi
fi

echo "==> Using tag: $TARGET_TAG (arch=$ARCH)"

BOOTSTRAP_URL="https://github.com/termux/termux-packages/releases/download/${TARGET_TAG}/bootstrap-${ARCH}.zip"
OUT_FILE="${ASSETS_DIR}/bootstrap-${ARCH}.zip"

echo "Downloading: $BOOTSTRAP_URL"
curl -fsSL --fail -o "$OUT_FILE" "$BOOTSTRAP_URL"

if [ -n "$EXPECTED_SHA256" ]; then
  echo "Verifying SHA-256..."
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${EXPECTED_SHA256}  ${OUT_FILE}" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    echo "${EXPECTED_SHA256}  ${OUT_FILE}" | shasum -a 256 -c -
  else
    echo "No sha256sum/shasum found; cannot verify"
    exit 1
  fi
  echo "✓ Checksum OK"
else
  echo "NOTE: EXPECTED_SHA256 not set – skipped integrity check"
fi

echo ""
echo "✓ Bootstrap saved to: $OUT_FILE"
echo ""
echo "-----------------------------------------------------------"
echo "NEXT: proot binaries still needed manually"
echo "  Copy libproot.so + libproot-loader.so into:"
echo "  $JNI_DIR/"
echo "-----------------------------------------------------------"
