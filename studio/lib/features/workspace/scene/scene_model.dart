import 'dart:convert';

/// One node in a scene. Placeholder only — no renderer yet.
class SceneNode {
  const SceneNode({
    required this.id,
    required this.type,
    required this.name,
    required this.x,
    required this.y,
  });

  final String id;
  final String type;
  final String name;
  final double x;
  final double y;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'x': x,
        'y': y,
      };

  factory SceneNode.fromJson(Map<String, dynamic> json) {
    return SceneNode(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'sprite',
      name: json['name'] as String? ?? 'node',
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
    );
  }

  SceneNode copyWith({
    String? id,
    String? type,
    String? name,
    double? x,
    double? y,
  }) {
    return SceneNode(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }
}

/// Minimal scene document. No rendering engine yet — structure only.
class SceneDoc {
  const SceneDoc({
    required this.name,
    this.version = 1,
    this.width = 720,
    this.height = 1280,
    this.nodes = const [],
  });

  final int version;
  final String name;
  final int width;
  final int height;
  final List<SceneNode> nodes;

  Map<String, dynamic> toJson() => {
        'version': version,
        'name': name,
        'width': width,
        'height': height,
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };

  factory SceneDoc.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'];
    final nodes = <SceneNode>[];
    if (rawNodes is List) {
      for (final e in rawNodes) {
        if (e is Map) {
          nodes.add(SceneNode.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    return SceneDoc(
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: json['name'] as String? ?? 'untitled',
      width: (json['width'] as num?)?.toInt() ?? 720,
      height: (json['height'] as num?)?.toInt() ?? 1280,
      nodes: nodes,
    );
  }

  static SceneDoc empty(String name) => SceneDoc(name: name);

  SceneDoc copyWith({
    int? version,
    String? name,
    int? width,
    int? height,
    List<SceneNode>? nodes,
  }) {
    return SceneDoc(
      version: version ?? this.version,
      name: name ?? this.name,
      width: width ?? this.width,
      height: height ?? this.height,
      nodes: nodes ?? this.nodes,
    );
  }

  SceneDoc withNodeAdded(SceneNode node) =>
      copyWith(nodes: [...nodes, node]);

  SceneDoc withNodeRemoved(String id) =>
      copyWith(nodes: nodes.where((n) => n.id != id).toList());

  String encodePretty() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  static SceneDoc decode(String text) {
    final map = jsonDecode(text);
    if (map is! Map) {
      throw const FormatException('Scene root must be a JSON object');
    }
    return SceneDoc.fromJson(Map<String, dynamic>.from(map));
  }
}
