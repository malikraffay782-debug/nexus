#!/usr/bin/env bash
# Prepare Termux bootstrap asset + Android-legal jniLibs for Nexus Studio.
# Intended for CI (and local reproducible builds).
#
# CRITICAL: We use green-green-avk static proot (talloc linked in), NOT the
# Termux dynamically-linked proot. Termux proot + libtalloc crashes with
# SIGSEGV (exit 139) on several Vivo / MediaTek devices even after RPATH
# cleanup. Static proot only needs system libc/libdl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${TARGET_TAG:-bootstrap-2026.11.01-r1+apt.android-7}"
ASSETS="studio/android/app/src/main/assets/bootstrap"
JNI="studio/android/app/src/main/jniLibs/arm64-v8a"

BOOTSTRAP_SHA="${BOOTSTRAP_SHA:-5a1429b6c68ee3bdc17b5fd6e47ba42933ec924cd7283fe74992574e1d5badae}"
# green-green-avk static proot aarch64 package (content may change; we verify structure)
STATIC_PROOT_URL="${STATIC_PROOT_URL:-https://github.com/green-green-avk/build-proot-android/raw/master/packages/proot-android-aarch64.tar.gz}"

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

echo "==> Nexus runtime prepare (tag=$TAG)"
mkdir -p "$ASSETS" "$JNI"

# Fresh jniLibs: keep only README (docs), remove previous .so so stale ELF never ships
find "$JNI" -type f \( -name '*.so' -o -name '*.so.*' \) -delete

echo "==> Download Termux bootstrap (rootfs)"
curl -fsSL -L -o "$ASSETS/bootstrap-aarch64.zip" \
  "https://github.com/termux/termux-packages/releases/download/${TAG}/bootstrap-aarch64.zip"
verify_sha "$ASSETS/bootstrap-aarch64.zip" "$BOOTSTRAP_SHA"

echo "==> Download static Android proot (green-green-avk, talloc linked in)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
curl -fsSL -L -o proot-android-aarch64.tar.gz "$STATIC_PROOT_URL"
tar xzf proot-android-aarch64.tar.gz
test -x root/bin/proot
test -f root/libexec/proot/loader

echo "==> Install Android-legal jni names (lib*.so only)"
cp -f root/bin/proot                 "$ROOT/$JNI/libproot.so"
cp -f root/libexec/proot/loader      "$ROOT/$JNI/libproot-loader.so"
if [ -f root/libexec/proot/loader32 ]; then
  cp -f root/libexec/proot/loader32  "$ROOT/$JNI/libproot-loader32.so"
fi
# Optional userland variant (kept as extra, not required at runtime)
if [ -x root/bin/proot-userland ]; then
  cp -f root/bin/proot-userland      "$ROOT/$JNI/libproot-userland.so"
fi
chmod 755 "$ROOT/$JNI"/libproot*.so

echo "==> Verify static proot has no libtalloc dependency"
if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq patchelf
fi
NEEDED="$(patchelf --print-needed "$ROOT/$JNI/libproot.so" 2>/dev/null || true)"
echo "NEEDED: ${NEEDED:-(none)}"
if echo "$NEEDED" | grep -qE 'talloc|android-shmem'; then
  echo "ERROR: static proot unexpectedly needs talloc/shmem — wrong binary?" >&2
  exit 1
fi
# Only system libs are allowed
for lib in $NEEDED; do
  case "$lib" in
    libc.so|libdl.so|libm.so|liblog.so|ld-android.so|libstdc++.so*) ;;
    *)
      echo "WARN: unexpected NEEDED entry: $lib" >&2
      ;;
  esac
done
RPATH="$(patchelf --print-rpath "$ROOT/$JNI/libproot.so" 2>/dev/null || true)"
echo "RPATH: ${RPATH:-(empty)}"
if echo "$RPATH" | grep -q '/data/data/com.termux'; then
  echo "ERROR: Termux absolute RUNPATH present" >&2
  exit 1
fi

echo "==> Final jniLibs"
ls -lh "$ROOT/$JNI"
echo "==> Runtime prepare done (static proot)"
