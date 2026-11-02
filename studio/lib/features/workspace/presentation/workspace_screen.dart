import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../projects/application/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../application/project_runner.dart';

class WorkspaceScreen extends ConsumerWidget {
  const WorkspaceScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectByIdProvider(projectId));
    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (project) {
        if (project == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Project')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This project no longer exists.'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => context.go('/projects'),
                      child: const Text('Back to projects'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return _WorkspaceView(project: project);
      },
    );
  }
}

class _WorkspaceView extends StatefulWidget {
  const _WorkspaceView({required this.project});

  final Project project;

  @override
  State<_WorkspaceView> createState() => _WorkspaceViewState();
}

class _WorkspaceViewState extends State<_WorkspaceView> {
  bool _running = false;

  bool get _isGame => widget.project.type == ProjectType.game;

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final result = await const ProjectRunner().run(widget.project);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(result.ok ? 'Run: ${widget.project.name}' : 'Runtime issue'),
          content: SingleChildScrollView(
            child: SelectableText(
              result.message.isEmpty ? '(no output)' : result.message,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final tabs = <({String label, IconData icon, String hint})>[
      _isGame
          ? (
              label: 'Scene',
              icon: Icons.landscape,
              hint: 'Scene editor goes here'
            )
          : (
              label: 'Screens',
              icon: Icons.view_quilt,
              hint: 'Screen designer goes here'
            ),
      (label: 'Code', icon: Icons.code, hint: 'Code editor goes here'),
      (
        label: 'Assets',
        icon: Icons.image_outlined,
        hint: 'Asset manager goes here'
      ),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(project.name, overflow: TextOverflow.ellipsis),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_running ? 'Running…' : 'Run'),
              ),
            ),
          ],
          bottom: TabBar(
            tabs: [for (final t in tabs) Tab(text: t.label)],
          ),
        ),
        body: TabBarView(
          children: [
            for (final t in tabs)
              _Placeholder(icon: t.icon, title: t.label, hint: t.hint),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(hint, style: TextStyle(color: scheme.outline)),
        ],
      ),
    );
  }
}
