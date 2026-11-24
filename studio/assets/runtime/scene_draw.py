"""Load Nexus scene JSON and print a text stage (2D + 3D foundation)."""
from __future__ import annotations

# Bump when projection / camera contract changes (templates can detect).
SCENE_DRAW_VERSION = 2

import json
import math
from pathlib import Path


def load_scene(rel_path: str = "scenes/main.json") -> dict:
    path = Path(rel_path)
    if not path.is_file():
        raise FileNotFoundError(f"Scene not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("Scene root must be an object")
    return data


def _node_label(node: dict) -> str:
    name = str(node.get("name") or "node")
    ntype = str(node.get("type") or "sprite")
    x = int(float(node.get("x") or 0))
    y = int(float(node.get("y") or 0))
    z = float(node.get("z") or 0)
    w = int(float(node.get("w") or 0))
    h = int(float(node.get("h") or 0))
    pts = node.get("points")
    extra = f" poly:{len(pts)}" if isinstance(pts, list) and len(pts) >= 3 else ""
    mesh = str(node.get("mesh") or "").strip()
    if mesh and ntype != "camera":
        extra = f"{extra} mesh={mesh}"
    zpart = f" z={z:g}" if z else ""
    rx = float(node.get("rx") or 0)
    ry = float(node.get("ry") or 0)
    rz = float(node.get("rz") or 0)
    rpart = f" rot=({rx:g},{ry:g},{rz:g})" if (rx or ry or rz) else ""
    if ntype == "camera":
        fov = float(node.get("fov") or 60)
        near = float(node.get("near") or 0.1)
        far = float(node.get("far") or 1000)
        extra = f" fov={fov:g} near={near:g} far={far:g}"
    return f"{name} [{ntype}] @({x},{y}){zpart}{rpart} {w}x{h}{extra}"


def _active_camera(nodes: list, preferred_id: str | None = None) -> dict | None:
    """Prefer [preferred_id] when it names a camera; else first camera."""
    if preferred_id:
        for n in nodes:
            if (
                isinstance(n, dict)
                and str(n.get("type") or "") == "camera"
                and str(n.get("id") or "") == preferred_id
            ):
                return n
    for n in nodes:
        if isinstance(n, dict) and str(n.get("type") or "") == "camera":
            return n
    return None


def _cam_params(cam: dict) -> tuple[float, float, float, float, float, float]:
    """Unpack camera node → (cx, cy, cz, fov, near, far). Matches SceneCamFrame."""
    cx = float(cam.get("x") or 0) + float(cam.get("w") or 0) * 0.5
    cy = float(cam.get("y") or 0) + float(cam.get("h") or 0) * 0.5
    cz = float(cam.get("z") or 0)
    fov = float(cam.get("fov") or 60)
    near = max(float(cam.get("near") or 0.1), 0.01)
    far = max(float(cam.get("far") or 1000), near + 0.01)
    return cx, cy, cz, fov, near, far


def _camera_space_depth(z: float, cz: float) -> float:
    """Camera space: eye at cz, look +Z. Positive depth = in front."""
    return z - cz


def _in_soft_depth(depth: float, far: float) -> bool:
    """Soft path: on/in front of eye through far (near used for scale only)."""
    return 0.0 <= depth <= far


def _in_depth_frustum(depth: float, near: float, far: float) -> bool:
    """Strict near/far slab (NDC / true frustum)."""
    return near <= depth <= far


def _project_mode(scene: dict) -> str:
    """soft (default) | ndc — scene.projectMode or env NEXUS_PROJECT_MODE."""
    import os

    raw = str(scene.get("projectMode") or os.environ.get("NEXUS_PROJECT_MODE") or "soft")
    raw = raw.strip().lower()
    return "ndc" if raw == "ndc" else "soft"


def _depth_scale(
    depth: float,
    near: float,
    fov: float,
    width: float,
    height: float,
) -> float:
    """Soft depth scale — same idea as SceneProject.depthScale / scene editor."""
    fov_k = max(0.35, min(2.5, fov / 60.0))
    ref = max(width, height) * 0.35
    d = max(depth, near)
    return ref / (ref + d * fov_k)


def _to_ndc(
    x: float,
    y: float,
    z: float,
    width: float,
    height: float,
    params: tuple[float, float, float, float, float, float],
) -> tuple[float, float, float] | None:
    """Camera → NDC (OpenGL-style). None if outside depth slab or w<=0."""
    cx, cy, cz, fov, near, far = params
    depth = _camera_space_depth(z, cz)
    if not _in_depth_frustum(depth, near, far):
        return None
    xc = x - cx
    yc = cy - y  # stage Y-down → camera Y-up (matches Dart SceneProject)
    zc = depth
    if zc <= 1e-9:
        return None
    f = 1.0 / math.tan(math.radians(fov) * 0.5)
    a = (width / height) if height > 0 else 1.0
    nx = (f * xc / a) / zc
    ny = (f * yc) / zc
    span = far - near
    nz = ((zc - near) / span) * 2.0 - 1.0 if span > 1e-9 else 0.0
    return nx, ny, nz


def _in_ndc_lateral(nx: float, ny: float) -> bool:
    """FOV left/right/top/bottom — unit square in NDC."""
    return -1.0 <= nx <= 1.0 and -1.0 <= ny <= 1.0


def _ndc_to_stage(
    nx: float,
    ny: float,
    width: float,
    height: float,
) -> tuple[float, float]:
    """NDC → stage pixels (Y-down, top-left origin)."""
    sx = (nx + 1.0) * 0.5 * width
    sy = (1.0 - ny) * 0.5 * height
    return sx, sy


def _visible_node(
    n: dict,
    width: float,
    height: float,
    params: tuple[float, float, float, float, float, float] | None,
    mode: str,
) -> bool:
    """Pre-filter: soft = depth slab; ndc = depth + lateral FOV."""
    if params is None:
        return True
    z = float(n.get("z") or 0)
    cx, cy, cz, fov, near, far = params
    depth = _camera_space_depth(z, cz)
    if mode == "ndc":
        if not _in_depth_frustum(depth, near, far):
            return False
        # Lateral test at node center (cheap; matches editor center sample).
        x = float(n.get("x") or 0) + float(n.get("w") or 0) * 0.5
        y = float(n.get("y") or 0) + float(n.get("h") or 0) * 0.5
        ndc = _to_ndc(x, y, z, width, height, params)
        if ndc is None:
            return False
        return _in_ndc_lateral(ndc[0], ndc[1])
    return _in_soft_depth(depth, far)


def _project_xy(
    x: float,
    y: float,
    z: float,
    width: float,
    height: float,
    params: tuple[float, float, float, float, float, float] | None,
    mode: str = "soft",
    *,
    skip_cull: bool = False,
) -> tuple[float, float, bool]:
    """Project stage point — mirrors SceneProject.project (soft | ndc).

    Returns (sx, sy, visible).
    """
    if params is None:
        return x, y, True
    cx, cy, cz, fov, near, far = params
    depth = _camera_space_depth(z, cz)

    if mode == "ndc":
        ndc = _to_ndc(x, y, z, width, height, params)
        if ndc is None:
            return x, y, False
        nx, ny, _nz = ndc
        if not skip_cull and not _in_ndc_lateral(nx, ny):
            return x, y, False
        sx, sy = _ndc_to_stage(nx, ny, width, height)
        return sx, sy, True

    # soft (default)
    if not skip_cull and not _in_soft_depth(depth, far):
        return x, y, False
    s = _depth_scale(depth, near, fov, width, height)
    sx = cx + (x - cx) * s
    sy = cy + (y - cy) * s
    return sx, sy, True


def draw_scene(scene: dict) -> None:
    width = int(scene.get("width") or 720)
    height = int(scene.get("height") or 1280)
    name = str(scene.get("name") or "scene")
    nodes = scene.get("nodes") or []
    if not isinstance(nodes, list):
        nodes = []

    preferred = __import__("os").environ.get("NEXUS_CAMERA_ID")
    cam = _active_camera(nodes, preferred_id=preferred)
    params = _cam_params(cam) if cam is not None else None
    proj = _project_mode(scene)
    space = "perspective" if params is not None else "ortho"
    print(f"Nexus scene: {name}  {width}x{height}  [{space}/{proj}]")
    if params is not None:
        _cx, _cy, cz, _fov, near, far = params
        print(f"active camera: {_node_label(cam)}")
        print(f"camera space: look +Z  eye_z={cz:g}  near={near:g}  far={far:g}")
    print(f"nodes: {len(nodes)} (depth sort by z, far→near)")
    if not nodes:
        print("(empty stage)")
        return

    # Pre-filter (soft depth / ndc depth+lateral), then sort survivors.
    visible: list = []
    culled_labels: list[str] = []
    for n in nodes:
        if not isinstance(n, dict) or str(n.get("type") or "") == "camera":
            continue
        if params is not None and not _visible_node(n, width, height, params, proj):
            culled_labels.append(_node_label(n))
            continue
        visible.append(n)
    visible.sort(key=lambda n: float(n.get("z") or 0))

    cols, rows = 24, 12
    grid = [["." for _ in range(cols)] for _ in range(rows)]

    def to_cell(px: float, py: float) -> tuple[int, int]:
        c = int(px / width * (cols - 1)) if width > 0 else 0
        r = int(py / height * (rows - 1)) if height > 0 else 0
        c = max(0, min(cols - 1, c))
        r = max(0, min(rows - 1, r))
        return c, r

    for idx, node in enumerate(visible):
        ch = str(idx % 10)
        z = float(node.get("z") or 0)
        pts = node.get("points")
        if isinstance(pts, list) and len(pts) >= 3:
            coords = []
            for pt in pts:
                if not isinstance(pt, dict):
                    continue
                px = float(pt.get("x") or 0)
                py = float(pt.get("y") or 0)
                sx, sy, _vis = _project_xy(
                    px, py, z, width, height, params, proj, skip_cull=True
                )
                coords.append(to_cell(sx, sy))
                c, r = coords[-1]
                grid[r][c] = "#"
            for i in range(len(coords)):
                c0, r0 = coords[i]
                c1, r1 = coords[(i + 1) % len(coords)]
                steps = max(abs(c1 - c0), abs(r1 - r0), 1)
                for s in range(steps + 1):
                    t = s / steps
                    cc = int(round(c0 + (c1 - c0) * t))
                    rr = int(round(r0 + (r1 - r0) * t))
                    if grid[rr][cc] == ".":
                        grid[rr][cc] = ch
            continue
        x = float(node.get("x") or 0)
        y = float(node.get("y") or 0)
        w = max(float(node.get("w") or 1), 1.0)
        h = max(float(node.get("h") or 1), 1.0)
        corners = [
            _project_xy(x, y, z, width, height, params, proj, skip_cull=True)[:2],
            _project_xy(x + w, y, z, width, height, params, proj, skip_cull=True)[:2],
            _project_xy(x + w, y + h, z, width, height, params, proj, skip_cull=True)[:2],
            _project_xy(x, y + h, z, width, height, params, proj, skip_cull=True)[:2],
        ]
        cs = [to_cell(px, py) for px, py in corners]
        c0 = min(c for c, _ in cs)
        c1 = max(c for c, _ in cs)
        r0 = min(r for _, r in cs)
        r1 = max(r for _, r in cs)
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                grid[r][c] = ch

    # Mark camera cell with C
    if params is not None:
        cx, cy, _cz, _fov, _near, _far = params
        cc, rr = to_cell(cx, cy)
        grid[rr][cc] = "C"

    print("+" + "-" * cols + "+")
    for row in grid:
        print("|" + "".join(row) + "|")
    print("+" + "-" * cols + "+")
    if culled_labels:
        print(f"culled: {len(culled_labels)} (outside frustum, mode={proj})")
        for label in culled_labels:
            print(f"  culled: {label}")
    for i, node in enumerate(nodes):
        if isinstance(node, dict):
            print(f"  {i}: {_node_label(node)}")


# GameAssets.hpp makers (samples/cpp) — runtime export stub only.
_MESH_MAKERS = {
    "sword": "ga::makeSword()",
    "crate": "ga::makeWoodenCrate()",
    "chest": "ga::makeTreasureChest()",
    "metalcase": "ga::makeMetalCase()",
}


def _collect_mesh_ids(nodes: list) -> list[str]:
    seen: list[str] = []
    for n in nodes:
        if not isinstance(n, dict):
            continue
        if str(n.get("type") or "") == "camera":
            continue
        mid = str(n.get("mesh") or "").strip().lower()
        if mid and mid in _MESH_MAKERS and mid not in seen:
            seen.append(mid)
    return seen


def export_mesh_stub(scene: dict, rel_dir: str = "assets/meshes") -> None:
    """Write a manifest of linked mesh ids for later C++ / runtime sample use.

    Does not compile or copy geometry — only records which GameAssets makers
    the scene needs so a future pack step can pull samples/cpp.
    """
    nodes = scene.get("nodes") or []
    if not isinstance(nodes, list):
        nodes = []
    ids = _collect_mesh_ids(nodes)
    print("--- mesh export stub ---")
    if not ids:
        print("(no mesh ids linked on sprites)")
        return
    out_dir = Path(rel_dir)
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"mesh stub: could not create {out_dir}: {e}")
        return
    entries = []
    for mid in ids:
        maker = _MESH_MAKERS[mid]
        entries.append({
            "id": mid,
            "maker": maker,
            "header": "samples/cpp/GameAssets.hpp",
            "status": "stub",
        })
        print(f"  {mid} -> {maker}  [stub]")
    manifest = {
        "version": 1,
        "source": "scenes/main.json",
        "meshes": entries,
        "note": "Stub only — geometry not exported. Link C++17 sample later.",
    }
    path = out_dir / "manifest.json"
    try:
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path}")
    except OSError as e:
        print(f"mesh stub: write failed: {e}")


def main() -> None:
    scene = load_scene("scenes/main.json")
    draw_scene(scene)
    export_mesh_stub(scene)


if __name__ == "__main__":
    main()
