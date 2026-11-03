import 'package:flutter/material.dart';

import '../files/workspace_files_controller.dart';
import 'code_editor_panel.dart';
import 'file_tree_panel.dart';

/// Code tab. The controller is owned by the caller (see
/// workspaceFilesControllerProvider) so WorkspaceScreen can check unsaved
/// changes before Run. This widget never disposes it.
///
/// Wide screens: tree on the left, editor on the right.
/// Phones: editor full screen, "Files" button opens the tree in a sheet.
class WorkspaceCodeTab extends StatefulWidget {
  const WorkspaceCodeTab({super.key, required this.controller});

  final WorkspaceFilesController controller;

  @override
  State<WorkspaceCodeTab> createState() => _WorkspaceCodeTabState();
}

class _WorkspaceCodeTabState extends State<WorkspaceCodeTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // keep scroll/selection when switching tabs

  void _showFiles() {
    final controller = widget.controller;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: FileTreePanel(
          controller: controller,
          onFileOpened: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 720) {
          return Row(
            children: [
              SizedBox(
                width: 260,
                child: FileTreePanel(controller: controller),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: CodeEditorPanel(controller: controller)),
            ],
          );
        }
        return CodeEditorPanel(
          controller: controller,
          onShowFiles: _showFiles,
        );
      },
    );
  }
}
