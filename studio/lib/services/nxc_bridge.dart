import 'embedded_runtime.dart';

/// Thin read-only bridge to Nexus Coin (NXC) one-shot CLI.
///
/// Uses existing proot [EmbeddedRuntime.runCommand] — no new MethodChannel,
/// no mining, no background node. Binary must be on PATH inside the runtime
/// as `nexus-coin` (on-demand install later).
///
/// Low-end: short timeouts, no allocations beyond the command result.
class NxcBridge {
  NxcBridge._();

  /// Default data port used by nexus-coin file names (nexus_<port>_*.).
  static const int defaultPort = 7001;

  static const String _bin = 'nexus-coin';

  /// True if `nexus-coin` is present in the embedded runtime.
  static Future<bool> isAvailable() => EmbeddedRuntime.hasBinary(_bin);

  /// Wallet address for [port] (creates key file if missing when binary runs).
  static Future<NxcQueryResult> address({int port = defaultPort}) {
    return _query(['address', '$port'], port: port);
  }

  /// Balance in NXC for [address] or the local wallet if null.
  static Future<NxcQueryResult> balance({
    int port = defaultPort,
    String? address,
  }) {
    final args = <String>['balance', '$port'];
    if (address != null && address.isNotEmpty) args.add(address);
    return _query(args, port: port);
  }

  /// Chain height and tip hash: stdout like `12 abcd...`.
  static Future<NxcQueryResult> height({int port = defaultPort}) {
    return _query(['height', '$port'], port: port);
  }

  static Future<NxcQueryResult> _query(
    List<String> args, {
    required int port,
  }) async {
    final available = await isAvailable();
    if (!available) {
      return NxcQueryResult(
        ok: false,
        value: '',
        error: 'nexus-coin not installed in runtime',
        port: port,
      );
    }

    // Shell-escape: only digits/hex-safe args from our callers; still quote.
    final cmd = StringBuffer(_bin);
    for (final a in args) {
      cmd.write(' ');
      cmd.write(_shellSingleQuote(a));
    }

    final result = await EmbeddedRuntime.runCommand(
      cmd.toString(),
      timeoutSec: 15,
    );

    if (result.timedOut) {
      return NxcQueryResult(
        ok: false,
        value: '',
        error: 'timed out',
        port: port,
      );
    }
    if (result.exitCode != 0) {
      final err = result.stderr.trim().isNotEmpty
          ? result.stderr.trim()
          : 'exit ${result.exitCode}';
      return NxcQueryResult(
        ok: false,
        value: result.stdout.trim(),
        error: err,
        port: port,
      );
    }

    return NxcQueryResult(
      ok: true,
      value: result.stdout.trim(),
      error: null,
      port: port,
    );
  }

  static String _shellSingleQuote(String s) {
    return "'${s.replaceAll("'", "'\\''")}'";
  }
}

class NxcQueryResult {
  const NxcQueryResult({
    required this.ok,
    required this.value,
    required this.port,
    this.error,
  });

  final bool ok;
  final String value;
  final String? error;
  final int port;
}
