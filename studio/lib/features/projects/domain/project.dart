enum ProjectType {
  game,
  app;

  String get label => this == ProjectType.game ? 'Game' : 'App';

  /// Strict: unknown type is invalid (no silent default for manifests).
  static ProjectType? tryParse(String? name) {
    if (name == null) return null;
    for (final t in ProjectType.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

class Project {
  const Project({
    required this.id,
    required this.name,
    required this.type,
    required this.createdAt,
    required this.path,
  });

  final String id;
  final String name;
  final ProjectType type;
  final DateTime createdAt;
  final String path;

  static final idPattern = RegExp(r'^[a-zA-Z0-9_-]+$');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> json, {required String path}) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.trim().isEmpty || !idPattern.hasMatch(id.trim())) {
      throw const FormatException('project.json: missing or invalid id');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('project.json: missing or invalid name');
    }
    final type = ProjectType.tryParse(json['type'] as String?);
    if (type == null) {
      throw const FormatException('project.json: missing or invalid type');
    }
    final createdRaw = json['createdAt'];
    final createdAt = createdRaw is String
        ? (DateTime.tryParse(createdRaw)?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(0);

    return Project(
      id: id.trim(),
      name: name.trim(),
      type: type,
      createdAt: createdAt,
      path: path,
    );
  }

  Project copyWithPath(String newPath) => Project(
        id: id,
        name: name,
        type: type,
        createdAt: createdAt,
        path: newPath,
      );

  static String? validateName(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return 'Enter a name';
    if (s.length > 40) return 'Name too long';
    if (s == '.' || s == '..') return 'Invalid name';
    if (s.contains('/') || s.contains(r'\') || s.contains('\u0000')) {
      return 'Name cannot contain path characters';
    }
    return null;
  }
}
