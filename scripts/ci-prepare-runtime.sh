#!/usr/bin/env bash
# Prepare Termux bootstrap asset + Android-legal jniLibs for Nexus Studio.
# Intended for CI (and local reproducible builds).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${TARGET_TAG:-bootstrap-2026.11.01-r1+apt.android-7}"
ASSETS="studio/android/app/src/main/assets/bootstrap"
JNI="studio/android/app/src/main/jniLibs/arm64-v8a"
BASE="https://packages.termux.dev/apt/termux-main"

BOOTSTRAP_SHA="${BOOTSTRAP_SHA:-5a1429b6c68ee3bdc17b5fd6e47ba42933ec924cd7283fe74992574e1d5badae}"
PROOT_SHA="${PROOT_SHA:-10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030}"
TALLOC_SHA="${TALLOC_SHA:-556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7}"
SHMEM_SHA="${SHMEM_SHA:-0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6}"

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

echo "==> Download bootstrap"
curl -fsSL -L -o "$ASSETS/bootstrap-aarch64.zip" \
  "https://github.com/termux/termux-packages/releases/download/${TAG}/bootstrap-aarch64.zip"
verify_sha "$ASSETS/bootstrap-aarch64.zip" "$BOOTSTRAP_SHA"

echo "==> Download proot + deps (.deb)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
curl -fsSL -L -o proot.deb  "$BASE/pool/main/p/proot/proot_5.1.107.102_aarch64.deb"
curl -fsSL -L -o talloc.deb "$BASE/pool/main/libt/libtalloc/libtalloc_2.5.0_aarch64.deb"
curl -fsSL -L -o shmem.deb  "$BASE/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb"
verify_sha proot.deb  "$PROOT_SHA"
verify_sha talloc.deb "$TALLOC_SHA"
verify_sha shmem.deb  "$SHMEM_SHA"

echo "==> Extract debs"
mkdir debroot && cd debroot
for d in proot.deb talloc.deb shmem.deb; do
  ar x "../$d"
  tar xf data.tar.* 2>/dev/null || true
  rm -f data.tar.* control.tar.* debian-binary
done
USR="data/data/com.termux/files/usr"
test -x "$USR/bin/proot"
test -f "$USR/libexec/proot/loader"
test -f "$USR/lib/libtalloc.so.2.5.0"
test -f "$USR/lib/libandroid-shmem.so"

echo "==> Install Android-legal jni names only (lib*.so)"
cp -f "$USR/bin/proot"              "$ROOT/$JNI/libproot.so"
cp -f "$USR/libexec/proot/loader"   "$ROOT/$JNI/libproot-loader.so"
# 32-bit loader if present (some proot builds ship it)
if [ -f "$USR/libexec/proot/loader32" ]; then
  cp -f "$USR/libexec/proot/loader32" "$ROOT/$JNI/libproot-loader32.so"
fi
cp -f "$USR/lib/libandroid-shmem.so" "$ROOT/$JNI/libandroid-shmem.so"
cp -f "$USR/lib/libtalloc.so.2.5.0"  "$ROOT/$JNI/libtalloc.so"
chmod 755 "$ROOT/$JNI"/lib*.so

echo "==> patchelf: Android-legal sonames + \$ORIGIN rpath (critical for Vivo/MTK)"
if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq patchelf
fi

# 1. libtalloc.so.2 → libtalloc.so  (Android only extracts plain lib*.so)
# 2. Kill the Termux absolute RUNPATH. It points at a path that does not exist
#    inside our app process and causes SIGSEGV on several MediaTek / Vivo kernels
#    when the linker + proot loader interact with it.
# 3. Set RPATH=\$ORIGIN so sibling libs in nativeLibraryDir are found reliably.
for bin in libproot.so libproot-loader.so libproot-loader32.so; do
  f="$ROOT/$JNI/$bin"
  [ -f "$f" ] || continue
  if patchelf --print-needed "$f" 2>/dev/null | grep -q 'libtalloc\.so\.2'; then
    patchelf --replace-needed libtalloc.so.2 libtalloc.so "$f"
  fi
  # Prefer $ORIGIN; fall back to removing rpath entirely if the tool is old.
  if ! patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null; then
    patchelf --remove-rpath "$f" 2>/dev/null || true
  fi
done

echo "==> Verify ELF deps + rpath"
NEEDED="$(patchelf --print-needed "$ROOT/$JNI/libproot.so")"
echo "NEEDED: $NEEDED"
if echo "$NEEDED" | grep -q 'libtalloc\.so\.2'; then
  echo "ERROR: proot still needs libtalloc.so.2" >&2
  exit 1
fi
echo "$NEEDED" | grep -q 'libtalloc\.so' || {
  echo "ERROR: proot does not list libtalloc.so after patchelf" >&2
  exit 1
}
RPATH="$(patchelf --print-rpath "$ROOT/$JNI/libproot.so" 2>/dev/null || true)"
echo "RPATH:  ${RPATH:-(empty)}"
if echo "$RPATH" | grep -q '/data/data/com.termux'; then
  echo "ERROR: Termux absolute RUNPATH still present — this crashes on Vivo/MTK" >&2
  exit 1
fi

echo "==> Final jniLibs"
ls -lh "$ROOT/$JNI"
# Extra safety: show final dynamic section for the main binary
patchelf --print-needed "$ROOT/$JNI/libproot.so" || true
patchelf --print-rpath  "$ROOT/$JNI/libproot.so" 2>/dev/null || true

echo "==> Runtime prepare done"
