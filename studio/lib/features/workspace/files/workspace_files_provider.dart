import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_files_controller.dart';

/// One [WorkspaceFilesController] per project path.
final workspaceFilesControllerProvider = Provider.autoDispose
    .family<WorkspaceFilesController, String>((ref, projectPath) {
  final controller = WorkspaceFilesController(projectPath);
  ref.onDispose(controller.dispose);
  controller.refreshTree();
  return controller;
});
