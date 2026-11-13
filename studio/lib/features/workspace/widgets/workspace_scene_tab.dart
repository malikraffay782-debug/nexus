import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../files/workspace_paths.dart';
import '../scene/scene_model.dart';
import '../scene/scene_renderer.dart';
import '../scene/scene_service.dart';

/// Scene tab: list/create scenes + sized nodes (drag, rename, resize).
class WorkspaceSceneTab extends StatefulWidget {
  const WorkspaceSceneTab({super.key, required this.projectPath});

  final String projectPath;

  @override
  State<WorkspaceSceneTab> createState() => _WorkspaceSceneTabState();
}

class _WorkspaceSceneTabState extends State<WorkspaceSceneTab>
    with SingleTickerProviderStateMixin {
  late final SceneService _service;
  List<String> _files = [];
  String? _selected;
  SceneDoc? _doc;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  String? _selectedNodeId;
  final TextEditingController _nameCtrl = TextEditingController();
  String? _nameEditNodeId;
  /// Index of vertex being edited when node.hasPoints.
  int? _editPointIndex;

  /// Graphical 2D preview loop (Flutter ticker — not proot).
  bool _playing = false;
  final ValueNotifier<double> _playTime = ValueNotifier(0.0);

  // Coalesce pointer nudges to one setState per frame (kills swipe lag).
  double _pendingNudgeDx = 0;
  double _pendingNudgeDy = 0;
  bool _nudgeFrameScheduled = false;
  Ticker? _playTicker;

  @override
  void initState() {
    super.initState();
    _service = SceneService(widget.projectPath);
    _reload();
  }

  @override
  void dispose() {
    _nudgeFrameScheduled = false;
    _pendingNudgeDx = 0;
    _pendingNudgeDy = 0;
    _stopPlayLoop();
    _playTime.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _stopPlayLoop() {
    _playTicker?.dispose();
    _playTicker = null;
    _playing = false;
    _playTime.value = 0;
  }

  void _togglePlay() {
    if (_doc == null) return;
    if (_playing) {
      _playTicker?.dispose();
      _playTicker = null;
      setState(() {
        _playing = false;
      });
      _playTime.value = 0;
      return;
    }
    _playTime.value = 0;
    _playTicker = createTicker((elapsed) {
      if (!mounted) return;
      // Only the stage ListenableBuilder rebuilds — not the whole tab.
      _playTime.value = elapsed.inMicroseconds / 1e6;
    })..start();
    setState(() {
      _playing = true;
      _editPointIndex = null;
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.listScenes();
      String? sel = _selected;
      SceneDoc? doc = _doc;
      if (list.isEmpty) {
        sel = null;
        doc = null;
      } else if (sel == null || !list.contains(sel)) {
        sel = list.first;
        doc = await _service.load(sel);
      } else {
        doc = await _service.load(sel);
      }
      if (!mounted) return;
      _stopPlayLoop();
      setState(() {
        _files = list;
        _selected = sel;
        _doc = doc;
        _dirty = false;
        _selectedNodeId = null;
        _editPointIndex = null;
        _loading = false;
      });
      _playTime.value = 0;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _select(String name) async {
    if (_dirty) {
      final discard = await _confirmDiscard();
      if (!discard || !mounted) return;
    }
    setState(() {
      _selected = name;
      _error = null;
      _loading = true;
      _selectedNodeId = null;
    });
    try {
      final doc = await _service.load(name);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _dirty = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Discard scene edits?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _createScene() async {
    if (_dirty) {
      final discard = await _confirmDiscard();
      if (!discard || !mounted) return;
    }
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New scene'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'main',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final fileName = await _service.create(name);
      await _reload();
      if (!mounted) return;
      await _select(fileName);
    } on WorkspaceException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _save() async {
    final sel = _selected;
    final doc = _doc;
    if (sel == null || doc == null || _saving) return;
    setState(() => _saving = true);
    try {
      await _service.save(sel, doc);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scene saved')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  void _addNode({String type = SceneNodeTypes.sprite}) {
    final doc = _doc;
    if (doc == null) return;
    final n = doc.nodes.length;
    final col = n % 4;
    final row = n ~/ 4;
    final t = SceneNodeTypes.normalize(type);
    final node = SceneNode(
      id: 'n_${DateTime.now().microsecondsSinceEpoch}',
      type: t,
      name: t == SceneNodeTypes.camera ? 'Camera ${n + 1}' : 'Sprite ${n + 1}',
      x: 80.0 + col * 120,
      y: 80.0 + row * 120,
      w: t == SceneNodeTypes.camera ? 48 : 64,
      h: t == SceneNodeTypes.camera ? 48 : 64,
      color: ScenePalette.forType(t),
    );
    setState(() {
      _doc = doc.withNodeAdded(node);
      _selectedNodeId = node.id;
      _syncNameField(node);
      _dirty = true;
    });
  }

  void _setNodeType(String type) {
    final t = SceneNodeTypes.normalize(type);
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? current;
    for (final n in doc.nodes) {
      if (n.id == id) {
        current = n;
        break;
      }
    }
    if (current == null) return;
    // Keep color unless switching to camera and still on a sprite default.
    final color = t == SceneNodeTypes.camera &&
            current.color == ScenePalette.forType(SceneNodeTypes.sprite)
        ? ScenePalette.forType(t)
        : current.color;
    // Cameras stay axis-aligned rects — drop polygon verts.
    final updated = t == SceneNodeTypes.camera
        ? current.copyWith(type: t, color: color, clearPoints: true)
        : current.copyWith(type: t, color: color);
    setState(() {
      _doc = doc.withNodeUpdated(updated);
      _selectedNodeId = id;
      if (t == SceneNodeTypes.camera) _editPointIndex = null;
      _dirty = true;
    });
  }

  void _setNodeColor(int argb) {
    _updateSelectedNode((n) => n.copyWith(color: argb));
  }

  void _toggleGrid() {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      _doc = doc.copyWith(showGrid: !doc.showGrid);
      _dirty = true;
    });
  }

  void _removeSelectedNode() {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    setState(() {
      _doc = doc.withNodeRemoved(id);
      _selectedNodeId = null;
      _editPointIndex = null;
      _nameEditNodeId = null;
      _nameCtrl.clear();
      _dirty = true;
    });
  }

  /// delta -1 = send backward (earlier paint), +1 = bring forward (later paint).
  void _reorderNode(String id, int delta) {
    final doc = _doc;
    if (doc == null || delta == 0) return;
    final list = List<SceneNode>.from(doc.nodes);
    final i = list.indexWhere((n) => n.id == id);
    if (i < 0) return;
    final j = (i + delta).clamp(0, list.length - 1);
    if (j == i) return;
    final node = list.removeAt(i);
    list.insert(j, node);
    setState(() {
      _doc = doc.copyWith(nodes: list);
      _selectedNodeId = id;
      _dirty = true;
    });
  }

  void _syncNameField(SceneNode? node) {
    if (node == null) {
      _nameEditNodeId = null;
      _nameCtrl.clear();
      return;
    }
    if (_nameEditNodeId != node.id) {
      _nameEditNodeId = node.id;
      _nameCtrl.text = node.name;
    }
  }

  void _selectNode(String id) {
    final doc = _doc;
    if (doc == null) return;
    SceneNode? node;
    for (final n in doc.nodes) {
      if (n.id == id) {
        node = n;
        break;
      }
    }
    setState(() {
      final same = _selectedNodeId == id;
      _selectedNodeId = id;
      // Re-tapping the same polygon must not wipe the active vertex —
      // that was dropping pad control mid-edit.
      if (!same) {
        _editPointIndex = (node != null && node.hasPoints) ? 0 : null;
      } else if (node != null &&
          node.hasPoints &&
          _editPointIndex != null &&
          (_editPointIndex! < 0 ||
              _editPointIndex! >= node.points!.length)) {
        _editPointIndex = 0;
      }
      _syncNameField(node);
    });
  }

  void _updateSelectedNode(SceneNode Function(SceneNode) fn) {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? current;
    for (final n in doc.nodes) {
      if (n.id == id) {
        current = n;
        break;
      }
    }
    if (current == null) return;
    final updated = fn(current);
    setState(() {
      _doc = doc.withNodeUpdated(updated);
      _selectedNodeId = id;
      if (_nameEditNodeId == id && updated.name != _nameCtrl.text) {
        _nameCtrl.text = updated.name;
      }
      _dirty = true;
    });
  }

  void _renameSelected(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _updateSelectedNode((n) => n.copyWith(name: trimmed));
  }

  void _resizeSelected(double delta) {
    // Prefer vertex-aware path so points mode bbox stays in sync.
    _nudgeSelected(dw: delta, dh: delta);
  }

  /// Nudge position or size by small steps (bottom transform strip).
  void _nudgeSelected({
    double dx = 0,
    double dy = 0,
    double dw = 0,
    double dh = 0,
  }) {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? current;
    for (final n in doc.nodes) {
      if (n.id == id) {
        current = n;
        break;
      }
    }
    if (current == null) return;

    // Points mode: shift or scale vertices, then refresh bounds.
    if (current.hasPoints) {
      var pts = List<ScenePoint>.from(current.points!);
      if (dx != 0 || dy != 0) {
        pts = pts
            .map((p) => ScenePoint(p.x + dx, p.y + dy))
            .toList();
      }
      if (dw != 0 || dh != 0) {
        final b = SceneNode.boundsOf(pts);
        final ox = b.$1;
        final oy = b.$2;
        final ow = b.$3 <= 0 ? 1.0 : b.$3;
        final oh = b.$4 <= 0 ? 1.0 : b.$4;
        final nw = (ow + dw).clamp(24.0, 512.0);
        final nh = (oh + dh).clamp(24.0, 512.0);
        final sx = nw / ow;
        final sy = nh / oh;
        pts = pts
            .map(
              (p) => ScenePoint(
                ox + (p.x - ox) * sx,
                oy + (p.y - oy) * sy,
              ),
            )
            .toList();
      }
      // Keep inside stage after nudge (apply X/Y independently; no overwrite).
      final b2 = SceneNode.boundsOf(pts);
      var shiftX = 0.0;
      var shiftY = 0.0;
      if (b2.$1 < 0) {
        shiftX = -b2.$1;
      } else if (b2.$1 + b2.$3 > doc.width) {
        shiftX = doc.width - (b2.$1 + b2.$3);
      }
      if (b2.$2 < 0) {
        shiftY = -b2.$2;
      } else if (b2.$2 + b2.$4 > doc.height) {
        shiftY = doc.height - (b2.$2 + b2.$4);
      }
      if (shiftX != 0 || shiftY != 0) {
        pts = pts
            .map((p) => ScenePoint(p.x + shiftX, p.y + shiftY))
            .toList();
      }
      final b3 = SceneNode.boundsOf(pts);
      setState(() {
        _doc = doc.withNodeUpdated(
          current!.copyWith(
            x: b3.$1,
            y: b3.$2,
            w: b3.$3,
            h: b3.$4,
            points: pts,
          ),
        );
        _selectedNodeId = id;
        _dirty = true;
      });
      return;
    }

    var nx = current.x + dx;
    var ny = current.y + dy;
    var nw = current.w + dw;
    var nh = current.h + dh;
    if (nw < 24) nw = 24;
    if (nh < 24) nh = 24;
    if (nx < 0) nx = 0;
    if (ny < 0) ny = 0;
    if (nx + nw > doc.width) {
      if (dw != 0) {
        nw = doc.width - nx;
      } else {
        nx = doc.width - nw;
      }
    }
    if (ny + nh > doc.height) {
      if (dh != 0) {
        nh = doc.height - ny;
      } else {
        ny = doc.height - nh;
      }
    }
    nw = nw.clamp(24.0, 512.0);
    nh = nh.clamp(24.0, 512.0);
    setState(() {
      _doc = doc.withNodeUpdated(
        current!.copyWith(x: nx, y: ny, w: nw, h: nh),
      );
      _selectedNodeId = id;
      _dirty = true;
    });
  }

  void _moveNode(String id, double x, double y) {
    final doc = _doc;
    if (doc == null) return;
    final nodes = doc.nodes.map((n) {
      if (n.id != id) return n;
      final maxX = (doc.width - n.w).clamp(0, doc.width.toDouble()).toDouble();
      final maxY = (doc.height - n.h).clamp(0, doc.height.toDouble()).toDouble();
      final nx = x.clamp(0, maxX).toDouble();
      final ny = y.clamp(0, maxY).toDouble();
      final dx = nx - n.x;
      final dy = ny - n.y;
      if (n.hasPoints) {
        final shifted = n.points!
            .map((p) => ScenePoint(p.x + dx, p.y + dy))
            .toList();
        final b = SceneNode.boundsOf(shifted);
        return n.copyWith(
          x: b.$1,
          y: b.$2,
          w: b.$3,
          h: b.$4,
          points: shifted,
        );
      }
      return n.copyWith(x: nx, y: ny);
    }).toList();
    setState(() {
      _doc = doc.copyWith(nodes: nodes);
      _selectedNodeId = id;
      _dirty = true;
    });
  }

  void _enablePointsOnSelected() {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? cur;
    for (final n in doc.nodes) {
      if (n.id == id) {
        cur = n;
        break;
      }
    }
    if (cur == null || cur.hasPoints) return;
    // Cameras stay rect for now.
    if (cur.type == SceneNodeTypes.camera) return;
    final pts = cur.rectAsPoints();
    setState(() {
      _doc = doc.withNodeUpdated(cur!.copyWith(points: pts));
      _selectedNodeId = id;
      _editPointIndex = 0; // start on first vertex for pad control
      _dirty = true;
    });
  }

  /// Selected node that is in freeform points mode (for control pad).
  SceneNode? get _pointsEditNode {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return null;
    for (final n in doc.nodes) {
      if (n.id == id && n.hasPoints) return n;
    }
    return null;
  }

  void _ensureEditPointSelected() {
    final n = _pointsEditNode;
    if (n == null) return;
    final i = _editPointIndex;
    if (i == null || i < 0 || i >= n.points!.length) {
      setState(() => _editPointIndex = 0);
    }
  }

  void _clearPointsOnSelected() {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? cur;
    for (final n in doc.nodes) {
      if (n.id == id) {
        cur = n;
        break;
      }
    }
    if (cur == null || !cur.hasPoints) return;
    setState(() {
      _doc = doc.withNodeUpdated(cur!.copyWith(clearPoints: true));
      _selectedNodeId = id;
      _editPointIndex = null;
      _dirty = true;
    });
  }

  void _movePoint(String id, int index, double sceneX, double sceneY) {
    final doc = _doc;
    if (doc == null) return;
    final nodes = doc.nodes.map((n) {
      if (n.id != id || !n.hasPoints) return n;
      if (index < 0 || index >= n.points!.length) return n;
      final sx = sceneX.clamp(0.0, doc.width.toDouble());
      final sy = sceneY.clamp(0.0, doc.height.toDouble());
      final pts = List<ScenePoint>.from(n.points!);
      pts[index] = ScenePoint(sx, sy);
      final b = SceneNode.boundsOf(pts);
      return n.copyWith(x: b.$1, y: b.$2, w: b.$3, h: b.$4, points: pts);
    }).toList();
    setState(() {
      _doc = doc.copyWith(nodes: nodes);
      _selectedNodeId = id;
      _editPointIndex = index;
      _dirty = true;
    });
  }

  /// Nudge the active vertex. Coalesces to one setState per frame.
  void _nudgeSelectedPoint({double dx = 0, double dy = 0}) {
    if (dx == 0 && dy == 0) return;
    _pendingNudgeDx += dx;
    _pendingNudgeDy += dy;
    if (_nudgeFrameScheduled) return;
    _nudgeFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _nudgeFrameScheduled = false;
      if (!mounted) {
        _pendingNudgeDx = 0;
        _pendingNudgeDy = 0;
        return;
      }
      final pdx = _pendingNudgeDx;
      final pdy = _pendingNudgeDy;
      _pendingNudgeDx = 0;
      _pendingNudgeDy = 0;
      if (pdx == 0 && pdy == 0) return;
      final id = _selectedNodeId;
      final i = _editPointIndex;
      if (id == null || i == null) return;
      final nodes = _doc?.nodes;
      if (nodes == null) return;
      for (final e in nodes) {
        if (e.id == id && e.hasPoints && i >= 0 && i < e.points!.length) {
          final p = e.points![i];
          _movePoint(id, i, p.x + pdx, p.y + pdy);
          return;
        }
      }
    });
  }

  /// Insert a vertex after the selected point (or last). Midpoint of that edge.
  void _addPointOnSelected() {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? cur;
    for (final n in doc.nodes) {
      if (n.id == id) {
        cur = n;
        break;
      }
    }
    if (cur == null || !cur.hasPoints) return;
    final pts = List<ScenePoint>.from(cur.points!);
    final n = pts.length;
    final i = (_editPointIndex ?? (n - 1)).clamp(0, n - 1);
    final a = pts[i];
    final b = pts[(i + 1) % n];
    final mid = ScenePoint((a.x + b.x) / 2, (a.y + b.y) / 2);
    pts.insert(i + 1, mid);
    final box = SceneNode.boundsOf(pts);
    setState(() {
      _doc = doc.withNodeUpdated(
        cur!.copyWith(
          x: box.$1,
          y: box.$2,
          w: box.$3,
          h: box.$4,
          points: pts,
        ),
      );
      _selectedNodeId = id;
      _editPointIndex = i + 1;
      _dirty = true;
    });
  }

  /// Remove selected vertex; keep at least 3.
  /// If no vertex is selected, removes the last one.
  void _removePointOnSelected() {
    final doc = _doc;
    final id = _selectedNodeId;
    if (doc == null || id == null) return;
    SceneNode? cur;
    for (final n in doc.nodes) {
      if (n.id == id) {
        cur = n;
        break;
      }
    }
    if (cur == null || !cur.hasPoints) return;
    final pts = List<ScenePoint>.from(cur.points!);
    if (pts.length <= 3) return;
    var i = _editPointIndex;
    if (i == null || i < 0 || i >= pts.length) {
      i = pts.length - 1;
    }
    pts.removeAt(i);
    final box = SceneNode.boundsOf(pts);
    final nextIdx = i >= pts.length ? pts.length - 1 : i;
    setState(() {
      _doc = doc.withNodeUpdated(
        cur!.copyWith(
          x: box.$1,
          y: box.$2,
          w: box.$3,
          h: box.$4,
          points: pts,
        ),
      );
      _selectedNodeId = id;
      _editPointIndex = nextIdx;
      _dirty = true;
    });
  }

  /// Resize with optional origin shift (for non-BR corners). Clamps inside stage.
  void _resizeNode(
    String id, {
    required double w,
    required double h,
    double? x,
    double? y,
  }) {
    final doc = _doc;
    if (doc == null) return;
    final nodes = doc.nodes.map((n) {
      if (n.id != id) return n;
      var nx = x ?? n.x;
      var ny = y ?? n.y;
      var nw = w;
      var nh = h;
      // Min size.
      if (nw < 24) {
        if (x != null) nx = n.x + n.w - 24;
        nw = 24;
      }
      if (nh < 24) {
        if (y != null) ny = n.y + n.h - 24;
        nh = 24;
      }
      // Keep inside stage.
      if (nx < 0) {
        nw += nx;
        nx = 0;
      }
      if (ny < 0) {
        nh += ny;
        ny = 0;
      }
      if (nx + nw > doc.width) nw = doc.width - nx;
      if (ny + nh > doc.height) nh = doc.height - ny;
      nw = nw.clamp(24.0, 512.0);
      nh = nh.clamp(24.0, 512.0);
      return n.copyWith(x: nx, y: ny, w: nw, h: nh);
    }).toList();
    setState(() {
      _doc = doc.copyWith(nodes: nodes);
      _selectedNodeId = id;
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading && _doc == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        _sceneStrip(scheme),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          ),
        Expanded(
          child: _doc == null
              ? _emptyScenes(scheme)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Side-by-side only when both axes have room; else stack.
                    final wide = constraints.maxWidth >= 560 &&
                        constraints.maxHeight >= 300;
                    // Pad only while a vertex is active — Done hides it without dropping points.
                    final pointsPad =
                        _pointsEditNode != null && _editPointIndex != null;
                    final selected = _selectedNodeId != null;
                    if (wide) {
                      return Row(
                        children: [
                          SizedBox(
                            width: 200,
                            child: _nodeSidebar(scheme),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Column(
                              children: [
                                Expanded(child: _buildCanvas(scheme)),
                                if (pointsPad) _pointsControlPad(scheme),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    // Phone / portrait: stage is king. Tools live in a fixed
                    // bottom dock (video-editor style) — never a tall top panel.
                    return Column(
                      children: [
                        _phoneNodesBar(scheme),
                        const Divider(height: 1),
                        Expanded(child: _buildCanvas(scheme)),
                        if (pointsPad)
                          _pointsControlPad(scheme)
                        else if (selected)
                          _phoneInspector(scheme),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sceneStrip(ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final name = _files[i];
                  final selected = name == _selected;
                  return ChoiceChip(
                    label: Text(
                      name.replaceAll('.json', ''),
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: selected,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) => _select(name),
                  );
                },
              ),
            ),
            if (_dirty)
              const Padding(
                padding: EdgeInsets.only(right: 2),
                child: Icon(Icons.circle, size: 9, color: Colors.orange),
              ),
            // Overflow menu — strip stays free as features grow.
            PopupMenuButton<String>(
              tooltip: 'Scene menu',
              icon: const Icon(Icons.more_vert, size: 22),
              padding: EdgeInsets.zero,
              onSelected: (v) async {
                switch (v) {
                  case 'save':
                    if (_dirty && !_saving) await _save();
                    return;
                  case 'new':
                    await _createScene();
                    return;
                  case 'reload':
                    if (_dirty) {
                      final d = await _confirmDiscard();
                      if (!d || !mounted) return;
                    }
                    await _reload();
                    return;
                  case 'add_sprite':
                    _addNode(type: SceneNodeTypes.sprite);
                    return;
                  case 'add_camera':
                    _addNode(type: SceneNodeTypes.camera);
                    return;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'save',
                  enabled: _dirty && !_saving,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 20),
                    title: const Text('Save scene'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'new',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.note_add_outlined, size: 20),
                    title: Text('New scene'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'reload',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.refresh, size: 20),
                    title: Text('Reload'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'add_sprite',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.crop_square, size: 20),
                    title: Text('Add sprite'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'add_camera',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.videocam_outlined, size: 20),
                    title: Text('Add camera'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyScenes(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.landscape_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('No scenes yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: _createScene,
            child: const Text('Create main scene'),
          ),
        ],
      ),
    );
  }

  /// Thin top strip: node chips + add (phone layout).
  Widget _phoneNodesBar(ColorScheme scheme) {
    final doc = _doc;
    final nodes = doc?.nodes ?? const <SceneNode>[];
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.25),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: nodes.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final n = nodes[i];
                  final sel = n.id == _selectedNodeId;
                  return FilterChip(
                    label: Text(
                      n.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: sel,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    avatar: CircleAvatar(
                      backgroundColor: Color(n.color),
                      radius: 6,
                    ),
                    onSelected: (_) => _selectNode(n.id),
                  );
                },
              ),
            ),
            // Quick add still here; full scene actions live in ⋮ menu.
            IconButton(
              tooltip: 'Add sprite',
              icon: const Icon(Icons.add, size: 22),
              onPressed: () => _addNode(type: SceneNodeTypes.sprite),
            ),
          ],
        ),
      ),
    );
  }

  /// Fixed-height bottom inspector — never grows into the stage.
  Widget _phoneInspector(ColorScheme scheme) {
    final doc = _doc;
    SceneNode? node;
    if (doc != null && _selectedNodeId != null) {
      for (final n in doc.nodes) {
        if (n.id == _selectedNodeId) {
          node = n;
          break;
        }
      }
    }
    if (node == null) return const SizedBox.shrink();
    final n = node;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
      elevation: 4,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // Slightly taller + 44dp targets for thumb-friendly taps.
          height: 118,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        n.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${n.x.round()},${n.y.round()} · ${n.w.round()}×${n.h.round()}',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                    if (n.type != SceneNodeTypes.camera) ...[
                      const SizedBox(width: 4),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        onPressed: n.hasPoints
                            ? () {
                                FocusScope.of(context).unfocus();
                                setState(() => _editPointIndex = 0);
                              }
                            : () {
                                FocusScope.of(context).unfocus();
                                _enablePointsOnSelected();
                              },
                        child: Text(
                          n.hasPoints ? 'Points' : 'Edit points',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (n.hasPoints)
                        TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: _clearPointsOnSelected,
                          child: const Text('Rect', style: TextStyle(fontSize: 13)),
                        ),
                    ],
                    IconButton(
                      tooltip: 'Delete',
                      icon: Icon(Icons.delete_outline, size: 22, color: scheme.error),
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      onPressed: _removeSelectedNode,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Row(
                    children: [
                      for (final t in SceneNodeTypes.all)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(t, style: const TextStyle(fontSize: 12)),
                            selected: n.type == t,
                            onSelected: (_) => _setNodeType(t),
                          ),
                        ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: ScenePalette.colors.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final c = ScenePalette.colors[i];
                            final sel = n.color == c;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _setNodeColor(c),
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Center(
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: Color(c),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: sel
                                            ? scheme.onSurface
                                            : scheme.outlineVariant,
                                        width: sel ? 2.4 : 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Smaller',
                        icon: const Icon(Icons.remove, size: 22),
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: () => _nudgeSelected(dw: -8, dh: -8),
                      ),
                      IconButton(
                        tooltip: 'Larger',
                        icon: const Icon(Icons.add, size: 22),
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: () => _nudgeSelected(dw: 8, dh: 8),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Large video-editor style pad: left tool rail + full swipe surface.
  Widget _pointsControlPad(ColorScheme scheme) {
    final node = _pointsEditNode;
    final idx = _editPointIndex;
    if (node == null || idx == null) return const SizedBox.shrink();
    final pts = node.points!;
    if (idx < 0 || idx >= pts.length) return const SizedBox.shrink();
    final p = pts[idx];
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.98),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          // Full-bleed swipe zone under the title (fills dock, not a small inset card).
          height: 320,
          child: Column(
            children: [
              // Title bar
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(Icons.control_camera,
                          size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Edit Points  ·  P${idx + 1}/${pts.length}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${p.x.round()}, ${p.y.round()}',
                        style: TextStyle(fontSize: 13, color: scheme.outline),
                      ),
                      const Spacer(),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          setState(() => _editPointIndex = null);
                        },
                        child: const Text(
                          'Done',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              // Rail + swipe pad
              Expanded(
                child: Row(
                  children: [
                    // Left tool rail
                    SizedBox(
                      width: 56,
                      child: Column(
                        children: [
                          const SizedBox(height: 6),
                          IconButton(
                            tooltip: 'Add vertex on edge',
                            icon: const Icon(Icons.add_circle_outline, size: 24),
                            constraints:
                                const BoxConstraints(minWidth: 48, minHeight: 44),
                            onPressed: _addPointOnSelected,
                          ),
                          IconButton(
                            tooltip: 'Remove vertex',
                            icon: const Icon(Icons.remove_circle_outline, size: 24),
                            constraints:
                                const BoxConstraints(minWidth: 48, minHeight: 44),
                            onPressed:
                                pts.length > 3 ? _removePointOnSelected : null,
                          ),
                          const Divider(height: 12),
                          Expanded(
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              itemCount: pts.length,
                              itemBuilder: (context, i) {
                                final sel = i == idx;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Material(
                                    color: sel
                                        ? scheme.primaryContainer
                                        : scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: () =>
                                          setState(() => _editPointIndex = i),
                                      child: SizedBox(
                                        height: 36,
                                        child: Center(
                                          child: Text(
                                            'P${i + 1}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: sel
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // Full-bleed swipe surface (uses all remaining dock space).
                    Expanded(
                      child: ColoredBox(
                        color: scheme.surface.withValues(alpha: 0.92),
                        child: Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              left: 12,
                              top: 10,
                              child: Icon(
                                Icons.crop_free,
                                size: 18,
                                color: scheme.outline.withValues(alpha: 0.35),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 10,
                              child: Icon(
                                Icons.crop_free,
                                size: 18,
                                color: scheme.outline.withValues(alpha: 0.35),
                              ),
                            ),
                            IgnorePointer(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.open_with,
                                    size: 40,
                                    color: scheme.primary.withValues(alpha: 0.45),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Swipe here to move the point',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.75),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Or drag handles on the stage',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned.fill(
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerMove: (e) {
                                  const sens = 1.6;
                                  _nudgeSelectedPoint(
                                    dx: e.delta.dx * sens,
                                    dy: e.delta.dy * sens,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nodeSidebar(ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Nodes',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Add node',
                  icon: const Icon(Icons.add, size: 20),
                  padding: EdgeInsets.zero,
                  onSelected: (t) => _addNode(type: t),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: SceneNodeTypes.sprite,
                      child: Text('Sprite'),
                    ),
                    PopupMenuItem(
                      value: SceneNodeTypes.camera,
                      child: Text('Camera'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // List must shrink; properties stay fixed-height below.
          Expanded(child: _nodeList(scheme)),
          if (_selectedNodeId != null) ...[
            const Divider(height: 1),
            _nodeProperties(scheme),
          ],
        ],
      ),
    );
  }

  Widget _nodeProperties(ColorScheme scheme) {
    final doc = _doc;
    SceneNode? node;
    if (doc != null && _selectedNodeId != null) {
      for (final n in doc.nodes) {
        if (n.id == _selectedNodeId) {
          node = n;
          break;
        }
      }
    }
    if (node == null) return const SizedBox.shrink();

    Widget stepper(String label, int value, VoidCallback onMinus, VoidCallback onPlus) {
      return Expanded(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
            IconButton(
              icon: const Icon(Icons.remove, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onMinus,
            ),
            Text('$value', style: const TextStyle(fontSize: 12)),
            IconButton(
              icon: const Icon(Icons.add, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onPlus,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 1, 4, 1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Name',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: _renameSelected,
            onChanged: (v) {
              if (v.trim().isNotEmpty) _renameSelected(v);
            },
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              for (final t in SceneNodeTypes.all)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(t, style: const TextStyle(fontSize: 11)),
                    selected: node.type == t,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) => _setNodeType(t),
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Remove node',
                icon: Icon(Icons.delete_outline, size: 18, color: scheme.error),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: _removeSelectedNode,
              ),
            ],
          ),
          // Edit points (sprites only)
          if (node.type != SceneNodeTypes.camera)
            Padding(
              padding: const EdgeInsets.only(bottom: 0),
              child: Row(
                children: [
                  Text(
                    node.hasPoints ? 'Points' : 'Rect',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                  const SizedBox(width: 6),
                  if (!node.hasPoints)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _enablePointsOnSelected,
                      child: const Text('Edit points', style: TextStyle(fontSize: 12)),
                    )
                  else ...[
                    Text(
                      '${node.points!.length} verts',
                      style: const TextStyle(fontSize: 11),
                    ),
                    IconButton(
                      tooltip: 'Add vertex',
                      icon: const Icon(Icons.add, size: 18),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      onPressed: _addPointOnSelected,
                    ),
                    IconButton(
                      tooltip: 'Remove vertex',
                      icon: const Icon(Icons.remove, size: 18),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      onPressed: node.points!.length > 3
                          ? _removePointOnSelected
                          : null,
                    ),
                    const Spacer(),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _clearPointsOnSelected,
                      child: const Text('Back to rect', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ],
              ),
            ),
          // Transform: node X/Y or selected vertex Px/Py (YOKOSO-style point coords)
          if (node.hasPoints &&
              _editPointIndex != null &&
              _editPointIndex! >= 0 &&
              _editPointIndex! < node.points!.length) ...[
            Row(
              children: [
                Text(
                  'P${_editPointIndex! + 1}',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                const SizedBox(width: 4),
                stepper(
                  'X',
                  node.points![_editPointIndex!].x.round(),
                  () => _nudgeSelectedPoint(dx: -8),
                  () => _nudgeSelectedPoint(dx: 8),
                ),
                stepper(
                  'Y',
                  node.points![_editPointIndex!].y.round(),
                  () => _nudgeSelectedPoint(dy: -8),
                  () => _nudgeSelectedPoint(dy: 8),
                ),
              ],
            ),
          ] else
            Row(
              children: [
                stepper('X', node.x.round(), () => _nudgeSelected(dx: -8), () => _nudgeSelected(dx: 8)),
                stepper('Y', node.y.round(), () => _nudgeSelected(dy: -8), () => _nudgeSelected(dy: 8)),
              ],
            ),
          // Size: W H (bbox; scales verts when in points mode)
          Row(
            children: [
              stepper('W', node.w.round(), () => _nudgeSelected(dw: -8), () => _nudgeSelected(dw: 8)),
              stepper('H', node.h.round(), () => _nudgeSelected(dh: -8), () => _nudgeSelected(dh: 8)),
            ],
          ),
          // Color
          SizedBox(
            height: 26,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ScenePalette.colors.length,
              separatorBuilder: (_, __) => const SizedBox(width: 5),
              itemBuilder: (context, i) {
                final c = ScenePalette.colors[i];
                final selected = node!.color == c;
                return GestureDetector(
                  onTap: () => _setNodeColor(c),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? scheme.onSurface : scheme.outlineVariant,
                        width: selected ? 2.2 : 1,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _nodeList(ColorScheme scheme) {
    final doc = _doc;
    if (doc == null || doc.nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'No nodes.\nTap + to add.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.outline, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: doc.nodes.length,
      itemBuilder: (context, i) {
        final n = doc.nodes[i];
        final selected = n.id == _selectedNodeId;
        final last = i == doc.nodes.length - 1;
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          title: Text(n.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${n.type} · ${n.w.toInt()}×${n.h.toInt()}'
            '${n.hasPoints ? ' · poly' : ''}',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          leading: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Color(n.color),
              shape: BoxShape.circle,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Send backward',
                icon: const Icon(Icons.arrow_downward, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: i == 0 ? null : () => _reorderNode(n.id, -1),
              ),
              IconButton(
                tooltip: 'Bring forward',
                icon: const Icon(Icons.arrow_upward, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: last ? null : () => _reorderNode(n.id, 1),
              ),
            ],
          ),
          onTap: () => _selectNode(n.id),
        );
      },
    );
  }

  Widget _buildCanvas(ColorScheme scheme) {
    final doc = _doc!;
    return LayoutBuilder(
      builder: (context, constraints) {
        const pad = 12.0;
        final maxW = (constraints.maxWidth - pad * 2).clamp(40.0, double.infinity);
        final maxH = (constraints.maxHeight - pad * 2 - 24).clamp(40.0, double.infinity);
        final aspect = doc.width / doc.height;
        double w = maxW;
        double h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }
        if (w <= 0 || h <= 0) {
          return const SizedBox.shrink();
        }
        final scaleX = w / doc.width;
        final scaleY = h / doc.height;

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        '${doc.name}  ·  ${doc.width}×${doc.height}  ·  ${doc.nodes.length}'
                        '${_dirty ? '  ·  unsaved' : ''}',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: scheme.outline,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: _playing ? 'Stop preview' : 'Play 2D preview',
                      icon: Icon(
                        _playing ? Icons.stop : Icons.play_arrow,
                        size: 20,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: _togglePlay,
                    ),
                    IconButton(
                      tooltip: doc.showGrid ? 'Hide grid' : 'Show grid',
                      icon: Icon(
                        doc.showGrid ? Icons.grid_on : Icons.grid_off,
                        size: 18,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: _playing ? null : _toggleGrid,
                    ),
                  ],
                ),
              ),
              Container(
                width: w,
                height: h,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A22),
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  children: [
                    // Graphical 2D stage (play ticker only rebuilds this layer).
                    Positioned.fill(
                      child: ListenableBuilder(
                        listenable: _playTime,
                        builder: (context, _) {
                          return CustomPaint(
                            painter: SceneStagePainter(
                              doc: doc,
                              selectedId:
                                  _playing ? null : _selectedNodeId,
                              editPointIndex:
                                  _playing ? null : _editPointIndex,
                              showGrid: doc.showGrid,
                              playTime: _playing ? _playTime.value : 0.0,
                            ),
                          );
                        },
                      ),
                    ),
                    if (doc.nodes.isEmpty)
                      Center(
                        child: Text(
                          'Empty stage — add a sprite or camera',
                          style: TextStyle(color: scheme.outline),
                        ),
                      ),
                    // Interactive edit handles only when not in play loop.
                    if (!_playing)
                      for (final n in doc.nodes)
                        _nodeMarker(
                          n,
                          scaleX: scaleX,
                          scaleY: scaleY,
                          stageW: w,
                          stageH: h,
                          scheme: scheme,
                          paintBody: false,
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _nodeMarker(
    SceneNode n, {
    required double scaleX,
    required double scaleY,
    required double stageW,
    required double stageH,
    required ColorScheme scheme,
    bool paintBody = true,
  }) {
    final selected = n.id == _selectedNodeId;
    final isCamera = n.type == SceneNodeTypes.camera;
    final fill = Color(n.color).withValues(alpha: selected ? 0.95 : 0.82);
    // Touch-friendly: ~40dp hit, visible ~20dp.
    const handleVisual = 20.0;
    const handleHit = 40.0;

    // --- Polygon (edit-points) mode ---
    if (n.hasPoints) {
      final pts = n.points!;
      // Bounding box in stage pixels for the Positioned host.
      final left = (n.x * scaleX).clamp(0.0, stageW);
      final top = (n.y * scaleY).clamp(0.0, stageH);
      final mw = (n.w * scaleX).clamp(8.0, stageW);
      final mh = (n.h * scaleY).clamp(8.0, stageH);

      // Body is drawn by SceneStagePainter; this layer is hit-targets + handles.
      final polyChildren = <Widget>[
        SizedBox(width: mw, height: mh),
      ];

      if (selected) {
        for (var i = 0; i < pts.length; i++) {
          final p = pts[i];
          final px = (p.x - n.x) * scaleX;
          final py = (p.y - n.y) * scaleY;
          final active = _editPointIndex == i;
          polyChildren.add(
            Positioned(
              left: px - handleHit / 2,
              top: py - handleHit / 2,
              width: handleHit,
              height: handleHit,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  setState(() => _editPointIndex = i);
                },
                onPanUpdate: (details) {
                  // Read current point from doc (avoid stale build closure).
                  double cx = p.x;
                  double cy = p.y;
                  final nodes = _doc?.nodes;
                  if (nodes != null) {
                    for (final e in nodes) {
                      if (e.id == n.id && e.hasPoints &&
                          i < e.points!.length) {
                        cx = e.points![i].x;
                        cy = e.points![i].y;
                        break;
                      }
                    }
                  }
                  final nx = cx + details.delta.dx / scaleX;
                  final ny = cy + details.delta.dy / scaleY;
                  _movePoint(n.id, i, nx, ny);
                },
                child: Center(
                  child: Container(
                    width: handleVisual,
                    height: handleVisual,
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFF69F0AE) : Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: fill,
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        // Edge midpoints — tap to insert a vertex on that edge.
        for (var i = 0; i < pts.length; i++) {
          final a = pts[i];
          final b = pts[(i + 1) % pts.length];
          final mx = ((a.x + b.x) / 2 - n.x) * scaleX;
          final my = ((a.y + b.y) / 2 - n.y) * scaleY;
          const midHit = 28.0;
          const midVisual = 14.0;
          final edgeIndex = i;
          polyChildren.add(
            Positioned(
              left: mx - midHit / 2,
              top: my - midHit / 2,
              width: midHit,
              height: midHit,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _editPointIndex = edgeIndex);
                  _addPointOnSelected();
                },
                child: Center(
                  child: Container(
                    width: midVisual,
                    height: midVisual,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                      border: Border.all(color: fill, width: 1.5),
                    ),
                    child: Icon(Icons.add, size: 10, color: fill),
                  ),
                ),
              ),
            ),
          );
        }
      }

      return Positioned(
        left: left,
        top: top,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectNode(n.id),
          onPanUpdate: (details) {
            SceneNode? cur;
            final nodes = _doc?.nodes;
            if (nodes != null) {
              for (final e in nodes) {
                if (e.id == n.id) {
                  cur = e;
                  break;
                }
              }
            }
            if (cur == null) return;
            final newX = cur.x + details.delta.dx / scaleX;
            final newY = cur.y + details.delta.dy / scaleY;
            _moveNode(n.id, newX, newY);
          },
          child: SizedBox(
            width: mw,
            height: mh,
            child: Stack(
              clipBehavior: Clip.none,
              children: polyChildren,
            ),
          ),
        ),
      );
    }

    // --- Rect mode (default) ---
    final mw = (n.w * scaleX).clamp(16.0, stageW);
    final mh = (n.h * scaleY).clamp(16.0, stageH);
    final left =
        (n.x * scaleX).clamp(0.0, (stageW - mw).clamp(0.0, stageW));
    final top =
        (n.y * scaleY).clamp(0.0, (stageH - mh).clamp(0.0, stageH));

    Widget body = paintBody
        ? Container(
            width: mw,
            height: mh,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(isCamera ? 20 : 6),
              border: Border.all(
                color: selected ? Colors.white : fill.withValues(alpha: 1),
                width: selected ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: fill.withValues(alpha: 0.45),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              isCamera ? Icons.videocam : Icons.square_rounded,
              size: (mw < 28 || mh < 28) ? 12 : 18,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          )
        : SizedBox(width: mw, height: mh);

    if (selected) {
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          _resizeHandle(
            n: n,
            scaleX: scaleX,
            scaleY: scaleY,
            fill: fill,
            visual: handleVisual,
            hit: handleHit,
            corner: _ResizeCorner.tl,
          ),
          _resizeHandle(
            n: n,
            scaleX: scaleX,
            scaleY: scaleY,
            fill: fill,
            visual: handleVisual,
            hit: handleHit,
            corner: _ResizeCorner.tr,
          ),
          _resizeHandle(
            n: n,
            scaleX: scaleX,
            scaleY: scaleY,
            fill: fill,
            visual: handleVisual,
            hit: handleHit,
            corner: _ResizeCorner.bl,
          ),
          _resizeHandle(
            n: n,
            scaleX: scaleX,
            scaleY: scaleY,
            fill: fill,
            visual: handleVisual,
            hit: handleHit,
            corner: _ResizeCorner.br,
          ),
        ],
      );
    }

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectNode(n.id),
        onPanUpdate: (details) {
          SceneNode? cur;
          final nodes = _doc?.nodes;
          if (nodes != null) {
            for (final e in nodes) {
              if (e.id == n.id) {
                cur = e;
                break;
              }
            }
          }
          if (cur == null) return;
          final newX = cur.x + details.delta.dx / scaleX;
          final newY = cur.y + details.delta.dy / scaleY;
          _moveNode(n.id, newX, newY);
        },
        child: body,
      ),
    );
  }

  Widget _resizeHandle({
    required SceneNode n,
    required double scaleX,
    required double scaleY,
    required Color fill,
    required double visual,
    required double hit,
    required _ResizeCorner corner,
  }) {
    double? left, top, right, bottom;
    switch (corner) {
      case _ResizeCorner.tl:
        left = -hit / 2 + 2;
        top = -hit / 2 + 2;
        break;
      case _ResizeCorner.tr:
        right = -hit / 2 + 2;
        top = -hit / 2 + 2;
        break;
      case _ResizeCorner.bl:
        left = -hit / 2 + 2;
        bottom = -hit / 2 + 2;
        break;
      case _ResizeCorner.br:
        right = -hit / 2 + 2;
        bottom = -hit / 2 + 2;
        break;
    }
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: hit,
      height: hit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          SceneNode? cur;
          final nodes = _doc?.nodes;
          if (nodes != null) {
            for (final e in nodes) {
              if (e.id == n.id) {
                cur = e;
                break;
              }
            }
          }
          if (cur == null) return;
          final dx = details.delta.dx / scaleX;
          final dy = details.delta.dy / scaleY;
          switch (corner) {
            case _ResizeCorner.br:
              _resizeNode(n.id, w: cur.w + dx, h: cur.h + dy);
              break;
            case _ResizeCorner.bl:
              _resizeNode(
                n.id,
                w: cur.w - dx,
                h: cur.h + dy,
                x: cur.x + dx,
              );
              break;
            case _ResizeCorner.tr:
              _resizeNode(
                n.id,
                w: cur.w + dx,
                h: cur.h - dy,
                y: cur.y + dy,
              );
              break;
            case _ResizeCorner.tl:
              _resizeNode(
                n.id,
                w: cur.w - dx,
                h: cur.h - dy,
                x: cur.x + dx,
                y: cur.y + dy,
              );
              break;
          }
        },
        child: Center(
          child: Container(
            width: visual,
            height: visual,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: fill, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ResizeCorner { tl, tr, bl, br }
