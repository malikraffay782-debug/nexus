import 'package:flutter/material.dart';

import '../files/workspace_paths.dart';
import '../scene/scene_model.dart';
import '../scene/scene_service.dart';

/// Minimal Scene tab: list/create scenes + empty canvas (no engine yet).
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
    setState(() {
      _selected = name;
      _error = null;
      _loading = true;
    });
    try {
      final doc = await _service.load(name);
      if (!mounted) return;
      setState(() {
        _doc = doc;
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

  Future<void> _createScene() async {
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
                IconButton(
                  tooltip: 'New scene',
                  onPressed: _createScene,
                  icon: const Icon(Icons.add),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _reload,
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
        Expanded(child: _buildCanvas(scheme)),
      ],
    );
  }

  Widget _buildCanvas(ColorScheme scheme) {
    final doc = _doc;
    if (doc == null) {
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

    return LayoutBuilder(
      builder: (context, constraints) {
        // Fit scene aspect into available space with padding.
        const pad = 24.0;
        final maxW = constraints.maxWidth - pad * 2;
        final maxH = constraints.maxHeight - pad * 2;
        final aspect = doc.width / doc.height;
        double w = maxW;
        double h = w / aspect;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${doc.name}  ·  ${doc.width}×${doc.height}  ·  ${doc.nodes.length} nodes',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              const SizedBox(height: 12),
              Container(
                width: w,
                height: h,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  doc.nodes.isEmpty ? 'Empty stage' : '${doc.nodes.length} nodes',
                  style: TextStyle(color: scheme.outline),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
