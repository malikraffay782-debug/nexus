# Nexus

**Mobile-first Hybrid Engine + Studio** with a fully **embedded Linux runtime** (Termux-style: proot + bootstrap).

No separate Termux app. Linux userspace lives inside the Nexus Android app private storage and is driven from Flutter via MethodChannel.

**Repo:** https://github.com/malikraffay782-debug/nexus

---

## Vision (target level)

Nexus is **not** a thin code notepad. The intended product level is closer to a **mobile Unity/Roblox-style studio**, built in phases:

| Layer | Role |
|-------|------|
| **Nexus Studio** | Flutter UI — projects, code editor, later blocks / scene / screens |
| **Nexus Core** | Game/app logic (Python first; later toolchains inside the runtime) |
| **Embedded Runtime** | Isolated Linux prefix via proot — packages, Python, compilers |

**Project types**

- **Game** — Scene / Code / Assets (scene editor + 2D runtime later)
- **App** — Screens / Code / Assets

**Important architecture rule**

- **Embedded Linux** = tools, scripts, packages, build helpers  
- **Game rendering / frame loop** = Flutter/Android side (not GPU inside proot)  
- proot is a **developer power tool**, not a multi-tenant security sandbox  

---

## Current status (honest)

| Area | Status | Notes |
|------|--------|--------|
| **Phase 0 – Embedded Runtime** | Done (code) | Bootstrap, proot, locks, hardening, package mgr |
| **Phase 1 – Studio shell** | Done | Projects CRUD, routing, workspace shell |
| **Phase 1.5 – Code workspace** | Done | File tree + editor + path safety |
| **Phase 2 – Real project Run** | Done (code) | Mount `projects/<id>` → `/home/project`, run `src/main.py` |
| **Phase 2b – Run guard + Runtime UI** | Done | Unsaved-changes dialog; Runtime debug screen |
| **CI debug APK** | **Green** | `flutter build apk --debug` succeeds |
| **Device functional runtime** | **Blocked on binaries** | Need bootstrap zip + `libproot*.so` in APK |
| **Scene / Screen / Assets editors** | Placeholders | Not implemented |
| **2D engine / Flame / blocks** | Not started | After device smoke |

### Latest successful CI APK

- Workflow: [Build Android APK](https://github.com/malikraffay782-debug/nexus/actions/workflows/android-debug.yml)
- Example green run: commit `917ba86` (Kotlin `ProcessHandle` compile fix)
- Artifact name: **`nexus-apk`** → contains `app-debug.apk`
- Download: GitHub → Actions → latest **success** run → Artifacts → `nexus-apk`

> This APK is the **Studio shell + native bridge**. Without packaging bootstrap + proot libs, **Initialize / Python / Run** will not fully work on device.

---

## What works in code today

### Embedded runtime (Kotlin)

- `BootstrapManager` — zip extract, Zip Slip checks, `SYMLINKS.txt` (stream-safe), version file  
- `ProotExecutor` — proot argv, output cap, timeout kill (**no `Process.toHandle`** — Android SDK safe)  
- `NexusRuntime` — RW lock between init and commands  
- `PackageManager` — validated package names + mutation mutex  
- `ProjectMount` — only `projectId` from Flutter; host path resolved in Kotlin  
- `RuntimePlugin` — MethodChannel `com.nexus/runtime`, progress EventChannel  

### Studio (Flutter)

- Projects: create / list / delete under app documents `projects/<id>/`  
- Workspace: Code tab (tree + editor), Run button  
- Run guard: Save and Run / Run without saving / Cancel  
- `ProjectRunner` → `EmbeddedRuntime.runProject(projectId)`  
- Runtime tab: Initialize, Install Python, status, log  

### Security posture (documented)

See `embedded-runtime/docs/security-notes.md`.

- Trusted local power-user tool  
- Path validation on project mounts and workspace files  
- Not an untrusted-code jail  

---

## Repository layout

```
nexus/
├── README.md
├── scripts/fetch-runtime.sh          # download Termux bootstrap (TARGET_TAG)
├── .github/workflows/android-debug.yml
├── core/native/android/.../com/nexus/runtime/
│   ├── BootstrapManager.kt
│   ├── ProotExecutor.kt
│   ├── NexusRuntime.kt
│   ├── PackageManager.kt
│   ├── ProjectMount.kt
│   ├── RuntimePlugin.kt
│   └── RuntimeLogger.kt
├── embedded-runtime/docs/
│   ├── architecture.md
│   ├── security-notes.md
│   └── project-mount.md
└── studio/                           # Flutter app
    ├── lib/features/projects/
    ├── lib/features/workspace/       # files, editor, run guard, runner
    ├── lib/features/runtime_debug/   # RuntimeDebugScreen + facade
    ├── lib/services/embedded_runtime.dart
    └── android/                      # MainActivity registers RuntimePlugin
```

---

## Build APK (CI or local)

### CI

```bash
# push to main triggers workflow, or run workflow_dispatch
# Artifact: nexus-apk / app-debug.apk
```

### Local

```bash
cd studio
flutter pub get
flutter build apk --debug
# output: build/app/outputs/flutter-apk/app-debug.apk
```

### Android toolchain pins (see `studio/android/`)

- AGP **8.11.1**
- Kotlin **2.3.20**
- Gradle **8.14**
- `android.useAndroidX=true`
- Java **17**

---

## Device / Termux-level runtime setup (required for real Initialize)

Binaries are **not** in git (`.gitignore`).

1. **Bootstrap zip** (per ABI), into app assets, e.g.  
   `studio/android/app/src/main/assets/bootstrap/bootstrap-aarch64.zip`  
   Script: `TARGET_TAG=<termux-package-release> bash scripts/fetch-runtime.sh aarch64`

2. **proot libs** into jniLibs, e.g.  
   `studio/android/app/src/main/jniLibs/arm64-v8a/libproot.so`  
   `libproot-loader.so`

3. Install APK → **Runtime** tab → **Initialize** → **Install Python** → open project → **Run**

Expected after full packaging: `src/main.py` prints under proot with cwd `/home/project`.

Path contract:

- Flutter: `getApplicationDocumentsDirectory()/projects/<id>`  
- Kotlin: `context.getDir("flutter", MODE_PRIVATE)/projects/<id>`  
  (same directory on Android)

---

## Flutter bridge API (summary)

`studio/lib/services/embedded_runtime.dart`

| Method | Purpose |
|--------|---------|
| `initialize()` | Extract/bootstrap runtime |
| `isReady()` | Bootstrap present |
| `runCommand(cmd)` | Trusted shell command in proot |
| `runProject(projectId)` | Bind project + `python3 /home/project/src/main.py` |
| `installPackages([...])` | pkg/apt install |
| `pythonVersion()` | Version string |
| `progressStream` | Bootstrap progress |

---

## Recommended next work order

1. Package **bootstrap + proot** into a debug APK and smoke on a real phone  
2. Confirm Initialize → Install Python → Run `main.py`  
3. Only then: scene JSON / 2D runtime design (Flutter-side loop, not proot GPU)  
4. Blocks editor last (depends on editor + run + scene contracts)

---

## Known gaps

- No bootstrap/proot in default CI APK  
- Scene / Screen / Asset editors are placeholders  
- No cancel-token API for long native jobs (Dart timeout ≠ process kill registry)  
- Corrupt projects are skipped in list (no quarantine UI yet)  
- Single-ABI packaging notes still need hardening for non-arm64  

---

## License / credit

Bootstrap/proot approach inspired by Termux-style userspace embedding.  
Project: Nexus Studio + Embedded Runtime.
