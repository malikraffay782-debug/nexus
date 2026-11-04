# Nexus

**Mobile-first Hybrid Engine + Studio** with an **embedded Linux runtime** (Termux-style proot + bootstrap) inside a Flutter Android app.

- **Repo:** https://github.com/malikraffay782-debug/nexus  
- **Package ID:** `com.nexus.studio`  
- **Min SDK:** 26 · **Target SDK:** 34 · **Compile SDK:** 35  
- **Primary ABI for runtime:** `arm64-v8a` (aarch64)

This README is written so a **human or another AI** can continue work without the original chat history.

---

## 1. Product goal

Build a **Studio** (projects, code editor, later scenes/blocks) on Flutter, and an **embedded Linux userspace** for Python/tools — **without** depending on a separate Termux app.

| Layer | Responsibility |
|-------|----------------|
| **Studio (Flutter)** | UI, projects, editor, Run button, Runtime debug screen |
| **Bridge** | MethodChannel `com.nexus/runtime` + progress EventChannel |
| **Kotlin runtime** | Bootstrap extract, proot exec, package install, project mount |
| **Embedded Linux** | Termux bootstrap prefix under app private storage |

**Architecture rule:** game rendering / frame loop stays on **Flutter/Android**. proot is for **code, tools, packages** — not GPU inside Linux.

---

## 2. End-to-end flow (read this first)

```
User opens Nexus Studio
  → Projects list (documents/.../projects/<id>/)
  → Create Game or App project
  → Workspace: file tree + code editor (src/main.py default)
  → Runtime tab: Initialize → extracts bootstrap zip from APK assets
  → Install Python → pkg install python inside proot
  → Run → Kotlin binds projects/<id> → /home/project, runs python3 src/main.py
```

### 2.1 Data paths (must stay in sync)

| Side | Path |
|------|------|
| Flutter projects root | `getApplicationDocumentsDirectory()/projects` |
| Kotlin projects root | `context.getDir("flutter", MODE_PRIVATE)/projects` |
| Same on device | `/data/user/0/com.nexus.studio/app_flutter/projects` |
| Runtime prefix | under app files (BootstrapManager `prefixDir`) |
| Guest project mount | host `projects/<id>` → guest `/home/project` |

Only **projectId** crosses the bridge for Run. Kotlin resolves the host path (no path injection from Dart).

### 2.2 MethodChannel API (`com.nexus/runtime`)

Implemented in `RuntimePlugin.kt` → `NexusRuntime` → `BootstrapManager` / `ProotExecutor` / `PackageManager` / `ProjectMount`.

| Method | Purpose |
|--------|---------|
| `initialize` | Extract bootstrap if needed; progress events |
| `isReady` | Bootstrap present and usable |
| `runCommand` | Trusted shell command in proot |
| `runProject` | Mount project + run `python3 /home/project/src/main.py` |
| `installPackage` | `pkg`/`apt` install validated names |
| `updatePackages` | apt/pkg update |
| `pythonVersion` / `hasBinary` | probes |
| `getPrefixPath` / `getRuntimeRoot` | debug paths |

Flutter wrapper: `studio/lib/services/embedded_runtime.dart`.  
UI adapter: `RuntimeFacade` / `EmbeddedRuntimeFacade` in runtime_debug feature.

### 2.3 Bootstrap + proot packaging

- Asset: `studio/android/app/src/main/assets/bootstrap/bootstrap-aarch64.zip`  
  (gitignored; **CI downloads** Termux bootstrap before build)
- Native: `jniLibs/arm64-v8a/libproot.so` (proot binary renamed),  
  `libproot-loader.so`, `libtalloc.so`, `libandroid-shmem.so`
- `extractNativeLibs=true` + `useLegacyPackaging=true` so proot is executable from `nativeLibraryDir`

Without bootstrap in the APK, Initialize fails with:  
`Bootstrap asset not found: bootstrap/bootstrap-aarch64.zip`

---

## 3. Repo layout

```
nexus/
├── README.md                          ← this file
├── scripts/fetch-runtime.sh           ← optional local bootstrap download
├── .github/workflows/android-debug.yml
├── core/native/android/src/main/kotlin/com/nexus/runtime/
│   ├── BootstrapManager.kt            ← zip extract, SYMLINKS.txt, Zip Slip checks
│   ├── ProotExecutor.kt               ← proot ProcessBuilder, timeout kill (no ProcessHandle)
│   ├── NexusRuntime.kt                ← facade + RW lock
│   ├── PackageManager.kt              ← validated pkg names + mutex
│   ├── ProjectMount.kt                ← projectId → bind mount args
│   ├── RuntimePlugin.kt               ← Flutter plugin
│   └── RuntimeLogger.kt
├── embedded-runtime/docs/             ← architecture + security notes
└── studio/                            ← Flutter application
    ├── pubspec.yaml                   ← versionName+versionCode
    ├── lib/
    │   ├── main.dart / app.dart
    │   ├── core/router/               ← go_router shell
    │   ├── features/projects/         ← CRUD + repository
    │   ├── features/workspace/        ← editor, run guard, ProjectRunner
    │   ├── features/runtime_debug/    ← Initialize / Install Python UI
    │   └── services/embedded_runtime.dart
    └── android/
        ├── app/build.gradle           ← SDK pins, signing, jni/assets sourceSets
        ├── keystore/debug.keystore    ← stable CI signing (not Play production)
        └── app/src/main/
            ├── AndroidManifest.xml
            ├── assets/bootstrap/      ← bootstrap zip (CI)
            └── jniLibs/arm64-v8a/     ← proot libs
```

