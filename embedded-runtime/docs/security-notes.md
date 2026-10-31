# Security / Trust Model (Phase 0)

This runtime is **not** a hardened sandbox for untrusted code.

## Current trust assumptions

- The Flutter / app layer that calls `runCommand` / `installPackages` is **trusted**.
- Bootstrap zip comes from the app assets (or from `scripts/fetch-runtime.sh`).
- proot binds `/dev`, `/proc`, `/sys` for usability (same model as Termux).

## What is protected

- Zip Slip on extraction
- Symlink destination + resolved target must stay inside prefix
- Package names and `hasBinary` names are allowlisted / quoted
- Output size is capped
- Bootstrap init is locked against concurrent races
- Timeout tries to kill process tree (best-effort)

## What is intentionally open (for now)

- Arbitrary shell commands via `runCommand` (Studio needs this)
- Network package installs via pkg/apt
- No cryptographic verification of bootstrap yet
- PATH still includes prefix + limited native lib dir for proot loader

## Planned hardening (later phases)

1. Optional command allowlist / capability model for non-dev builds
2. Bootstrap SHA-256 pin in `fetch-runtime.sh` + verify before extract
3. Stricter mount set (drop or fake more of /proc /sys if needed)
4. Stronger process-group isolation
5. Runtime teardown / reset API

Until those land, treat this as a **developer power tool**, not a multi-tenant sandbox.
