import '../../../services/embedded_runtime.dart';
import '../../projects/domain/project.dart';

class RunResult {
  const RunResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

/// Single integration point between Studio shell and EmbeddedRuntime.
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

      final quotedName = _shellQuote(project.name);
      final cmd = 'echo hello from $quotedName';
      final result = await EmbeddedRuntime.runCommand(cmd);
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
