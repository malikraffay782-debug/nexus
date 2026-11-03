import 'package:flutter/material.dart';

import '../files/workspace_file_service.dart';
import '../files/workspace_files_controller.dart';

/// Asks whether unsaved changes may be thrown away.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: const Text('Discard your changes to the open file?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep editing'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class FileTreePanel extends StatelessWidget {
  const FileTreePanel({
    super.key,
    required this.controller,
    this.onFileOpened,
  });

  final WorkspaceFilesController controller;

  /// Called after a file was opened (used to close the bottom sheet on phones).
  final VoidCallback? onFileOpened;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Files',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: controller.refreshTree,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(context)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final entries = controller.visibleEntries;
    if (controller.loadingTree && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.treeError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(controller.treeError!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.refreshTree,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (entries.isEmpty) {
      return const Center(child: Text('No files yet'));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) => _row(context, entries[i]),
    );
  }

  Widget _row(BuildContext context, WorkspaceEntry e) {
    final selected = !e.isDir && e.relPath == controller.openPath;
    final collapsed = controller.isCollapsed(e.relPath);

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      minLeadingWidth: 24,
      contentPadding: EdgeInsets.only(left: 12.0 + e.depth * 16.0, right: 4),
      leading: Icon(
        e.isDir
            ? (collapsed ? Icons.folder : Icons.folder_open)
            : Icons.description_outlined,
        size: 20,
      ),
      title: Text(e.name, overflow: TextOverflow.ellipsis),
      trailing: e.isDir
          ? PopupMenuButton<String>(
              tooltip: 'New',
              icon: const Icon(Icons.add, size: 20),
              onSelected: (v) =>
                  _create(context, e.relPath, isFolder: v == 'folder'),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'file', child: Text('New file')),
                PopupMenuItem(value: 'folder', child: Text('New folder')),
              ],
            )
          : IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _delete(context, e),
            ),
      onTap: () {
        if (e.isDir) {
          controller.toggleCollapsed(e.relPath);
        } else {
          _open(context, e.relPath);
        }
      },
    );
  }

  Future<void> _open(BuildContext context, String rel) async {
    final messenger = ScaffoldMessenger.of(context);
    if (controller.openPath == rel) {
      onFileOpened?.call();
      return;
    }
    if (controller.dirty && !await confirmDiscardChanges(context)) return;
    final err = await controller.openFile(rel);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else {
      onFileOpened?.call();
    }
  }

  Future<void> _create(
    BuildContext context,
    String parentRel, {
    required bool isFolder,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: isFolder ? 'New folder' : 'New file',
        hint: isFolder ? 'folder_name' : 'main.py',
      ),
    );
    if (name == null || name.isEmpty) return;

    final result = isFolder
        ? await controller.createFolder(parentRel, name)
        : await controller.createFile(parentRel, name);
    if (!result.ok) {
      messenger.showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    if (isFolder) return;

    // Open the new file; ask first if the current one has unsaved edits.
    if (!context.mounted) return;
    if (controller.dirty && !await confirmDiscardChanges(context)) return;
    final err = await controller.openFile(result.relPath!);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else {
      onFileOpened?.call();
    }
  }

  Future<void> _delete(BuildContext context, WorkspaceEntry e) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('"${e.name}" will be deleted. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await controller.deleteFile(e.relPath);
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    }
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.hint});
  final String title;
  final String hint;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
