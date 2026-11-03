import 'package:flutter/material.dart';

import '../files/workspace_files_controller.dart';
import 'code_editor_panel.dart';
import 'file_tree_panel.dart';

/// Drop-in replacement for the Code placeholder tab.
///
///   WorkspaceCodeTab(projectPath: project.path)
///
/// Wide screens: tree on the left, editor on the right.
/// Phones: editor full screen, "Files" button opens the tree in a sheet.
class WorkspaceCodeTab extends StatefulWidget {
  const WorkspaceCodeTab({super.key, required this.projectPath});

  final String projectPath;

  @override
  State<WorkspaceCodeTab> createState() => _WorkspaceCodeTabState();
}

class _WorkspaceCodeTabState extends State<WorkspaceCodeTab>
    with AutomaticKeepAliveClientMixin {
  late WorkspaceFilesController _controller;

  @override
  bool get wantKeepAlive => true; // keep open file + edits when switching tabs

  @override
  void initState() {
    super.initState();
    _controller = WorkspaceFilesController(widget.projectPath);
    _controller.refreshTree();
  }

  @override
  void didUpdateWidget(covariant WorkspaceCodeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectPath != widget.projectPath) {
      _controller.dispose();
      _controller = WorkspaceFilesController(widget.projectPath);
      _controller.refreshTree();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showFiles() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: FileTreePanel(
          controller: _controller,
          onFileOpened: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 720) {
          return Row(
            children: [
              SizedBox(
                width: 260,
                child: FileTreePanel(controller: _controller),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: CodeEditorPanel(controller: _controller)),
            ],
          );
        }
        return CodeEditorPanel(
          controller: _controller,
          onShowFiles: _showFiles,
        );
      },
    );
  }
}
