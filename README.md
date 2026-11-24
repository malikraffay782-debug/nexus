# Nexus

**Mobile game + code studio** on device: Flutter Studio UI, embedded Linux (proot) for Python/tools, and a **3D-oriented scene foundation** you fill yourself.

- **Repo:** https://github.com/malikraffay782-debug/nexus  
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

| Piece | Status |
|-------|--------|
| Scene JSON + nodes (sprite/camera, z, zDepth, fov, near, far) | Yes |
| Soft projection (default, low-end) | Yes |
| NDC + view/projection matrices + lateral cull | Yes (opt-in Soft/NDC toggle) |
| Camera rx/ry/rz orient NDC view matrix | Yes |
| Node rotation rx/ry/rz on stage + handles | Yes |
| AABB frustum (flat + zDepth) + skip-draw outside | Yes |
| Play sample: node named `Player` + WASD + **touch stick** | Yes (preview only) |
| Mesh ids on sprites (`sword` / `crate` / `chest` / `metalcase`) | Yes (JSON + UI picker) |
| Studio mesh silhouette (wireframe in node pose) | Yes (not GPU mesh) |
| Full Unity camera / GPU mesh / animation states | **No** |
| Auto ground / default level | **No** (by design) |

Play projection modes: **Soft** (default) or **NDC**. Run template can use `projectMode` / `NEXUS_PROJECT_MODE`.

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
| `studio/test/scene_project_test.dart` | Soft/NDC project, frustum, AABB visibility, camera pick |
| `studio/test/scene_model_test.dart` | Node/doc JSON round-trip, degrees, foreshorten, mesh |

### Scene tab structure

| File | Role |
|------|------|
| `widgets/workspace_scene_tab.dart` | Scene tab orchestration + UI (shrinking) |
| `widgets/play_touch_stick.dart` | Play-mode virtual stick |
| `scene/scene_play_controller.dart` | Play ticker, steer, Soft/NDC mode |

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

1. **Finish scene-tab split** — canvas / inspector / play into smaller files (behavior unchanged)  
2. **Shared editor↔run transform** — one tested function; Python consumes same results  
3. **Touch / play feel** — dt-based move, stick dead-zone  
4. **Assets** pipeline (image import + size limit)  
5. Optional languages on demand / real mesh loader later  

---

## 10. License / intent

Built to become a serious open or productized mobile studio. Keep the stage empty and dark so **large games are user-built**, not template-filled.
