import 'dart:io';

import '../../../services/embedded_runtime.dart';
import '../../projects/domain/project.dart';

class RunResult {
  const RunResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

class ProjectRunner {
  const ProjectRunner();

  Future<RunResult> run(Project project) async {
    try {
      final dir = Directory(project.path);
      if (!await dir.exists()) {
        return const RunResult(
          ok: false,
          message: 'Project folder is missing on disk.',
        );
      }

      final ready = await EmbeddedRuntime.isReady();
      if (!ready) {
        return const RunResult(
          ok: false,
          message:
              'Runtime not initialized. Open the Runtime tab and tap Initialize first.',
        );
      }

      final quotedName = _shellQuote(project.name);
      // Guest cwd: proot maps /home; project is on Android FS — for Phase 1
      // we only echo; later bind-mount project.path when running real code.
      final cmd = 'echo hello from $quotedName';
      final result = await EmbeddedRuntime.runCommand(
        cmd,
        // Host path is not a guest path; keep default guest /home until bind-mount
        timeoutSec: 30,
      );

      if (result.isSuccess) {
        return RunResult(
          ok: true,
          message: result.stdout.isEmpty ? '(no output)' : result.stdout,
        );
      }
      return RunResult(
        ok: false,
        message: 'ERROR(${result.exitCode}): ${result.stderr}'.trim(),
      );
    } catch (e) {
      return RunResult(ok: false, message: e.toString());
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
