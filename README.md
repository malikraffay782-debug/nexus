# Nexus

**Mobile-first Hybrid Engine + Studio** with a fully **embedded Linux runtime** (Termux-style, proot + bootstrap).

No separate Termux app. The Linux userspace lives inside the Nexus Android app private storage and is driven from Flutter via a MethodChannel.

---

## Vision

| Layer | Role |
|-------|------|
| **Nexus Studio** | Flutter UI — projects, editors, blocks, scene/screens |
| **Nexus Core** | Engine logic (Python first; later native pieces) |
| **Embedded Runtime** | Isolated Linux prefix via proot — packages, compilers, tools |

**Dual mode projects:**

- **Game** — Scene / Code / Assets
- **App** — Screens / Code / Assets

Users should eventually work with **blocks and/or real code** (Python, later C/C++/Rust toolchains inside the runtime).

---

## Current status

| Phase | Status | Notes |
|-------|--------|--------|
| **Phase 0 – Embedded Runtime** | Foundation done | Kotlin runtime + Flutter bridge + hardening |
| **Phase 1 – Studio shell** | In progress | Projects, workspace shell, routing, Run stub |
| **Device run** | Blocked on binaries | Need bootstrap zip + proot libs in APK |
| **Block interpreter / ECS** | Not started | Next major product work after device smoke |

---

## Repository layout

```
nexus/
├── README.md                          ← this file
├── scripts/
│   └── fetch-runtime.sh               # download Termux bootstrap (requires TARGET_TAG)
├── .github/workflows/
│   └── android-debug.yml              # CI: flutter build apk (working-dir: studio)
│
├── core/native/android/src/main/kotlin/com/nexus/runtime/
│   ├── BootstrapManager.kt            # extract bootstrap + SYMLINKS.txt
│   ├── ProotExecutor.kt               # run commands under proot
│   ├── NexusRuntime.kt                # singleton + RW lock
│   ├── PackageManager.kt              # pkg/apt wrapper (validated names)
│   ├── RuntimePlugin.kt               # MethodChannel + EventChannel
│   └── RuntimeLogger.kt
│
├── embedded-runtime/
│   ├── README.md
│   ├── docs/
│   │   ├── architecture.md
│   │   └── security-notes.md          # trust model (not a hardened sandbox)
│   └── scripts/setup_notes.md         # binaries + bootstrap manual steps
│
└── studio/                            # Flutter application
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart                  # ProviderScope + NexusApp
    │   ├── app.dart
    │   ├── core/
    │   │   ├── theme/app_theme.dart
    │   │   ├── router/app_router.dart # go_router shell + /workspace/:id
    │   │   └── shell/app_shell.dart   # bottom nav
    │   ├── features/
    │   │   ├── projects/              # domain, data, application, presentation
    │   │   ├── workspace/             # workspace UI + ProjectRunner
    │   │   ├── runtime_debug/         # hosts RuntimeTestScreen
    │   │   └── settings/
    │   └── services/
    │       ├── embedded_runtime.dart  # Flutter API to native runtime
    │       └── runtime_example.dart   # RuntimeTestScreen
    └── android/
        ├── app/src/main/kotlin/.../MainActivity.kt   # registers RuntimePlugin
        ├── app/src/main/assets/bootstrap/            # place bootstrap-*.zip here
        └── app/src/main/jniLibs/arm64-v8a/           # place libproot*.so here
```

Shared Kotlin sources are pulled into the Android app via `sourceSets` in  
`studio/android/app/build.gradle` → `../../../core/native/android/src/main/kotlin`.

---

## Architecture (runtime)

```
Flutter (EmbeddedRuntime / ProjectRunner)
    ↓ MethodChannel  com.nexus/runtime
    ↓ EventChannel   com.nexus/runtime/progress
RuntimePlugin (worker pool, destroyed flag)
    ↓
NexusRuntime (ReentrantReadWriteLock)
    ├── initialize()     → write lock → BootstrapManager
    ├── runCommand()     → read lock  → ProotExecutor
    └── packages.*       → read lock  → PackageManager → ProotExecutor
```

### Bootstrap

- Zip from assets: `bootstrap/bootstrap-<arch>.zip`
- Official Termux style: regular files extracted, then **`SYMLINKS.txt`** applied with `Os.symlink`
- Zip Slip blocked (canonical path under prefix)
- Symlink destination + resolved target must stay under prefix
- Concurrent init locked; failed extract deletes partial prefix
- Version file written with `Files.move` (ATOMIC_MOVE when possible)

### Execution

