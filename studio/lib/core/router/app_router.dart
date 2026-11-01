import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/projects/presentation/create_project_screen.dart';
import '../../features/projects/presentation/projects_screen.dart';
import '../../features/runtime_debug/runtime_debug_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/workspace/presentation/workspace_screen.dart';
import '../shell/app_shell.dart';

final GlobalKey<NavigatorState> _rootKey = GlobalKey<NavigatorState>();

final GoRouter appRouter = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/projects',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/projects',
            builder: (_, __) => const ProjectsScreen(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/create',
            builder: (_, __) => const CreateProjectScreen(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/runtime',
            builder: (_, __) => const RuntimeDebugScreen(),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
          ),
        ]),
      ],
    ),
    GoRoute(
      path: '/workspace/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, state) =>
          WorkspaceScreen(projectId: state.pathParameters['id']!),
    ),
  ],
);
