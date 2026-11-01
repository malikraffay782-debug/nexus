enum ProjectType {
  game,
  app;

  String get label => this == ProjectType.game ? 'Game' : 'App';

  static ProjectType fromName(String? name) => ProjectType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => ProjectType.app,
      );
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> json, {required String path}) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('project.json: missing or invalid id');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('project.json: missing or invalid name');
    }
    final createdRaw = json['createdAt'];
    final createdAt = createdRaw is String
        ? (DateTime.tryParse(createdRaw)?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(0);

    return Project(
      id: id.trim(),
      name: name.trim(),
      type: ProjectType.fromName(json['type'] as String?),
      createdAt: createdAt,
      path: path,
    );
  }

  /// Shared validation for create / rename.
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
