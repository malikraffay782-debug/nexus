import '../../../services/embedded_runtime.dart';
import '../../projects/domain/project.dart';

class RunResult {
  const RunResult({
    required this.ok,
    required this.message,
    this.exitCode,
    this.timedOut = false,
  });

  final bool ok;
  final String message;
  final int? exitCode;
  final bool timedOut;
}

/// Runs project entry: python3 /home/project/src/main.py (cwd /home/project).
class ProjectRunner {
  const ProjectRunner();

  Future<RunResult> run(Project project) async {
    try {
      final ready = await EmbeddedRuntime.isReady();
      if (!ready) {
        return const RunResult(
          ok: false,
          message:
              'Runtime not initialized. Open the Runtime tab and tap Initialize first.',
        );
      }

      final result = await EmbeddedRuntime.runProject(
        project.id,
        timeoutSec: 30,
      );

      final stdout = result.stdout;
      final stderr = result.stderr;
      final output = stderr.isEmpty
          ? stdout
          : (stdout.isEmpty ? stderr : '$stdout\n$stderr').trim();

      if (result.timedOut) {
        return RunResult(
          ok: false,
          message: output.isEmpty
              ? 'Timed out after 30s'
              : '$output\n\n[Timed out after 30s]',
          exitCode: result.exitCode,
          timedOut: true,
        );
      }

      if (result.exitCode == 127) {
        return RunResult(
          ok: false,
          message:
              'python3 is not installed in the runtime.\nInstall it from the Runtime tab: pkg install python\n\n$output',
          exitCode: 127,
        );
      }

      if (result.exitCode == 0) {
        return RunResult(
          ok: true,
          message: output.isEmpty ? '(no output)' : output,
          exitCode: 0,
        );
      }

      // Native ProjectMount errors come as stderr with exit -1
      final err = result.stderr.trim();
      if (err.contains('src/main.py not found') ||
          err.contains('Project folder') ||
          err.contains('Invalid project')) {
        return RunResult(ok: false, message: err, exitCode: result.exitCode);
      }

      return RunResult(
        ok: false,
        message: output.isEmpty
            ? 'Script exited with code ${result.exitCode}'
            : output,
        exitCode: result.exitCode,
      );
    } catch (e) {
      return RunResult(ok: false, message: e.toString());
    }
  }
}
