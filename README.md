# Nexus

**Mobile-first Hybrid Engine + Studio** with a fully **Embedded Linux Runtime** (Termux-style).

No external Termux app required. The Linux environment lives inside the Nexus app itself.

> Phase 0 – Foundation (Embedded Runtime) is in progress.

## Vision

- **Nexus Studio** → Flutter app (Block Editor, Code Editor, Scene View, Project Manager, Language Installer)
- **Nexus Core** → Engine (Python first, later C++/Rust native parts)
- **Embedded Runtime** → Full Linux userspace inside the app (proot + bootstrap)

Supports both:
- **Game Mode** (Scene, Physics, Sprites, Input)
- **App Mode** (UI Components, Screens, Storage, Network)

Users can work with Blocks **or** write real code (Python, C, C++, Rust).

## Current Status (Phase 0)

### Done
- Project structure (pubspec, Gradle, MainActivity, plugin registration)
- `BootstrapManager` – official Termux SYMLINKS.txt handling (real symlinks)
- Zip Slip protection + safe isReady
- `ProotExecutor` – command execution inside isolated env
- `NexusRuntime` + PackageManager (injection-safe)
- Flutter MethodChannel + EventChannel progress bridge
- Robust Dart error/timeout handling
- Basic test UI (`RuntimeTestScreen`)

### Still Required (Manual)
- Actual `proot` + `proot-loader` binaries in `jniLibs/arm64-v8a/`
- Bootstrap zip(s) in `android/app/src/main/assets/bootstrap/`
- See `embedded-runtime/scripts/setup_notes.md`

## Quick Start (after binaries are added)

```dart
final init = await EmbeddedRuntime.initialize();
if (init.success) {
  print(await EmbeddedRuntime.pythonVersion());
  print(await EmbeddedRuntime.exec("uname -a"));
}
```

## Repository Structure

```
nexus/
├── studio/                     # Flutter app
│   └── lib/services/
│       ├── embedded_runtime.dart
│       └── runtime_example.dart
├── core/native/android/        # Kotlin + future JNI
│   └── src/main/kotlin/com/nexus/runtime/
│       ├── BootstrapManager.kt
│       ├── ProotExecutor.kt
│       ├── NexusRuntime.kt
│       └── RuntimePlugin.kt
├── embedded-runtime/
│   ├── README.md
│   └── scripts/setup_notes.md
└── README.md
```

## Roadmap

- [x] Phase 0 foundation code
- [ ] Make bootstrap + proot actually run on device
- [ ] Python working reliably
- [ ] Simple package install support
- [ ] Block Interpreter (basic)
- [ ] Scene / ECS
- [ ] Dual Mode (Game + App)
- [ ] Native acceleration (physics/renderer)

## License

TBD (will be decided later)

---

Built for people who want real power on mobile, not toy sandboxes.