import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/embedded_runtime.dart';
import '../../services/nxc_bridge.dart';
import '../projects/application/projects_providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _ready = false;
  bool _hasPython = false;
  bool _hasCpp = false;
  bool _loadingProbe = true;
  bool _installingCpp = false;
  String? _statusNote;

  // NXC read-only status (no send/mine — avoids accidental fund movement)
  bool _nxcLoading = false;
  bool? _nxcAvailable;
  String? _nxcAddress;
  String? _nxcBalance;
  String? _nxcError;

  @override
  void initState() {
    super.initState();
    _refreshProbe();
  }

  Future<void> _refreshProbe() async {
    setState(() {
      _loadingProbe = true;
      _statusNote = null;
    });
    final probe = await EmbeddedRuntime.probeStatus();
    if (!mounted) return;
    setState(() {
      _ready = probe.ready;
      _hasPython = probe.hasPython;
      _hasCpp = probe.hasCpp;
      _loadingProbe = false;
      if (probe.error != null) {
        _statusNote = probe.error;
      }
    });
  }

  Future<void> _installCpp() async {
    if (_installingCpp) return;
    setState(() {
      _installingCpp = true;
      _statusNote = 'Downloading C++17 toolchain (clang)…';
    });
    final result = await EmbeddedRuntime.installCpp();
    if (!mounted) return;
    setState(() {
      _installingCpp = false;
      _statusNote = result.success
          ? 'C++17 toolchain installed.'
          : (result.error.isNotEmpty ? result.error : result.output);
    });
    await _refreshProbe();
  }

  Future<void> _refreshNxc() async {
    if (_nxcLoading) return;
    setState(() {
      _nxcLoading = true;
      _nxcError = null;
    });
    final available = await NxcBridge.isAvailable();
    if (!mounted) return;
    if (!available) {
      setState(() {
        _nxcAvailable = false;
        _nxcAddress = null;
        _nxcBalance = null;
        _nxcError = 'nexus-coin not installed in runtime';
        _nxcLoading = false;
      });
      return;
    }
    final addr = await NxcBridge.address();
    if (!mounted) return;
    final bal = await NxcBridge.balance();
    if (!mounted) return;
    setState(() {
      _nxcAvailable = true;
      _nxcAddress = addr.ok ? addr.value : null;
      _nxcBalance = bal.ok ? bal.value : null;
      if (!addr.ok || !bal.ok) {
        _nxcError = [addr.error, bal.error].whereType<String>().join('; ');
      }
      _nxcLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(projectsRootPathProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.dark_mode_outlined),
            title: Text('Theme'),
            subtitle: Text('Dark'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Projects folder'),
            subtitle: Text(root.when(
              data: (p) => p,
              loading: () => '…',
              error: (e, _) => 'Unavailable — $e',
            )),
            trailing: IconButton(
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(projectsRootPathProvider);
                ref.invalidate(projectsProvider);
              },
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Languages'),
            subtitle: Text(
              _loadingProbe
                  ? 'Checking runtime…'
                  : (_ready
                      ? 'Optional toolchains — install only what you need'
                      : 'Runtime not ready — open Runtime and Initialize first'),
            ),
            trailing: IconButton(
              tooltip: 'Refresh',
              onPressed: _loadingProbe ? null : _refreshProbe,
              icon: const Icon(Icons.refresh),
            ),
          ),
          _LanguageTile(
            title: 'Python 3',
            subtitle: _hasPython
                ? 'Installed — used for project Run'
                : 'Not installed — install from Runtime when needed',
            installed: _hasPython,
            busy: false,
            enabled: false, // existing Runtime flow; do not force here
            actionLabel: _hasPython ? 'Installed' : 'Via Runtime',
            onInstall: null,
          ),
          _LanguageTile(
            title: 'C++17 (clang++)',
            subtitle: _hasCpp
                ? 'Installed — compile headers / native samples'
                : 'Optional — download clang++ when you need C++ objects',
            installed: _hasCpp,
            busy: _installingCpp,
            enabled: _ready && !_hasCpp && !_installingCpp,
            actionLabel: _hasCpp
                ? 'Installed'
                : (_installingCpp ? 'Installing…' : 'Install'),
            onInstall: (_ready && !_hasCpp) ? _installCpp : null,
          ),
          if (_statusNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                _statusNote!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.currency_bitcoin),
            title: const Text('Nexus Coin (NXC)'),
            subtitle: Text(
              _nxcLoading
                  ? 'Checking…'
                  : (_nxcAvailable == true
                      ? 'Read-only · no send/mine from Settings'
                      : (_nxcError ?? 'Not installed — optional runtime binary')),
            ),
            trailing: IconButton(
              tooltip: 'Refresh NXC',
              onPressed: _nxcLoading ? null : _refreshNxc,
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (_nxcAvailable == true) ...[
            ListTile(
              dense: true,
              title: const Text('Address'),
              subtitle: Text(
                _nxcAddress ?? '—',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              dense: true,
              title: const Text('Balance'),
              subtitle: Text(
                _nxcBalance != null ? '$_nxcBalance NXC' : '—',
              ),
            ),
          ],
          if (_nxcError != null && _nxcAvailable != false)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _nxcError!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Nexus'),
            subtitle: Text(
              'Studio shell + Embedded Runtime · languages are optional',
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.title,
    required this.subtitle,
    required this.installed,
    required this.busy,
    required this.enabled,
    required this.actionLabel,
    required this.onInstall,
  });

  final String title;
  final String subtitle;
  final bool installed;
  final bool busy;
  final bool enabled;
  final String actionLabel;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        installed ? Icons.check_circle : Icons.cloud_download_outlined,
        color: installed ? scheme.primary : scheme.outline,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: busy
          ? const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (onInstall == null
              ? Text(
                  actionLabel,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                )
              : FilledButton.tonal(
                  onPressed: enabled ? onInstall : null,
                  child: Text(actionLabel),
                )),
    );
  }
}
