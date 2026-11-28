# Nexus

**Mobile game + code studio** on device: Flutter Studio UI, embedded Linux (proot) for Python/tools, and a **3D-oriented scene foundation** you fill yourself.

- **Repo:** https://github.com/malikraffay782-debug/nexus  
- **Bug hunt:** see **§11** (open bug list, severity + suggested fix order)  
- **Package ID:** `com.nexus.studio`  
- **Min SDK 26 · Target 34 · Compile 35** · primary ABI `arm64-v8a`

This README is for **humans and agents** continuing the project. Prefer small steps; do not treat the 3D stack as “done.”

---

## 1. Product goal

Ship a practical **on-device studio** toward Unity-class capability **step by step**, with main focus on **3D**:

1. Stable Python run + project files + workspace  
2. Installable languages/packages on demand  
3. Strong camera / transform / scene foundation  
4. Real 3D loop + nodes that matter  
5. In-app run; later export/package flows  
6. Flexible workspace (folders, notes) with sandbox allow-lists  

**2D is secondary** — only when it supports the 3D path or stability.

### Stage philosophy (important)

New game scenes start as a **dark empty void**:

- No ground plane, no default level geometry, no forced 3D props  
- Grid **off** by default (user can toggle)  
- **You** add sprites, cameras, meshes, assets as the game needs  

NDC / soft projection, frustum cull, and matrices are **tools in the studio**, not a pre-built world.

---

## 2. Architecture

| Layer | Role |
|-------|------|
| **Flutter Studio** | Projects, editor, Scene / Code / Assets, play preview |
| **MethodChannel** `com.nexus/runtime` | Initialize runtime, run project, packages |
| **Kotlin + proot** | Bootstrap, Python, mount `projects/<id>` → `/home/project` |
| **Scene (Dart)** | Scene JSON, nodes, soft/NDC project, play sample loop |
| **Run (Python)** | `src/main.py` + `scene_draw.py` (ASCII / foundation) |

**Rule:** frame loop and scene chrome stay on **Flutter**. proot is for **code and tools**, not GPU Linux rendering.

### Paths

| Side | Path |
|------|------|
| Projects (Flutter) | app documents `/projects` |
| Guest mount | `/home/project` |
| Entry run | `python3 src/main.py` |

---

## 3. Repo layout (where things live)

```
nexus/
├── README.md
├── .github/workflows/build-debug-apk.yml   ← APK: workflow_dispatch ONLY
├── core/native/…                          ← Kotlin runtime / proot / bootstrap
├── studio/                                ← Flutter app
│   ├── android/                           ← Manifest, MainActivity, native libs
│   └── lib/
│       ├── main.dart / app.dart
│       ├── core/                          ← router, theme, shell
│       ├── services/                      ← embedded_runtime bridge
│       └── features/
│           ├── projects/                  ← list / create / project model
│           ├── runtime_debug/             ← Initialize, Install Python, debug
│           ├── settings/
│           └── workspace/
│               ├── presentation/
│               │   └── workspace_screen.dart   ← tabs + Run button + run panel host
│               ├── scene/
│               │   ├── scene_model.dart        ← SceneDoc, SceneNode, types
│               │   ├── scene_project.dart      ← soft / NDC projection
│               │   ├── scene_renderer.dart
│               │   └── scene_service.dart      ← load/save scene JSON
│               ├── files/
│               │   ├── workspace_paths.dart    ← sandbox allow-list (keep safe)
│               │   ├── workspace_files_*.dart
│               │   └── …
│               ├── run/
│               │   ├── run_session.dart
│               │   ├── run_session_controller.dart
│               │   └── run_gateway.dart
│               └── widgets/
│                   ├── workspace_scene_tab.dart  ← scene UI, play, phone docks
│                   ├── workspace_code_tab.dart
│                   ├── run_output_panel.dart     ← adaptive run console
│                   ├── run_guard.dart            ← unsaved-changes before Run
│                   ├── code_editor_panel.dart
│                   └── file_tree_panel.dart
└── scripts/
```

