# Nexus Embedded Linux Runtime (Phase 0)

This is the heart of Nexus Core.

We embed a full Linux userspace (Termux-style) inside the Android app using:

- Official Termux bootstrap (or our minimal fork later)
- proot + proot-loader
- Controlled $PREFIX inside app private storage

## Goals for Phase 0

- [x] Folder structure
- [ ] Bootstrap extraction on first run
- [ ] proot-based command execution
- [ ] Python 3 working
- [ ] Flutter ↔ Native bridge
- [ ] Basic package install support

## Storage Layout (Runtime)

```
/data/data/<package_name>/files/nexus-runtime/
├── prefix/               # $PREFIX (bin, lib, etc.)
├── tmp/
├── home/
└── version
```

## Architecture

```
Flutter (EmbeddedRuntime service)
        │ MethodChannel
        ▼
RuntimePlugin (Kotlin)
        │
        ├── BootstrapManager
        ├── ProotExecutor
        └── Environment
                │
                ▼
         proot + bootstrap
```

## Important Notes

- proot-loader **must** live in nativeLibraryDir (W^X bypass)
- We start with aarch64 focus
- Later we will support on-demand package download + custom packages