- `proot -0 -r $PREFIX ... /bin/sh -c <command>`
- Output drained fully (cap stored size; avoids pipe deadlock)
- UTF-8 via `InputStreamReader`
- Timeout: kill descendants + pid; close streams; reader executor `shutdownNow`
- `workingDir` normalized; host paths / `..` rejected

### Trust model (important)

This is a **developer power tool**, not a multi-tenant sandbox.

- Callers of `runCommand` are treated as **trusted**
- Arbitrary shell is intentional for Studio for now
- `/dev`, `/proc`, `/sys` bound for Termux-like usability
- See `embedded-runtime/docs/security-notes.md`

---

## Studio shell (Phase 1)

| Screen | Route | Role |
|--------|-------|------|
| Projects | `/projects` | List / open / delete |
| Create | `/create` | Name + Game/App type |
| Runtime debug | `/runtime` | `RuntimeTestScreen` (init + smoke tests) |
| Settings | `/settings` | Theme, projects path |
| Workspace | `/workspace/:id` | Scene/Screens · Code · Assets placeholders + **Run** |

**Projects on disk:**

```
<app_documents>/projects/<id>/
  project.json
  src/
  assets/
  scenes/    # game
  screens/   # app
```

**Runtime touch point for product UI:** only  
`studio/lib/features/workspace/application/project_runner.dart`  
(plus the debug screen). Do not scatter `EmbeddedRuntime` calls everywhere.

### Flutter dependencies (`studio/pubspec.yaml`)

- `flutter_riverpod`
- `go_router`
- `path_provider`
- `path`

---

## Flutter ↔ Native API

**Channel:** `com.nexus/runtime`  
**Progress:** `com.nexus/runtime/progress`

| Method | Purpose |
|--------|---------|
| `initialize` | Extract/ensure bootstrap (progress events) |
| `isReady` | Quick ready flag |
| `runCommand` | `{command, workingDir?, timeoutSec?}` → exitCode/stdout/stderr/timedOut |
| `pythonVersion` / `hasBinary` | Helpers |
| `installPackage` / `updatePackages` | Thin pkg/apt wrappers |

Dart entry: `studio/lib/services/embedded_runtime.dart`.

---

## How to run (developers)

### 1. Binaries (required for real runtime)

```bash
# From repo root — pin a release tag (required)
TARGET_TAG=... bash scripts/fetch-runtime.sh aarch64
# Optional: EXPECTED_SHA256=... TARGET_TAG=... bash scripts/fetch-runtime.sh aarch64
```

Place proot libs (from a working Termux install) into:

```
studio/android/app/src/main/jniLibs/arm64-v8a/
  libproot.so          # or proot
  libproot-loader.so
```

Details: `embedded-runtime/scripts/setup_notes.md`.

### 2. Flutter

```bash
cd studio
flutter pub get
flutter run
```

### 3. In the app

1. **Runtime** tab → **Initialize** → **Smoke Tests**
2. **Create** a project → open workspace → **Run** (echo stub via runtime)

### 4. CI

Push to `main` or `workflow_dispatch`: builds debug APK from `studio/`.

---

## Hardening already applied (Phase 0)

- Zip Slip + symlink path validation  
- Bootstrap init lock + partial cleanup  
- Init vs command **ReadWriteLock** (package ops under same read lock)  
- Shell package-name allowlist + quoting  
- Output size cap + full pipe drain  
- Worker **AbortPolicy** (no work on Flutter platform thread)  
- Plugin `destroyed` flag (no result after detach)  
- `fetch-runtime.sh` requires `TARGET_TAG` (optional SHA256)

---

## Known gaps / next work

1. **Ship-blocking:** real bootstrap zip + proot on device; end-to-end smoke  
2. **Bootstrap integrity:** pin SHA256 in docs/CI for release builds  
3. **Studio:** code editor, file tree, real Run of project `src/`  
4. **Blocks:** block editor + codegen to Python  
5. **Game/App:** scene/screen models beyond placeholders  
6. **Optional later:** command allowlist for non-dev builds; stronger process isolation  

---

## Conventions for future contributors / agents

1. **Do not rewrite** `ProotExecutor` / `BootstrapManager` unless fixing a proven bug — they were heavily audited.  
2. New product features go under `studio/lib/features/...`.  
3. Talk to the runtime only through `EmbeddedRuntime` or `ProjectRunner`.  
4. Prefer small PRs: UI vs runtime changes separated when possible.  
5. Android native shared code lives in `core/native/android/...`, not duplicated under `studio/android` except `MainActivity` / Gradle / manifests.  

---

## License

TBD