**Quick map for common work**

| Task | Primary files |
|------|----------------|
| Run panel / landscape height | `widgets/run_output_panel.dart`, `presentation/workspace_screen.dart` |
| Scene editor / play / inspector | `widgets/workspace_scene_tab.dart` |
| Projection / camera matrices | `scene/scene_project.dart`, `scene/scene_model.dart` |
| Path sandbox | `files/workspace_paths.dart` (`topDirs` + `rootFiles`) |
| File tree / root notes | `widgets/file_tree_panel.dart`, `files/workspace_file_service.dart` |
| proot / Python bootstrap | `core/native/…`, `runtime_debug/` |
| Unsaved guard before Run | `widgets/run_guard.dart` |
| Run session / panel close | `run/run_session_controller.dart` (`clear` vs `detach`) |

---

## 4. Scene / 3D foundation (current, partial)

| Piece | Status | Covered by tests? |
|-------|--------|-------------------|
| Scene JSON + nodes (sprite/camera, z, zDepth, fov, near, far) | Yes | Yes (`scene_model_test`) |
| Soft projection (default, low-end) | Yes | Yes (`scene_project_test` + golden) |
| NDC look **+Z** perspective (`w=+depth`) + lateral cull | Yes | Yes (sign + frustum + golden) |
| NDC size scale from 1/depth (not soft mix) | Yes | Yes |
| Camera rx/ry/rz orient NDC view matrix | Yes | Partial (rotated frustum test) |
| Node rotation rx/ry/rz on stage + handles | Yes | UI only (no widget test) |
| AABB frustum (flat + zDepth) | Yes | Yes |
| **ScenePlayState** real dt + steer XY+Z; draw sort by depth | Yes | Yes (`scene_play_state_test`) |
| Stick release does **not** snap Player back | Yes | Yes |
| Camera follows Player **runtime** center in play | Yes | Code path; on-device visual TBD |
| Mesh ids + wireframe + projected box/planar (crate/sword/chest) | Yes | Yes (`scene_mesh_wire_test`, `projectForWire`) |
| `scene_draw.py` asset + preferred camera | Yes | Python golden on CI |
| Full Unity camera / GPU mesh / animation | **No** | — |
| Auto ground / default level | **No** (by design) | — |

Play modes: **Soft** (default) or **NDC**. New cameras default to `z=-240` so sprites at `z≈0` sit in front of near. Shared Dart↔Python transform is **partial** (visibility golden), not full matrix parity for every rotation.

---

## 5. UI stability (landscape / short height)

Implemented so daily use on phones in landscape does not bury the stage or code editor.

| Area | Behavior | File |
|------|----------|------|
| **Run output panel** | Height from available space (keyboard-aware): ~110 / 140 / 170 / 200. Compact header when short. | `widgets/run_output_panel.dart` → `heightFor()` |
| **Code tab Files sheet** | On short/landscape height, sheet height is capped instead of always 70% of screen. | `widgets/workspace_code_tab.dart` |
| **Scene phone inspector** | ~120–158 px depending on screen height. | `widgets/workspace_scene_tab.dart` → `_phoneInspector` |
| **Scene points pad** | ~180–320 px depending on screen height. | `widgets/workspace_scene_tab.dart` → `_pointsControlPad` |
| **Scene wide layout** | Side-by-side sidebar only if width ≥ 560 **and** height ≥ 300; else stacked phone layout. | `widgets/workspace_scene_tab.dart` build |
| **Zero-size scene guard** | `doc.width/height <= 0` → safe aspect; no NaN scale | `widgets/workspace_scene_tab.dart` → `_buildCanvas` |
| **Play ticker race** | Dispose old ticker before start; tick ignores if not playing | `widgets/workspace_scene_tab.dart` → `_togglePlay` |

