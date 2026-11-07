import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../projects/application/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../widgets/run_guard.dart';
import '../run/run_gateway.dart';
import '../run/run_session.dart';
import '../run/run_session_controller.dart';
import '../widgets/run_output_panel.dart';
import '../files/workspace_files_provider.dart';
import '../widgets/workspace_code_tab.dart';

class WorkspaceScreen extends ConsumerStatefulWidget {
  const WorkspaceScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends ConsumerState<WorkspaceScreen> {
  ProviderSubscription<AsyncValue<Project?>>? _sub;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    // Subscribe once — not on every rebuild
    _sub = ref.listenManual<AsyncValue<Project?>>(
      projectByIdProvider(widget.projectId),
      (prev, next) {
        next.whenData((project) {
          if (project == null && mounted && !_left) {
            _left = true;
            context.go('/projects');
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(projectByIdProvider(widget.projectId));
    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$e', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => context.go('/projects'),
                  child: const Text('Back to projects'),
                ),
              ],
            ),
          ),
        ),
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


class _WorkspaceView extends ConsumerStatefulWidget {
  const _WorkspaceView({required this.project});

  final Project project;

  @override
  ConsumerState<_WorkspaceView> createState() => _WorkspaceViewState();
}

class _WorkspaceViewState extends ConsumerState<_WorkspaceView> {
  late final RunSessionController _runCtrl;

  bool get _isGame => widget.project.type == ProjectType.game;

  @override
  void initState() {
    super.initState();
    _runCtrl = RunSessionController(const DefaultRunGateway());
    _runCtrl.addListener(_onRunChanged);
  }

  void _onRunChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _runCtrl.removeListener(_onRunChanged);
    // Best-effort: cancel in-flight proot when leaving workspace.
    _runCtrl.detach();
    _runCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    // Sync busy check — controller also guards; this avoids opening the
    // unsaved dialog twice on double-tap.
    if (_runCtrl.state.phase.isBusy) return;

    final files =
        ref.read(workspaceFilesControllerProvider(widget.project.path));
    final proceed = await confirmRunWithUnsavedChanges(context, files);
    if (!proceed || !mounted) return;
    if (_runCtrl.state.phase.isBusy) return;

    await _runCtrl.run(widget.project.id, timeoutSec: 60);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final files = ref.watch(workspaceFilesControllerProvider(project.path));
    final runState = _runCtrl.state;
    final busy = runState.phase.isBusy;
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
              child: runState.phase == RunPhase.running ||
                      runState.phase == RunPhase.starting
                  ? FilledButton.tonalIcon(
                      onPressed: () => _runCtrl.stop(),
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    )
                  : FilledButton.icon(
                      onPressed: busy ? null : _run,
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(busy ? 'Running…' : 'Run'),
                    ),
            ),
          ],
          bottom: TabBar(
            tabs: [for (final t in tabs) Tab(text: t.label)],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  for (final t in tabs)
                    if (t.label == 'Code')
                      WorkspaceCodeTab(controller: files)
                    else
                      _Placeholder(icon: t.icon, title: t.label, hint: t.hint),
                ],
              ),
            ),
            if (runState.phase != RunPhase.idle)
              RunOutputPanel(
                state: runState,
                onStop: () => _runCtrl.stop(),
                onClose: () {
                  // Only allow close when not busy
                  if (!runState.phase.isBusy) {
                    _runCtrl.detach();
                  }
                },
              ),
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
