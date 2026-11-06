import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'runtime_facade.dart';

enum _Py { unknown, missing, ready }

/// Replaces the old RuntimeTestScreen. Shows, separately:
///   Runtime: not initialized / ready
///   Python:  not checked / missing / ready (with version)
/// and lets you Initialize, Install Python and Re-check, with a bounded log.
class RuntimeDebugScreen extends ConsumerStatefulWidget {
  const RuntimeDebugScreen({super.key});

  @override
  ConsumerState<RuntimeDebugScreen> createState() => _RuntimeDebugScreenState();
}

class _RuntimeDebugScreenState extends ConsumerState<RuntimeDebugScreen> {
  static const int _maxLog = 20000;
  static const String _installCommand = 'pkg install python';

  bool _busy = false; // one operation at a time
  bool? _ready; // null = not checked yet
  _Py _py = _Py.unknown;
  String? _pythonVersion;
  double? _progress; // null = indeterminate
  String _progressText = '';
  String _log = '';

  RuntimeFacade get _facade => ref.read(runtimeFacadeProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recheck());
  }

  // ---------- helpers ----------

  void _append(String text) {
    if (!mounted) return;
    setState(() {
      final next = _log.isEmpty ? text : '$_log\n$text';
      _log = next.length > _maxLog ? next.substring(next.length - _maxLog) : next;
    });
  }

  String _tail(String s, int n) =>
      s.length <= n ? s : '…${s.substring(s.length - n)}';

  Future<void> _guard(String title, Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = null;
      _progressText = title;
    });
    _append('> $title');
    try {
      await body();
    } on TimeoutException {
      _append('Timed out.');
    } on PlatformException catch (e) {
      _append('Error: ${e.message ?? e.code}');
    } catch (e) {
      _append('Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _progressText = '';
        });
      }
    }
  }

  // ---------- operations ----------

  Future<void> _checkStatus() async {
    // probeStatus is filesystem-only (no proot). Second+ opens stay fast.
    final probe = await _facade.probeStatus();
    if (!mounted) return;
    setState(() {
      _ready = probe.ready;
      if (!probe.ready) {
        _py = _Py.unknown;
        _pythonVersion = null;
      } else if (probe.hasPython) {
        _py = _Py.ready;
        // Keep last known version string if we already fetched it once;
        // do not spawn proot just to refresh the label.
        _pythonVersion ??= 'python3';
      } else {
        _py = _Py.missing;
        _pythonVersion = null;
      }
    });
    if (probe.ready) {
      _append(
        probe.hasPython
            ? 'Runtime ready · python binary present'
            : 'Runtime ready · python binary missing',
      );
    } else {
      _append('Runtime not initialized');
    }
  }

  /// Optional: full proot python --version (slow). Only after install / explicit.
  Future<void> _checkPython() async {
    String? raw;
    try {
      raw = await _facade.pythonVersion();
    } catch (e) {
      _append('python check failed: $e');
    }
    if (!mounted) return;
    final v = raw;
    if (v != null && RegExp(r'\d+\.\d+').hasMatch(v)) {
      setState(() {
        _py = _Py.ready;
        _pythonVersion = v;
      });
      _append(v);
    } else {
      setState(() {
        _py = _Py.missing;
        _pythonVersion = null;
      });
      _append('python3 not found in the runtime.');
    }
  }

  Future<void> _recheck() => _guard('Check status', _checkStatus);

  Future<void> _initialize() => _guard('Initialize runtime', () async {
        await _facade.initialize(onProgress: (message, fraction) {
          if (!mounted) return;
          setState(() {
            _progressText = message;
            _progress = fraction;
          });
        });
        _append('Runtime initialized.');
        await _checkStatus();
      });

  Future<void> _installPython() => _guard('Install Python', () async {
        final r = await _facade.installPackages(const ['python']);
        _append(_tail(r.output.trim(), 4000));
        if (!r.ok) {
          _append('Install failed (exit ${r.exitCode}).');
          return;
        }
        _append('Install finished.');
        await _checkPython();
      });

  // ---------- UI ----------

  String get _headline {
    if (_ready == null) return 'Checking…';
    if (_ready == false) return 'Runtime not initialized';
    switch (_py) {
      case _Py.ready:
        return 'Runtime ready · ${_pythonVersion ?? 'Python ready'}';
      case _Py.missing:
        return 'Runtime ready · Python missing';
      case _Py.unknown:
        return 'Runtime ready · Python not checked';
    }
  }

  Widget _statusRow(IconData icon, Color color, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Expanded(child: Text(value, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final grey = Theme.of(context).disabledColor;
    final runtimeRow = _ready == null
        ? _statusRow(Icons.help_outline, grey, 'Runtime', 'checking')
        : _ready!
            ? _statusRow(Icons.check_circle, Colors.green, 'Runtime', 'ready')
            : _statusRow(Icons.cancel, Colors.orange, 'Runtime', 'not initialized');
    final pythonRow = switch (_py) {
      _Py.ready => _statusRow(
          Icons.check_circle, Colors.green, 'Python', _pythonVersion ?? 'ready'),
      _Py.missing =>
        _statusRow(Icons.cancel, Colors.orange, 'Python', 'missing'),
      _Py.unknown => _statusRow(
          Icons.help_outline,
          grey,
          'Python',
          _ready == true ? 'not checked' : 'needs the runtime first',
        ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_headline, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            runtimeRow,
            pythonRow,
          ],
        ),
      ),
    );
  }

  Widget _manualCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Install Python runs:'),
                  SizedBox(height: 4),
                  SelectableText(
                    _installCommand,
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Copy command',
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () =>
                  Clipboard.setData(const ClipboardData(text: _installCommand)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Log', style: Theme.of(context).textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Copy log',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: _log.isEmpty
                      ? null
                      : () => Clipboard.setData(ClipboardData(text: _log)),
                ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _log.isEmpty ? null : () => setState(() => _log = ''),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 120),
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SelectableText(
                  _log.isEmpty ? 'No output yet.' : _log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canInstall = !_busy && _ready == true && _py != _Py.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('Runtime')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(),
          const SizedBox(height: 12),
          if (_busy) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 4),
            Text(_progressText, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: (_busy || _ready == true) ? null : _initialize,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Initialize'),
              ),
              FilledButton.tonalIcon(
                onPressed: canInstall ? _installPython : null,
                icon: const Icon(Icons.download),
                label: const Text('Install Python'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _recheck,
                icon: const Icon(Icons.refresh),
                label: const Text('Re-check'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _manualCard(),
          const SizedBox(height: 12),
          _logCard(),
        ],
      ),
    );
  }
}