AndroidManifest already allows orientation changes (`configChanges` includes orientation/screenSize). App does **not** lock to portrait.

---

## 5b. Workspace paths & flexibility

Sandbox stays closed; allow-lists grow **deliberately**.

| Rule | Detail |
|------|--------|
| **Top folders** | `src`, `assets`, `scenes`, `screens`, `notes` only |
| **Nested folders** | Allowed under those tops, max depth **8** (list + resolve) |
| **Root files** | Only `README.md` and `NOTES.md` at project root (not arbitrary root listing) |
| **Rejected** | `..`, absolute paths, empty segments (`a//b`), trailing `/`, symlinks, names with bad chars |
| **UI** | Files panel → note icon → “Add README.md / NOTES.md” when missing |

Primary code: `files/workspace_paths.dart`, `files/workspace_file_service.dart`, `widgets/file_tree_panel.dart`.

---

## 6. Build & APK (compute-safe)

**APK CI does not run on every push.**  
Workflow: `.github/workflows/build-debug-apk.yml` → **`workflow_dispatch` only**.

- Code push → no APK  
- APK only when someone **explicitly** runs the workflow (or asks for “APK ready”)

**Light CI on push** (studio paths): `.github/workflows/flutter-check.yml`  
→ `flutter analyze` + `flutter test` only (no APK).

Local:

```bash
cd studio
flutter pub get
flutter test
flutter analyze
flutter build apk --debug
```

Bootstrap asset must exist for runtime Initialize (CI downloads it for workflow builds).

### Unit tests

| File | Covers |
|------|--------|
| `studio/test/scene_project_test.dart` | Soft/NDC project, frustum, AABB, perspective scale |
| `studio/test/scene_model_test.dart` | Node/doc JSON round-trip, degrees, foreshorten, mesh |
| `studio/test/scene_play_state_test.dart` | Real dt move, release no-snap, bounds, dt clamp |
| `studio/test/workspace_paths_test.dart` | Sandbox reject/allow path cases |
| `studio/test/projection_golden_test.dart` + `test/python/` | Shared visibility golden |

### Scene tab structure

| File | Role |
|------|------|
| `widgets/workspace_scene_tab.dart` | Scene tab orchestration + canvas/handles (~1.8k lines) |
| `widgets/play_touch_stick.dart` | Play-mode virtual stick |
| `widgets/scene_phone_inspector.dart` | Phone inspector + RX/RY/RZ steps |
| `widgets/scene_points_pad.dart` | Points edit dock (swipe pad) |
| `widgets/scene_node_list.dart` | Desktop node list + reorder |
| `widgets/scene_node_chrome.dart` | Edit handles (resize/rotate/points) |
| `scene/scene_play_controller.dart` | Play ticker, steer, Soft/NDC mode |
| `scene/scene_play_state.dart` | Runtime Player pose/velocity (no JSON write) |

---

## 7. Device smoke

1. Install debug APK (uninstall older signed builds if needed).  
2. Runtime → Initialize → Install Python.  
3. Create **Game** project → Scene is a **dark void**.  
4. Add sprite/camera; rename a sprite to `Player` → Play → stick / WASD.  
5. Run → `src/main.py` in proot.  
6. **Landscape check:** rotate phone — Run panel and scene docks should shrink; stage/editor stay usable.

---

## 8. Working rules (stable)

1. One concrete step at a time unless asked otherwise.  
2. Small commits; push when asked. **No APK** unless explicitly requested.  
3. proot ≠ Flutter scene loop — don’t collapse the boundary.  
4. Keep workspace path sandboxing when adding folders (`workspace_paths.dart`).  
5. Prefer fixing blockers on the 3D path and daily usability.  
6. Core camera/render is **not** complete — don’t document it as finished.

---

## 9. Suggested next steps (priority order)

