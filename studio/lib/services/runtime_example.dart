import 'dart:async';
import 'package:flutter/material.dart';
import 'embedded_runtime.dart';

/// Debug / test screen for the Embedded Runtime.
class RuntimeTestScreen extends StatefulWidget {
  const RuntimeTestScreen({super.key});

  @override
  State<RuntimeTestScreen> createState() => _RuntimeTestScreenState();
}

class _RuntimeTestScreenState extends State<RuntimeTestScreen> {
  String _log = 'Ready.\n';
  bool _busy = false;
  int _progress = 0;
  String _progressMsg = '';
  StreamSubscription? _progressSub;

  @override
  void initState() {
    super.initState();
    _progressSub = EmbeddedRuntime.progressStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _progress = p.percent;
        _progressMsg = p.message;
      });
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _append(String msg) {
    if (!mounted) return;
    setState(() => _log += '$msg\n');
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _progressMsg = 'Starting...';
    });
    _append('→ Initializing runtime...');

    try {
      final result = await EmbeddedRuntime.initialize();
      if (!mounted) return;

      if (result.success) {
        _append('✓ Runtime ready');
        final prefix = await EmbeddedRuntime.getPrefixPath();
        if (mounted) _append('Prefix: $prefix');
      } else {
        _append('✗ Failed: ${result.error}');
      }
    } catch (e) {
      _append('✗ Exception: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runSmokeTests() async {
    if (!mounted) return;
    setState(() => _busy = true);
    _append('\n→ Smoke tests...');

    final tests = [
      'uname -a',
      'python3 --version',
      'ls /bin | head -n 8',
      'echo \$PREFIX',
      'whoami',
      'id',
    ];

    try {
      for (final cmd in tests) {
        if (!mounted) return;
        _append('\n\$ $cmd');
        final res = await EmbeddedRuntime.runCommand(cmd);
        if (!mounted) return;
        if (res.isSuccess) {
          _append(res.stdout);
        } else {
          _append('FAILED (${res.exitCode}): ${res.stderr}');
        }
      }
    } catch (e) {
      _append('✗ Exception: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nexus Runtime Test')),
      body: Column(
        children: [
          if (_busy || (_progress > 0 && _progress < 100))
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: _progress / 100),
                  const SizedBox(height: 6),
                  Text('$_progress%  $_progressMsg', style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 10,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _initialize,
                  child: const Text('Initialize'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _runSmokeTests,
                  child: const Text('Smoke Tests'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
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
