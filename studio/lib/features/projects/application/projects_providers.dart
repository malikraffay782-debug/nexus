import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/project_repository.dart';
import '../domain/project.dart';

final projectRepositoryProvider =
    Provider<ProjectRepository>((ref) => ProjectRepository());

class ProjectsController extends AsyncNotifier<List<Project>> {
  ProjectRepository get _repo => ref.read(projectRepositoryProvider);

  @override
  Future<List<Project>> build() => _repo.list();

  Future<Project> create({
    required String name,
    required ProjectType type,
  }) async {
    final project = await _repo.create(name: name, type: type);
    state = AsyncData(await _repo.list());
    return project;
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncData(await _repo.list());
    // Invalidate workspace lookup for this id
    ref.invalidate(projectByIdProvider(id));
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
