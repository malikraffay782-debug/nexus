import 'dart:convert';

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
  final List<Map<String, dynamic>> nodes;

  Map<String, dynamic> toJson() => {
        'version': version,
        'name': name,
        'width': width,
        'height': height,
        'nodes': nodes,
      };

  factory SceneDoc.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'];
    return SceneDoc(
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: json['name'] as String? ?? 'untitled',
      width: (json['width'] as num?)?.toInt() ?? 720,
      height: (json['height'] as num?)?.toInt() ?? 1280,
      nodes: rawNodes is List
          ? rawNodes.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const [],
    );
  }

  static SceneDoc empty(String name) => SceneDoc(name: name);

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
