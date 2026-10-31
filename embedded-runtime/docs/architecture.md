# Embedded Runtime Architecture

## Why we embed instead of depending on Termux app

- Zero external dependency for end users
- Full control over packages and updates
- Can ship custom tools later
- Better integration with Studio (progress, logs, lifecycle)

## Execution Flow

1. App starts → `NexusRuntime.initialize()`
2. `BootstrapManager` checks version file
3. If missing/outdated → extract architecture-specific bootstrap zip from assets
4. proot + loader are loaded from `nativeLibraryDir` (required for W^X)
5. Commands are executed via `ProotExecutor` using fake-root proot
6. stdout/stderr returned to Flutter via MethodChannel

## Key Design Decisions

- **PREFIX** lives under app private storage (`files/nexus-runtime/prefix`)
- We currently bind `/dev`, `/proc`, `/sys` and our own tmp/home
- Loader **must** be in the APK's native library directory
- Bootstrap version is tracked so we can force re-extract on updates

## Future Improvements

- Progressive download of bootstrap (instead of shipping full zip in APK)
- Own minimal bootstrap (smaller than full Termux)
- Proper package manager wrapper on top of apt/pkg
- Support for multiple concurrent sessions
- Background process supervision