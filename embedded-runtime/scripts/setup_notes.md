# How to complete Phase 0 (Manual steps still required)

## 1. Symlink handling (FIXED)

BootstrapManager now follows the **official Termux method**:

1. Extract all regular files from the zip (Zip Slip protected).
2. When it encounters `SYMLINKS.txt`, parse lines of the form:
   ```
   target←relative/link/path
   ```
3. After extraction, recreate every symlink with `android.system.Os.symlink()`.

This is exactly how `termux-app` installs its own bootstrap.  
`bin/sh`, `usr/bin/*` links, etc. will now be real symlinks instead of broken text files.

## 2. Get proot + loader

From a working Termux installation:

```bash
pkg install proot
# copy these into studio/android/app/src/main/jniLibs/arm64-v8a/
#   libproot.so          (or rename proot binary)
#   libproot-loader.so   (from $PREFIX/libexec/proot/)
#   libtalloc.so / libandroid-shmem.so if required
```

## 3. Get Bootstrap

Download from Termux packages releases:

https://github.com/termux/termux-packages/releases

Place:

```
studio/android/app/src/main/assets/bootstrap/bootstrap-aarch64.zip
```

(and other arches if needed)

## 4. Open the project

```bash
cd studio
flutter pub get
# then open in Android Studio / VS Code
```

MainActivity already registers `RuntimePlugin`.

## 5. First test

Run the app → tap **Initialize** → then **Smoke Tests**.

You should see real output from `uname`, `python3 --version`, etc. once binaries + bootstrap are present.
