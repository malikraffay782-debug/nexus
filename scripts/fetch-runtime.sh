#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   TARGET_TAG=bootstrap-2025.01.01 bash scripts/fetch-runtime.sh aarch64
# Optional:
#   EXPECTED_SHA256=... TARGET_TAG=... bash scripts/fetch-runtime.sh aarch64

ARCH="${1:-aarch64}"
ASSETS_DIR="studio/android/app/src/main/assets/bootstrap"
JNI_DIR="studio/android/app/src/main/jniLibs/arm64-v8a"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"

mkdir -p "$ASSETS_DIR" "$JNI_DIR"

if [ -z "${TARGET_TAG:-}" ]; then
  echo "ERROR: TARGET_TAG must be set for reproducible builds."
  echo "Example:"
  echo "  TARGET_TAG=\$(curl -fsSL https://api.github.com/repos/termux/termux-packages/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"tag_name\"])')"
  echo "  TARGET_TAG=\$TARGET_TAG bash scripts/fetch-runtime.sh aarch64"
  exit 1
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
    echo "No sha256 tool found"; exit 1
  fi
  echo "✓ Checksum OK"
fi

echo "✓ Bootstrap saved to: $OUT_FILE"
echo "Next: copy libproot.so + libproot-loader.so into $JNI_DIR/"
