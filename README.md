# Nexus

**Mobile-first Hybrid Engine + Studio** with a fully **Embedded Linux Runtime** (Termux-style).

No external Termux app required. The Linux environment lives inside the Nexus app itself.

## Status

- **Phase 0** – Embedded runtime foundation
- **Phase 1 (in progress)** – Studio shell (projects, workspace, routing)

## Phase 0 Status: **Foundation Complete**

The core embedded runtime, Flutter bridge, project skeleton, and symlink-safe bootstrap extraction are in place.

### What works (once binaries are added)

- Bootstrap extraction using official Termux `SYMLINKS.txt` method (real symlinks)
- Zip-Slip protection
- `proot`-based command execution
- Flutter `MethodChannel` + progress `EventChannel`
- Package name validation / shell injection protection
- Basic test UI (`RuntimeTestScreen`)
- Minimal but real Flutter + Android project structure
- `MainActivity` registers `RuntimePlugin`

### Still needed to actually run on a device

1. **Bootstrap zip**
   ```bash
   bash scripts/fetch-runtime.sh aarch64
   ```
2. **proot + loader**  
   Copy from a working Termux install into:
   `studio/android/app/src/main/jniLibs/arm64-v8a/`

See `embedded-runtime/scripts/setup_notes.md` for details.

## Quick Start (after binaries)

```bash
cd studio
flutter pub get
# then run on device / emulator
```

In the app: tap **Initialize** → **Smoke Tests**.

## Repository Layout

```
nexus/
├── studio/                          # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   └── services/
│   │       ├── embedded_runtime.dart
│   │       └── runtime_example.dart
│   ├── android/                     # Gradle + MainActivity + assets/jniLibs
│   └── pubspec.yaml
├── core/native/android/.../runtime/ # Kotlin runtime (Bootstrap, Proot, Plugin...)
├── embedded-runtime/                # Docs + notes
└── scripts/fetch-runtime.sh         # Downloads official bootstrap
```

## Roadmap

- [x] Phase 0 – Embedded Runtime foundation
- [ ] Make it run on real device (binaries)
- [ ] Block Interpreter (basic)
- [ ] Scene / ECS
- [ ] Dual Mode (Game + App)
- [ ] Native acceleration later

## License

TBD