1. **Finish scene-tab split** — canvas + gesture handles still in `workspace_scene_tab.dart` (~1.8k lines)  
2. **Deeper Dart↔Python golden** — full soft/NDC numeric vectors, not only visibility  
3. **Stick dead-zone + feel polish** on low-end (dt path already real)  
4. ~~**Assets** pipeline~~ **DONE** (sprite path + 256KB/512px cache)
5. Optional languages on demand / real mesh loader later  

---

## 10. License / intent

Built to become a serious open or productized mobile studio. Keep the stage empty and dark so **large games are user-built**, not template-filled.

---

## 11. Bug hunt report — 2026-11-24 (static review, nothing fixed yet)

**Scope / method.** Read-only code review of commit `4dac66a` (`refactor(scene): extract SceneNodeChrome`),
done in Termux. Files reviewed: `workspace_paths.dart`, `workspace_file_service.dart`, `workspace_files_controller.dart`,
`code_text_controller.dart`, `run_session*.dart`, `run_gateway.dart`, `run_guard.dart`, `run_output_panel.dart`,
`workspace_screen.dart` (run part), `scene_project.dart`, `scene_play_state.dart`, `scene_play_controller.dart`,
`scene_service.dart`, `scene_renderer.dart` (allocation scan only), `ProotExecutor.kt`, `ProjectMount.kt`, `NexusRuntime.kt`,
`RuntimePlugin.kt`, manifest / gradle / CI / `.gitignore`.
**Not done:** no `flutter analyze` / `flutter test` / device run (heavy work stays in GitHub Actions). Not reviewed:
`workspace_scene_tab.dart` (1.8k lines), `scene_model.dart`, `BootstrapManager.kt`, `PackageManager.kt`, installers.
Items marked *(verify)* need a device check.
**Status of every item below: OPEN** (no code was changed in this step).

Severity: **H** = blocks stability / 3D / 2 GB phones, **M** = real bug or clear perf risk, **L** = small / hygiene.

### 11.1 Stability — run / stop (priority A)

| ID | Sev | Where | Problem | Suggested fix |
|----|-----|-------|---------|---------------|
| B1 | H | `RuntimePlugin.kt` / `ProotExecutor` | FIXED — stopRun on dedicated `nexus-stop` daemon thread; kill waits cut to ~400ms+300ms (was ~4s). | — |
| B2 | H | `ProotExecutor.spawnOnce` / `run_session_controller` | FIXED — stop always latches; spawn checks pre/post-start race; Dart forces cancelled if native reports idle while still stopping. | — |
| B3 | H (2 GB) | `ProotExecutor.MAX_OUTPUT_CHARS` | FIXED — capped at 200_000 chars to match Dart `kMaxOutputChars` (was 2 MB per stream). | — |
| B14 | M | RuntimePlugin executors | FIXED — longExecutor for install/run; short pool for probes. | — |
| B24 | L | run_session_controller | FIXED — _launching cleared only by owning generation. | — |
| B27 | L | RuntimePlugin.onWorker | FIXED — always reply NATIVE_DETACHED if destroyed after work. | — |
| B23 | L | timeouts | FIXED — ProotExecutor MAX_TIMEOUT_SEC 3600→120 (matches clamps). | — |
| B22 | L | project_runner.dart | FIXED — dead code deleted. | — |

### 11.2 3D foundation (priority C / D)

