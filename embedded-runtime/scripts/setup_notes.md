# How to complete Phase 0 (Manual steps required)

The Kotlin + Dart code is ready. You still need the actual binaries.

## 1. Get proot + loader

Best source (from a working Termux installation on device or CI):

```bash
# Inside Termux
pkg install proot
ls $PREFIX/libexec/proot/          # loader and loader32
ls $PREFIX/bin/proot
find $PREFIX -name "*talloc*"
find $PREFIX -name "*android-shmem*"
```

Copy these into your Android project:

```
android/app/src/main/jniLibs/arm64-v8a/
    libproot.so
    libproot-loader.so
    libtalloc.so
    libandroid-shmem.so   (if required)
```

Rename carefully so System.loadLibrary / File lookup works with the names used in ProotExecutor.

## 2. Get Bootstrap

Official Termux bootstrap zips are published in termux-packages releases:

https://github.com/termux/termux-packages/releases

Download `bootstrap-aarch64.zip` (and others if needed) and place them at:

```
android/app/src/main/assets/bootstrap/bootstrap-aarch64.zip
android/app/src/main/assets/bootstrap/bootstrap-arm.zip
...
```

## 3. Register the plugin

In your `MainActivity.kt` (or generated Flutter embedding):

```kotlin
flutterEngine.plugins.add(RuntimePlugin())
```

Or use the standard Flutter plugin registration if you convert it into a proper plugin later.

## 4. First test from Flutter

```dart
final init = await EmbeddedRuntime.initialize();
if (!init.success) {
  print("Init failed: ${init.error}");
  return;
}

print(await EmbeddedRuntime.pythonVersion());
print(await EmbeddedRuntime.exec("uname -a"));
print(await EmbeddedRuntime.exec("ls -la /bin | head"));
```

## 5. Next improvements after smoke test passes

- Add progress callback during bootstrap extraction (large zip)
- Support `pkg install` by implementing a simple package manager wrapper
- Pre-bundle a minimal Python + pip
- Add aarch64-only first, then expand
- Background service so long-running processes survive

---

This is the heavy foundation. Once `python3 --version` works from Flutter, Phase 0 is basically done.
---

## CRITICAL: Symlink problem with Java ZipInputStream (B3)

Java's built-in `ZipInputStream` **does not restore Unix symlinks**.

Termux bootstrap contains many symlinks, for example:
- `bin/sh` → `dash`
- `usr/bin/*` → relative links
- many `.so` links

After a normal Java zip extract, `bin/sh` becomes a **regular text file** containing the word "dash".  
Result: `/bin/sh -c ...` fails with "Exec format error" and almost nothing works (including python3).

### Proper fixes (pick one later)

1. **Best**: Switch bootstrap format to `.tar.gz` and use Apache Commons Compress (`TarArchiveInputStream`) which supports symlinks + modes.
2. Or use a library that can read zip external attributes / symlink flag and recreate links with `Files.createSymbolicLink`.
3. Temporary workaround some projects use: after extract, run a small native helper or a pre-built script that recreates the known critical links.

Until this is fixed, even with correct binaries the runtime will not be usable for real commands.
