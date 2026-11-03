import 'package:flutter/material.dart';

import '../files/workspace_files_controller.dart';

enum RunGuardChoice { saveAndRun, runWithoutSaving, cancel }

/// Call before starting a project Run. Returns true if Run may proceed.
///
///   if (!await confirmRunWithUnsavedChanges(context, files)) return;
///
/// Run always executes what is on disk, so with unsaved edits the user must
/// choose: Save and Run, Run without saving (disk version), or Cancel.
Future<bool> confirmRunWithUnsavedChanges(
  BuildContext context,
  WorkspaceFilesController controller,
) async {
  if (!controller.dirty) return true;

  final messenger = ScaffoldMessenger.of(context);
  final fileName = controller.openPath?.split('/').last ?? 'the open file';

  final choice = await showDialog<RunGuardChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: Text(
        '"$fileName" has changes that are not saved. '
        'Run uses the version saved on disk.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(RunGuardChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(RunGuardChoice.runWithoutSaving),
          child: const Text('Run without saving'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(RunGuardChoice.saveAndRun),
          child: const Text('Save and Run'),
        ),
      ],
    ),
  );

  if (choice == RunGuardChoice.runWithoutSaving) return true;
  if (choice != RunGuardChoice.saveAndRun) return false; // cancel / dismissed

  final err = await controller.save();
  if (err != null) {
    messenger.showSnackBar(SnackBar(content: Text('Save failed: $err')));
    return false;
  }
  if (controller.dirty) {
    // Another save was in flight, or the user kept typing: do not run stale.
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not save the latest changes. Try again.')),
    );
    return false;
  }
  return true;
}
