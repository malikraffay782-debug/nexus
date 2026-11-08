#!/usr/bin/env bash
# Prepare Termux bootstrap asset + Android-legal jniLibs for Nexus Studio.
#
# Uses ahmed-alnassif proot builds: Termux proot source + statically linked
# talloc. That combination is required on modern Android:
#   - Termux patches handle zygote seccomp (chmod/chdir/execve ENOSYS)
#   - Static talloc avoids the dynamic libtalloc SIGSEGV on Vivo/MTK
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${TARGET_TAG:-bootstrap-2026.11.01-r1+apt.android-7}"
ASSETS="studio/android/app/src/main/assets/bootstrap"
JNI="studio/android/app/src/main/jniLibs/arm64-v8a"

BOOTSTRAP_SHA="${BOOTSTRAP_SHA:-5a1429b6c68ee3bdc17b5fd6e47ba42933ec924cd7283fe74992574e1d5badae}"
PROOT_REL="${PROOT_REL:-v26.10.08-a179d3e}"
PROOT_URL="${PROOT_URL:-https://github.com/ahmed-alnassif/proot/releases/download/${PROOT_REL}/proot-aarch64.zip}"

verify_sha() {
  local file="$1" expect="$2"
  local got
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$got" != "$expect" ]; then
    echo "SHA256 mismatch for $file" >&2
    echo "  expected: $expect" >&2
    echo "  got:      $got" >&2
    exit 1
  fi
  echo "OK sha256 $(basename "$file")"
}

echo "==> Nexus runtime prepare (bootstrap=$TAG proot=$PROOT_REL)"
mkdir -p "$ASSETS" "$JNI"

# Fresh jniLibs: keep only README (docs), remove previous .so so stale ELF never ships
find "$JNI" -type f \( -name '*.so' -o -name '*.so.*' \) -delete

echo "==> Download Termux bootstrap (rootfs)"
curl -fsSL -L -o "$ASSETS/bootstrap-aarch64.zip" \
  "https://github.com/termux/termux-packages/releases/download/${TAG}/bootstrap-aarch64.zip"
verify_sha "$ASSETS/bootstrap-aarch64.zip" "$BOOTSTRAP_SHA"

echo "==> Download Termux-based static proot (ahmed-alnassif)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
curl -fsSL -L -o proot-aarch64.zip "$PROOT_URL"
unzip -o proot-aarch64.zip
test -f proot
test -f loader

echo "==> Install Android-legal jni names (lib*.so only)"
cp -f proot  "$ROOT/$JNI/libproot.so"
cp -f loader "$ROOT/$JNI/libproot-loader.so"
if [ -f loader-m32 ]; then
  cp -f loader-m32 "$ROOT/$JNI/libproot-loader32.so"
fi
chmod 755 "$ROOT/$JNI"/libproot*.so

echo "==> Verify proot has no libtalloc dependency"
if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq patchelf
fi
NEEDED="$(patchelf --print-needed "$ROOT/$JNI/libproot.so" 2>/dev/null || true)"
echo "NEEDED: ${NEEDED:-(none)}"
if echo "$NEEDED" | grep -qi talloc; then
  echo "ERROR: proot unexpectedly needs talloc — wrong binary?" >&2
  exit 1
fi
RPATH="$(patchelf --print-rpath "$ROOT/$JNI/libproot.so" 2>/dev/null || true)"
echo "RPATH: ${RPATH:-(empty)}"
if echo "$RPATH" | grep -q '/data/data/com.termux'; then
  echo "ERROR: Termux absolute RUNPATH present" >&2
  exit 1
fi

echo "==> Final jniLibs"
ls -lh "$ROOT/$JNI"
echo "==> Runtime prepare done (Termux-proot + static talloc)"
