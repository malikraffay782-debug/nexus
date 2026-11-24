import 'package:flutter/material.dart';

import '../scene/scene_model.dart';

/// Desktop/wide layout node list with reorder controls.
class SceneNodeList extends StatelessWidget {
  const SceneNodeList({
    super.key,
    required this.scheme,
    required this.nodes,
    required this.selectedId,
    required this.onSelect,
    required this.onReorder,
  });

  final ColorScheme scheme;
  final List<SceneNode> nodes;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final void Function(String id, int delta) onReorder;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
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
      itemCount: nodes.length,
      itemBuilder: (context, i) {
        final n = nodes[i];
        final selected = n.id == selectedId;
        final last = i == nodes.length - 1;
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          title: Text(
            n.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            '${n.type} · ${n.w.toInt()}×${n.h.toInt()}'
            '${n.hasPoints ? ' · poly' : ''}'
            '${SceneMeshes.normalize(n.mesh).isNotEmpty ? ' · ${n.mesh}' : ''}',
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
                onPressed: i == 0 ? null : () => onReorder(n.id, -1),
              ),
              IconButton(
                tooltip: 'Bring forward',
                icon: const Icon(Icons.arrow_upward, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: last ? null : () => onReorder(n.id, 1),
              ),
            ],
          ),
          onTap: () => onSelect(n.id),
        );
      },
    );
  }
}
