import 'package:flutter/material.dart';

import '../files/workspace_paths.dart';
import '../scene/scene_model.dart';
import '../scene/scene_service.dart';

/// Scene tab: list/create scenes + sized nodes (drag, rename, resize).
class WorkspaceSceneTab extends StatefulWidget {
  const WorkspaceSceneTab({super.key, required this.projectPath});

  final String projectPath;

  @override
  State<WorkspaceSceneTab> createState() => _WorkspaceSceneTabState();
}

class _WorkspaceSceneTabState extends State<WorkspaceSceneTab> {
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

  @override
  void initState() {
    super.initState();
    _service = SceneService(widget.projectPath);
    _reload();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
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
      setState(() {
        _files = list;
        _selected = sel;
        _doc = doc;
        _dirty = false;
        _selectedNodeId = null;
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

  void _addNode() {
    final doc = _doc;
    if (doc == null) return;
    final n = doc.nodes.length;
    final col = n % 4;
    final row = n ~/ 4;
    final node = SceneNode(
      id: 'n_${DateTime.now().microsecondsSinceEpoch}',
      type: 'sprite',
      name: 'Node ${n + 1}',
      x: 80.0 + col * 120,
      y: 80.0 + row * 120,
      w: 64,
      h: 64,
    );
    setState(() {
      _doc = doc.withNodeAdded(node);
      _selectedNodeId = node.id;
      _syncNameField(node);
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
      _nameEditNodeId = null;
      _nameCtrl.clear();
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
      _selectedNodeId = id;
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
    _updateSelectedNode((n) {
      final nw = (n.w + delta).clamp(24.0, 256.0);
      final nh = (n.h + delta).clamp(24.0, 256.0);
      return n.copyWith(w: nw, h: nh);
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
      return n.copyWith(x: nx, y: ny);
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
                    // Landscape / short height: stack nodes above canvas.
                    final wide = constraints.maxWidth >= 520 &&
                        constraints.maxHeight >= 280;
                    if (wide) {
                      return Row(
                        children: [
                          SizedBox(
                            width: 160,
                            child: _nodeSidebar(scheme),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: _buildCanvas(scheme)),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        SizedBox(
                          height: (constraints.maxHeight * 0.32)
                              .clamp(100.0, 160.0),
                          child: _nodeSidebar(scheme),
                        ),
                        const Divider(height: 1),
                        Expanded(child: _buildCanvas(scheme)),
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
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final name = _files[i];
                  final selected = name == _selected;
                  return ChoiceChip(
                    label: Text(name.replaceAll('.json', '')),
                    selected: selected,
                    onSelected: (_) => _select(name),
                  );
                },
              ),
            ),
            if (_dirty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.circle, size: 10, color: Colors.orange),
              ),
            IconButton(
              tooltip: 'Save scene',
              onPressed: (_dirty && !_saving) ? _save : null,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
            ),
            IconButton(
              tooltip: 'New scene',
              onPressed: _createScene,
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: () async {
                if (_dirty) {
                  final d = await _confirmDiscard();
                  if (!d || !mounted) return;
                }
                await _reload();
              },
              icon: const Icon(Icons.refresh),
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

  Widget _nodeSidebar(ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Nodes',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Add node',
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: _addNode,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _nodeList(scheme)),
          if (_selectedNodeId != null) ...[
            const Divider(height: 1),
            _nodeProperties(scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: OutlinedButton.icon(
                onPressed: _removeSelectedNode,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove'),
              ),
            ),
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
    // Keep name field in sync when selection changes from canvas.
    if (_nameEditNodeId != node.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncNameField(node);
        setState(() {});
      });
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Selected', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Name',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: _renameSelected,
            onChanged: (v) {
              // Live rename while typing (empty ignored until done).
              if (v.trim().isNotEmpty) _renameSelected(v);
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Size ${node.w.toInt()}×${node.h.toInt()}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Smaller',
                icon: const Icon(Icons.remove, size: 20),
                onPressed: () => _resizeSelected(-8),
              ),
              Expanded(
                child: Text(
                  '${node.w.toInt()}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: 'Larger',
                icon: const Icon(Icons.add, size: 20),
                onPressed: () => _resizeSelected(8),
              ),
            ],
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
      itemCount: doc.nodes.length,
      itemBuilder: (context, i) {
        final n = doc.nodes[i];
        final selected = n.id == _selectedNodeId;
        return ListTile(
          dense: true,
          selected: selected,
          title: Text(n.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${n.type} · ${n.w.toInt()}×${n.h.toInt()} · (${n.x.toInt()}, ${n.y.toInt()})',
            style: TextStyle(fontSize: 11, color: scheme.outline),
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
              Text(
                '${doc.name}  ·  ${doc.width}×${doc.height}  ·  ${doc.nodes.length} nodes'
                '${_dirty ? '  ·  unsaved' : ''}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              const SizedBox(height: 6),
              Container(
                width: w,
                height: h,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  children: [
                    if (doc.nodes.isEmpty)
                      Center(
                        child: Text(
                          'Empty stage — add a node',
                          style: TextStyle(color: scheme.outline),
                        ),
                      ),
                    for (final n in doc.nodes)
                      _nodeMarker(
                        n,
                        scaleX: scaleX,
                        scaleY: scaleY,
                        stageW: w,
                        stageH: h,
                        scheme: scheme,
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
  }) {
    final mw = (n.w * scaleX).clamp(16.0, stageW);
    final mh = (n.h * scaleY).clamp(16.0, stageH);
    final left =
        (n.x * scaleX).clamp(0.0, (stageW - mw).clamp(0.0, stageW));
    final top =
        (n.y * scaleY).clamp(0.0, (stageH - mh).clamp(0.0, stageH));
    final selected = n.id == _selectedNodeId;
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () => _selectNode(n.id),
        onPanUpdate: (details) {
          // Read latest position — closure [n] is stale mid-drag.
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
        child: Container(
          width: mw,
          height: mh,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2.5 : 1.5,
            ),
          ),
          child: Text(
            n.name.isNotEmpty ? n.name[0].toUpperCase() : '?',
            style: TextStyle(
              fontSize: (mw < 28 || mh < 28) ? 11 : 14,
              fontWeight: FontWeight.w600,
              color: selected
                  ? scheme.onPrimary
                  : scheme.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