| ID | Sev | Where | Problem | Suggested fix |
|----|-----|-------|---------|---------------|
| B4 | H | `scene_project.dart` `toNdc()` | FIXED — near/far uses clip w (view-space depth), not world `z - cz`. Rotated cameras correct. | — |
| B5 | H | `scene_project.dart` `aabbVisible()` | FIXED — NDC path uses 6-plane clip test on corners (large covering AABB no longer false-culled). | — |
| B7 | M | `SceneProject.perspectiveScale` | FIXED — scale tracks vertical FOV (`f/f60 * softRef/depth`); FOV 60 keeps legacy feel. | — |
| B8 | M | `scene_play_state.dart` `update()` | FIXED — clamp uses real player `w/h` from node, not hard-coded 64×64. | — |
| B9 | M | `scene_play_state.dart` `update()` | FIXED — dead-zone reshape; partial stick = slower speed. | — |
| B10 | M | `scene_play_controller.dart` | FIXED — clear keys on focus loss so steer does not stick. | — |
| B25 | gap | `ScenePlayState` | **Partial** — Player Z via Q/E + worldZ in play paint/projected mesh. Mesh GPU still later. | — |
| B26 | L | cull box / rotation | FIXED — rotated nodes use diagonal-inflated AABB for cull. | — |

### 11.3 Data safety & files (priority B)

| ID | Sev | Where | Problem | Suggested fix |
|----|-----|-------|---------|---------------|
| B6 | H (2 GB) | `scene_service.dart` `save()` / `create()` | FIXED — temp + rename atomic write (same pattern as WorkspaceFileService). | — |
| B20 | L | writeText / listTree | FIXED — hide *.nexus_tmp; unique tmp names. | — |
| B18 | L | workspace_paths | FIXED — symlink check uses unresolved _rawRoot. | — |
| B19 | L | validateName / safeWorkingDir | FIXED — only exact `.` / `..` segments rejected. | — |
| B21 | L | listTree | FIXED — truncation marker row when entry cap hit. | — |
| B28 | L | scene_service.load | FIXED — 2 MB size cap on scene JSON read. | — |

### 11.4 Low-end (2 GB) performance

| ID | Sev | Where | Problem | Suggested fix |
|----|-----|-------|---------|---------------|
| B11 | M | renderer / code highlight | FIXED — reused bg/grid Paint; CodeTextController caches spans per text. | — |
| B12 | M | maxEditableBytes | FIXED — 1 MB → 256 KB for 2 GB phones. | — |
| B13 | M | run_output_panel | FIXED — panel shows last 32k chars; Copy keeps full body. | — |
| B16 | M | AndroidManifest | FIXED — allowBackup=false. | — |
| B29 | L | jniLibs | FIXED — removed unused libtalloc.so + libandroid-shmem.so (static proot). | — |

### 11.5 Repo / CI hygiene

| ID | Sev | Where | Problem | Suggested fix |
|----|-----|-------|---------|---------------|
| B15 | M | .gitignore | FIXED — secrets/ and __pycache__ on separate lines. | — |
| B17 | info | `studio/android/keystore/debug.keystore` | Debug keystore is committed on purpose (stable CI installs). Fine for debug, **never** use it for release / Play Store. Keep this repo private. | — |

### 11.6 Checked and OK (no action)

- `SceneMat4.perspective()` math for look **+Z** is correct (near → −1, far → +1, `w = +depth`).
- `ProjectMount.resolve()` validation (id regex, canonical parent check, symlink rejects, entry check) is solid.
- `ProotExecutor.drainCapped` keeps draining after the cap, so a chatty child cannot block on a full pipe.
- `confirmRunWithUnsavedChanges` correctly handles an in-flight save (re-checks `dirty` after `save()`).
- `WorkspacePaths` allow-list (`topDirs`, `rootFiles`, depth 8, segment rules) is intact — nothing was widened.

### 11.7 Suggested fix order (one step per turn)

1. ~~**B1 + B2** — Stop path~~ **DONE** (this commit).
2. ~~**B3** — match Kotlin output cap to Dart~~ **DONE**.
3. ~~**B6** — atomic scene save~~ **DONE**.
4. ~~**B4 + B5** — NDC culling correctness~~ **DONE**.
5. **B15** — `.gitignore` newline fix (tiny; do early before any secrets are added).
6. ~~All listed bug-hunt items~~ **DONE** (B25 is intentional foundation gap).

*Last updated: B1+B2 fixed. Update status of an item when it is fixed (add the commit hash).*
