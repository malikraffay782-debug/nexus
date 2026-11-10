import 'package:flutter/material.dart';

import '../files/workspace_paths.dart';
import '../scene/scene_model.dart';
import '../scene/scene_service.dart';

/// Scene tab: list/create scenes + node placeholders (no engine yet).
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

  @override
  void initState() {
    super.initState();
    _service = SceneService(widget.projectPath);
    _reload();
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
    // Simple grid placement so nodes don't all stack at 0,0
    final col = n % 4;
    final row = n ~/ 4;
    final node = SceneNode(
      id: 'n_${DateTime.now().microsecondsSinceEpoch}',
      type: 'sprite',
      name: 'Node ${n + 1}',
      x: 80.0 + col * 120,
      y: 80.0 + row * 120,
    );
    setState(() {
      _doc = doc.withNodeAdded(node);
      _selectedNodeId = node.id;
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
        // Scene file strip
        Material(
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
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          ),
        Expanded(
          child: _doc == null
              ? _emptyScenes(scheme)
              : Row(
                  children: [
                    // Node list sidebar
                    SizedBox(
                      width: 160,
                      child: Material(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 10, 4, 4),
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
                            if (_selectedNodeId != null)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: OutlinedButton.icon(
                                  onPressed: _removeSelectedNode,
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  label: const Text('Remove'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildCanvas(scheme)),
                  ],
                ),
        ),
      ],
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
            '${n.type} · (${n.x.toInt()}, ${n.y.toInt()})',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          onTap: () => setState(() => _selectedNodeId = n.id),
        );
      },
    );
  }

  Widget _buildCanvas(ColorScheme scheme) {
    final doc = _doc!;
    return LayoutBuilder(
      builder: (context, constraints) {
        const pad = 16.0;
        final maxW = constraints.maxWidth - pad * 2;
        final maxH = constraints.maxHeight - pad * 2 - 28;
        final aspect = doc.width / doc.height;
        double w = maxW;
        double h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
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
              const SizedBox(height: 8),
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
                      Positioned(
                        left: (n.x * scaleX).clamp(0, w - 36),
                        top: (n.y * scaleY).clamp(0, h - 36),
                        child: GestureDetector(
                          onTap: () => setState(() => _selectedNodeId = n.id),
                          child: Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: n.id == _selectedNodeId
                                  ? scheme.primary
                                  : scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: n.id == _selectedNodeId
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              n.name.isNotEmpty ? n.name[0].toUpperCase() : '?',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: n.id == _selectedNodeId
                                    ? scheme.onPrimary
                                    : scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
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
}
