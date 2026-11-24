import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/files/workspace_paths.dart';

void main() {
  // Root is only used for containment; resolve validates the relative path shape.
  final paths = WorkspacePaths('/tmp/nexus_fake_project');

  test('rejects parent segments and absolute paths', () {
    expect(() => paths.resolve('../secret'), throwsA(isA<WorkspaceException>()));
    expect(() => paths.resolve('/etc/passwd'), throwsA(isA<WorkspaceException>()));
  });

  test('rejects empty segments and trailing slash', () {
    expect(() => paths.resolve('src//main.py'), throwsA(isA<WorkspaceException>()));
    expect(() => paths.resolve('src/main.py/'), throwsA(isA<WorkspaceException>()));
  });

  test('rejects bad characters and deep paths', () {
    expect(() => paths.resolve('src/foo*.py'), throwsA(isA<WorkspaceException>()));
    final deep = List.filled(WorkspacePaths.maxDepth + 2, 'a').join('/');
    // first segment must be a top dir
    expect(
      () => paths.resolve('src/$deep'),
      throwsA(isA<WorkspaceException>()),
    );
  });

  test('allows topDirs and controlled root files only', () {
    for (final top in WorkspacePaths.topDirs) {
      expect(paths.resolve('$top/file.txt'), contains('/$top/file.txt'));
    }
    for (final root in WorkspacePaths.rootFiles) {
      expect(paths.resolve(root), endsWith('/$root'));
    }
    expect(() => paths.resolve('README.txt'), throwsA(isA<WorkspaceException>()));
    expect(() => paths.resolve('secret.md'), throwsA(isA<WorkspaceException>()));
  });
}
