import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';

final projectRepositoryProvider =
    Provider<ProjectRepository>((ref) => ProjectRepository());

class ProjectsController extends AsyncNotifier<List<Project>> {
  ProjectRepository get _repo => ref.read(projectRepositoryProvider);

  // Serialize mutations so concurrent create/delete don't stomp list state
  Future<void> _chain = Future.value();

  Future<T> _serialized<T>(Future<T> Function() fn) {
    final next = _chain.then((_) => fn());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<List<Project>> build() => _repo.list();

  Future<Project> create({
    required String name,
    required ProjectType type,
  }) {
    return _serialized(() async {
      final project = await _repo.create(name: name, type: type);
      state = AsyncData(await _repo.list());
      return project;
    });
  }

  Future<void> delete(String id) {
    return _serialized(() async {
      await _repo.delete(id);
      state = AsyncData(await _repo.list());
      ref.invalidate(projectByIdProvider(id));
    });
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_repo.list);
  }
}

final projectsProvider =
    AsyncNotifierProvider<ProjectsController, List<Project>>(
  ProjectsController.new,
);

final projectByIdProvider =
    FutureProvider.family<Project?, String>((ref, id) {
  return ref.watch(projectRepositoryProvider).getById(id);
});

final projectsRootPathProvider = FutureProvider<String>((ref) {
  return ref.watch(projectRepositoryProvider).rootPath();
});
