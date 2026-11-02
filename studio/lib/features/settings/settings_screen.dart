import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../projects/application/projects_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Nexus'),
            subtitle: Text('Studio shell + Embedded Runtime · Phase 1'),
          ),
        ],
      ),
    );
  }
}
