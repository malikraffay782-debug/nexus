#!/usr/bin/env bash
set -euo pipefail

# Nexus Phase 0 – Fetch Termux bootstrap (and show proot instructions)
# Run from repo root:  bash scripts/fetch-runtime.sh [arch]

ARCH="${1:-aarch64}"
ASSETS_DIR="studio/android/app/src/main/assets/bootstrap"
JNI_DIR="studio/android/app/src/main/jniLibs/arm64-v8a"

mkdir -p "$ASSETS_DIR" "$JNI_DIR"

echo "==> Fetching latest Termux bootstrap for $ARCH ..."

# Portable tag fetch (works on macOS/BSD/Linux – no GNU grep -P)
TAG=$(curl -fsSL "https://api.github.com/repos/termux/termux-packages/releases/latest" \
  | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("tag_name",""))' 2>/dev/null || true)

if [ -z "$TAG" ]; then
  echo "Failed to get latest release tag"
  exit 1
fi

echo "Latest tag: $TAG"

BOOTSTRAP_URL="https://github.com/termux/termux-packages/releases/download/${TAG}/bootstrap-${ARCH}.zip"
OUT_FILE="${ASSETS_DIR}/bootstrap-${ARCH}.zip"

echo "Downloading: $BOOTSTRAP_URL"
curl -L --fail -o "$OUT_FILE" "$BOOTSTRAP_URL"

echo ""
echo "✓ Bootstrap saved to: $OUT_FILE"
echo ""
echo "-----------------------------------------------------------"
echo "NEXT: You still need proot binaries manually"
echo "-----------------------------------------------------------"
echo "On a device/emulator that already has Termux:"
echo ""
echo "  pkg install proot"
echo "  # then copy these files into:"
echo "  #   $JNI_DIR/"
echo ""
echo "  - \$PREFIX/bin/proot           →  libproot.so   (or keep name proot)"
echo "  - \$PREFIX/libexec/proot/loader → libproot-loader.so"
echo "  - any required .so (talloc, android-shmem) if the loader needs them"
echo ""
echo "After that:"
echo "  cd studio && flutter pub get"
echo "  # open in Android Studio / run on device"
echo "-----------------------------------------------------------"
