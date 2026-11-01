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

  /// Absolute folder path — derived from disk, not stored in project.json.
  final String path;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> json, {required String path}) {
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      type: ProjectType.fromName(json['type'] as String?),
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      path: path,
    );
  }
}
