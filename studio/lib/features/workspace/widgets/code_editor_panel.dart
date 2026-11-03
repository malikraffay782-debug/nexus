import 'package:flutter/material.dart';

import '../files/workspace_files_controller.dart';

class CodeEditorPanel extends StatelessWidget {
  const CodeEditorPanel({
    super.key,
    required this.controller,
    this.onShowFiles,
  });

  final WorkspaceFilesController controller;

  /// When set (phone layout), shows a "Files" button in the toolbar.
  final VoidCallback? onShowFiles;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final path = controller.openPath;
        return Column(
          children: [
            _toolbar(context, path),
            if (controller.opening)
              const LinearProgressIndicator(minHeight: 2)
            else
              const Divider(height: 1),
            Expanded(
              child: path == null ? _empty(context) : _editor(context),
            ),
          ],
        );
      },
    );
  }

  Widget _toolbar(BuildContext context, String? path) {
    final name = path?.split('/').last;
    final canSave = path != null && controller.dirty && !controller.saving;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          if (onShowFiles != null)
            IconButton(
              tooltip: 'Files',
              icon: const Icon(Icons.folder_open),
              onPressed: onShowFiles,
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: onShowFiles == null ? 12 : 0),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      name ?? 'Code',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (path != null && controller.dirty)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message: 'Unsaved changes',
                        child: Icon(Icons.circle, size: 10, color: Colors.orange),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (path != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: canSave ? () => _save(context) : null,
                icon: controller.saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save, size: 18),
                label: const Text('Save'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.code, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Open a file from the file tree to start editing.',
              textAlign: TextAlign.center,
            ),
            if (onShowFiles != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onShowFiles,
                icon: const Icon(Icons.folder_open),
                label: const Text('Browse files'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _editor(BuildContext context) {
    return TextField(
      controller: controller.text,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 14,
        height: 1.4,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(12),
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final err = await controller.save();
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    }
  }
}