---

## 4. Security model (short)

- Trusted local power-user tool, **not** a multi-tenant sandbox.  
- Zip Slip blocked via canonical path prefix checks.  
- Symlink targets validated relative to prefix.  
- Package names validated before shell.  
- Project mount only by id; host path built in Kotlin.  
- Details: `embedded-runtime/docs/security-notes.md`.

**Do not** use `Process.toHandle()` / `ProcessHandle` — missing from Android SDK stubs (`compileDebugKotlin` fails).

---

## 5. Build & CI

### Local

```bash
cd studio
flutter pub get
flutter build apk --debug
# app-debug.apk under build/app/outputs/flutter-apk/
```

Bootstrap must exist under assets (run `scripts/fetch-runtime.sh` with `TARGET_TAG=...` or copy zip manually).

### CI (GitHub Actions)

Workflow: `.github/workflows/android-debug.yml`

1. Checkout  
2. Java 17 + Android SDK  
3. Install **NDK 27.0.12077973** (pinned; NDK 28 side-by-side zip was failing on runners)  
4. Flutter stable  
5. Download Termux bootstrap + extract proot debs into jniLibs  
6. `flutter build apk --debug`  
7. Upload artifact **`nexus-apk`** → `app-debug.apk`

### Toolchain pins

| Item | Value |
|------|--------|
| AGP | 8.11.1 (see `settings.gradle`) |
| Kotlin | 2.3.20 |
| Gradle | 8.14 |
| NDK | **27.0.12077973** (explicit in `app/build.gradle`) |
| Java | 17 |
| AndroidX | `android.useAndroidX=true` |

### Signing / install

- Debug (and CI) APK signed with **repo** `studio/android/keystore/debug.keystore`.  
- Avoids “App not installed” when CI used ephemeral debug keys.  
- **Uninstall** any older Nexus Studio before installing a newly signed build.  
- Install **`app-debug.apk`** from the artifact zip — not the zip itself.

---

## 6. Device smoke checklist

1. Uninstall old `com.nexus.studio` if present.  
2. Install latest CI `app-debug.apk`.  
3. Runtime → **Initialize** (first extract can take ~30–90s).  
4. **Install Python** → wait for success.  
5. Open a project → edit `src/main.py` → **Run**.  
6. Expect stdout in run result / log.

---

## 7. Phase status

| Phase | Status |
|-------|--------|
| 0 Embedded runtime (Kotlin) | Done |
| 1 Studio shell | Done |
| 1.5 Code workspace + path safety | Done |
| 2 Project mount + runProject | Done (code) |
| 2b Run guard + Runtime UI | Done |
| CI APK with bootstrap | In progress (NDK pin + packaging) |
| Scene / Screen / 2D engine | Not started |
| Block editor | Not started |

---

## 8. Recommended next work (for any AI/dev)

1. Keep CI green; verify Initialize + Python + Run on **real arm64 phone**.  
2. Only then: scene JSON model + simple Flutter 2D loop (not proot GPU).  
3. Optional Settings: mild thermal/battery notice (non-blocking).  
4. More languages via `pkg install` after Python path is solid (clang, etc.).  
5. Never reintroduce `Process.toHandle()` on Android.

---

## 9. Common failures

| Symptom | Cause | Fix |
|---------|--------|-----|
| `Bootstrap asset not found` | zip not in APK assets | CI fetch step / local fetch-runtime.sh |
| `proot binary not found` | jniLibs missing | CI proot deb extract |
| `App not installed` | signature mismatch | uninstall old app; use repo keystore builds |
| CI `NDK ... ZipFile unknown archive` | bad NDK 28 download | pinned NDK 27 + sdkmanager preinstall |
| `Unresolved reference toHandle` | ProcessHandle API | use reflective pid + kill only |
| Run does nothing useful | Python not installed | Runtime → Install Python |

---

## 10. License / credit

Bootstrap/proot packaging inspired by Termux userspace layout.  
Nexus Studio + Embedded Runtime — project under active development.
