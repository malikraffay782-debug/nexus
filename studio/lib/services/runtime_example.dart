import 'package:flutter/material.dart';
import 'embedded_runtime.dart';

/// Simple example screen to test the Embedded Runtime.
/// Add this route temporarily for debugging.
class RuntimeTestScreen extends StatefulWidget {
  const RuntimeTestScreen({super.key});

  @override
  State<RuntimeTestScreen> createState() => _RuntimeTestScreenState();
}

class _RuntimeTestScreenState extends State<RuntimeTestScreen> {
  String _log = 'Press Initialize to start...\n';
  bool _busy = false;

  void _append(String msg) {
    setState(() {
      _log += '$msg\n';
    });
  }

  Future<void> _initialize() async {
    setState(() => _busy = true);
    _append('→ Initializing runtime...');
    final result = await EmbeddedRuntime.initialize();
    if (result.success) {
      _append('✓ Runtime ready');
      _append('Prefix: ${await EmbeddedRuntime.getPrefixPath()}');
    } else {
      _append('✗ Failed: ${result.error}');
    }
    setState(() => _busy = false);
  }

  Future<void> _runSmokeTests() async {
    setState(() => _busy = true);
    _append('\n→ Running smoke tests...');

    final tests = [
      'uname -a',
      'python3 --version',
      'ls /bin | head -n 10',
      'echo \$PREFIX',
      'whoami',
    ];

    for (final cmd in tests) {
      _append('\n\$ $cmd');
      final res = await EmbeddedRuntime.runCommand(cmd);
      if (res.isSuccess) {
        _append(res.stdout);
      } else {
        _append('FAILED (${res.exitCode}): ${res.stderr}');
      }
    }

    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nexus Runtime Test')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _initialize,
                  child: const Text('Initialize'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _busy ? null : _runSmokeTests,
                  child: const Text('Smoke Tests'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}