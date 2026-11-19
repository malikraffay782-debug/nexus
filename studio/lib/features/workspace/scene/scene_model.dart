import 'dart:convert';
import 'dart:math' as math;

/// Known node types for the 2D stage (extensible later).
class SceneNodeTypes {
  static const sprite = 'sprite';
  static const camera = 'camera';
  static const List<String> all = [sprite, camera];

  static String normalize(String? raw) {
    final t = (raw ?? sprite).trim().toLowerCase();
    return all.contains(t) ? t : sprite;
  }
}

/// Default palette (ARGB ints). UI uses Color(argb).
class ScenePalette {
  static const List<int> colors = [
    0xFF7C4DFF, // purple
    0xFF42A5F5, // blue
    0xFF66BB6A, // green
    0xFFFFCA28, // amber
    0xFFEF5350, // red
    0xFF26C6DA, // cyan
    0xFFFF7043, // deep orange
    0xFFBDBDBD, // grey (cameras default)
  ];

  static int forType(String type) =>
      type == SceneNodeTypes.camera ? colors.last : colors.first;
}

/// Built-in mesh ids that map to samples/cpp GameAssets.hpp makers.
/// Empty / unknown = no mesh (rect/poly only).
class SceneMeshes {
  static const none = '';
  static const sword = 'sword';
  static const crate = 'crate';
  static const chest = 'chest';
  static const metalcase = 'metalcase';

  static const List<String> all = [none, sword, crate, chest, metalcase];

  static String normalize(String? raw) {
    final t = (raw ?? '').trim().toLowerCase();
    return all.contains(t) ? t : none;
  }

  static String label(String id) {
    switch (normalize(id)) {
      case sword:
        return 'Sword';
      case crate:
        return 'Crate';
      case chest:
        return 'Chest';
      case metalcase:
        return 'Metal case';
      default:
        return 'None';
    }
  }
}

/// One vertex in scene space (used when a node is in points/edit mode).
class ScenePoint {
  const ScenePoint(this.x, this.y);

  final double x;
  final double y;

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory ScenePoint.fromJson(Map<String, dynamic> json) {
    return ScenePoint(
      (json['x'] as num?)?.toDouble() ?? 0,
      (json['y'] as num?)?.toDouble() ?? 0,
    );
  }

  ScenePoint copyWith({double? x, double? y}) =>
      ScenePoint(x ?? this.x, y ?? this.y);
}

/// One node in a scene. Painted on the 2D stage; no game loop yet.
///
/// When [points] is null the node is an axis-aligned rect (x,y,w,h).
/// When [points] is set it is a freeform polygon; x/y/w/h stay the
/// bounding box for list/sidebar and coarse drag.
///
/// 3D foundation (additive, backward-compatible):
/// - [z] depth in scene units (default 0). Used later for sort / projection.
/// - [fov] / [near] / [far] are meaningful on camera nodes; sprites ignore them
///   in the 2D painter but still persist for future 3D run path.
class SceneNode {
  const SceneNode({
    required this.id,
    required this.type,
    required this.name,
    required this.x,
    required this.y,
    this.z = defaultZ,
    this.zDepth = defaultZDepth,
    this.w = 64,
    this.h = 64,
    this.color = 0xFF7C4DFF,
    this.points,
    this.mesh = '',
    this.fov = defaultFov,
    this.near = defaultNear,
    this.far = defaultFar,
  });

  static const double defaultZ = 0;
  /// Zero = flat plane (legacy). >0 = AABB thickness along Z around [z].
  static const double defaultZDepth = 0;
  static const double defaultFov = 60;
  static const double defaultNear = 0.1;
  static const double defaultFar = 1000;

  final String id;
  final String type;
  final String name;
  final double x;
  final double y;
  /// Depth (scene units). Default 0 keeps existing 2D behaviour.
  final double z;
  /// Z-thickness for 3D AABB. 0 = flat at [z]; >0 → [z − d/2, z + d/2].
  final double zDepth;
  final double w;
  final double h;
  /// ARGB packed color for stage paint.
  final int color;
  /// Optional polygon vertices in scene space. Null = rect node.
  final List<ScenePoint>? points;
  /// Optional GameAssets mesh id (sword/crate/chest/metalcase). Empty = none.
  final String mesh;
  /// Vertical field of view in degrees (camera nodes).
  final double fov;
  /// Near clip plane (camera nodes).
  final double near;
  /// Far clip plane (camera nodes).
  final double far;

  bool get hasPoints => points != null && points!.length >= 3;

  bool get isCamera => type == SceneNodeTypes.camera;

  /// Four corners of the current rect (scene space), TL→TR→BR→BL.
  List<ScenePoint> rectAsPoints() {
    return [
      ScenePoint(x, y),
      ScenePoint(x + w, y),
      ScenePoint(x + w, y + h),
      ScenePoint(x, y + h),
    ];
  }

  /// Bounding box from points (or current rect if none).
  static (double x, double y, double w, double h) boundsOf(
    List<ScenePoint> pts,
  ) {
    if (pts.isEmpty) return (0, 0, 64, 64);
    var minX = pts.first.x;
    var minY = pts.first.y;
    var maxX = pts.first.x;
    var maxY = pts.first.y;
    for (final p in pts) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
    final bw = (maxX - minX).clamp(24.0, 4096.0);
    final bh = (maxY - minY).clamp(24.0, 4096.0);
    return (minX, minY, bw, bh);
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'type': type,
      'name': name,
      'x': x,
      'y': y,
      'w': w,
      'h': h,
      'color': color,
    };
    // 3D foundation — always write so Python / future run path can read them.
    map['z'] = z;
    if (zDepth != defaultZDepth) map['zDepth'] = zDepth;
    if (isCamera || fov != defaultFov) map['fov'] = fov;
    if (isCamera || near != defaultNear) map['near'] = near;
    if (isCamera || far != defaultFar) map['far'] = far;
    if (points != null && points!.isNotEmpty) {
      map['points'] = points!.map((p) => p.toJson()).toList();
    }
    final meshId = SceneMeshes.normalize(mesh);
    if (meshId.isNotEmpty) map['mesh'] = meshId;
    return map;
  }

  factory SceneNode.fromJson(Map<String, dynamic> json) {
    final type = SceneNodeTypes.normalize(json['type'] as String?);
    final rawColor = json['color'];
    int color;
    if (rawColor is int) {
      color = rawColor;
    } else if (rawColor is num) {
      color = rawColor.toInt();
    } else {
      color = ScenePalette.forType(type);
    }
    List<ScenePoint>? points;
    final rawPts = json['points'];
    if (rawPts is List && rawPts.isNotEmpty) {
      points = [];
      for (final e in rawPts) {
        if (e is Map) {
          points.add(ScenePoint.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      if (points.length < 3) points = null;
    }
    final rawId = (json['id'] as String?)?.trim() ?? '';
    final px = (json['x'] as num?)?.toDouble() ?? 0;
    final py = (json['y'] as num?)?.toDouble() ?? 0;
    final pz = (json['z'] as num?)?.toDouble() ?? defaultZ;
    final rawZd = (json['zDepth'] as num?)?.toDouble() ?? defaultZDepth;
    final zDepth = rawZd.isFinite && rawZd > 0 ? rawZd : defaultZDepth;
    final fov = (json['fov'] as num?)?.toDouble() ?? defaultFov;
    // Clamp near/far so invariant always holds: near > 0 and far > near.
    // Hand-edited or corrupt JSON must not produce invalid cameras.
    var near = (json['near'] as num?)?.toDouble() ?? defaultNear;
    var far = (json['far'] as num?)?.toDouble() ?? defaultFar;
    if (!(near > 0)) near = defaultNear;
    if (!(far > near)) far = near < defaultFar ? defaultFar : near + 1.0;
    final mesh = SceneMeshes.normalize(json['mesh'] as String?);
    // Empty id → unique per decode (position alone collides for stacked nodes).
    final id = rawId.isEmpty
        ? 'n_${DateTime.now().microsecondsSinceEpoch}_${_nextFallbackId()}'
        : rawId;
    return SceneNode(
      id: id,
      type: type,
      name: json['name'] as String? ?? 'node',
      x: px,
      y: py,
      z: pz,
      zDepth: zDepth,
      w: (json['w'] as num?)?.toDouble() ?? 64,
      h: (json['h'] as num?)?.toDouble() ?? 64,
      color: color,
      points: points,
      mesh: mesh,
      fov: fov.clamp(1.0, 179.0),
      near: near,
      far: far,
    );
  }

  static int _fallbackIdSeq = 0;

  static int _nextFallbackId() {
    _fallbackIdSeq = (_fallbackIdSeq + 1) & 0x7fffffff;
    return _fallbackIdSeq;
  }

  SceneNode copyWith({
    String? id,
    String? type,
    String? name,
    double? x,
    double? y,
    double? z,
    double? zDepth,
    double? w,
    double? h,
    int? color,
    List<ScenePoint>? points,
    bool clearPoints = false,
    String? mesh,
    double? fov,
    double? near,
    double? far,
  }) {
    return SceneNode(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      x: x ?? this.x,
      y: y ?? this.y,
      z: z ?? this.z,
      zDepth: zDepth ?? this.zDepth,
      w: w ?? this.w,
      h: h ?? this.h,
      color: color ?? this.color,
      points: clearPoints ? null : (points ?? this.points),
      mesh: mesh ?? this.mesh,
      fov: fov ?? this.fov,
      near: near ?? this.near,
      far: far ?? this.far,
    );
  }
}

/// Scene document: stage size + nodes + editor flags.
class SceneDoc {
  const SceneDoc({
    required this.name,
    this.version = 1,
    this.width = 720,
    this.height = 1280,
    this.nodes = const [],
    this.showGrid = true,
  });

  final int version;
  final String name;
  final int width;
  final int height;
  final List<SceneNode> nodes;
  final bool showGrid;

  Map<String, dynamic> toJson() => {
        'version': version,
        'name': name,
        'width': width,
        'height': height,
        'showGrid': showGrid,
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
    // Force unique ids if a hand-edited JSON reused the same id twice.
    final seen = <String>{};
    final unique = <SceneNode>[];
    for (final n in nodes) {
      if (seen.add(n.id)) {
        unique.add(n);
      } else {
        unique.add(
          n.copyWith(
            id: 'n_${DateTime.now().microsecondsSinceEpoch}_${SceneNode._nextFallbackId()}',
          ),
        );
      }
    }
    return SceneDoc(
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: json['name'] as String? ?? 'untitled',
      width: (json['width'] as num?)?.toInt() ?? 720,
      height: (json['height'] as num?)?.toInt() ?? 1280,
      showGrid: json['showGrid'] as bool? ?? true,
      nodes: unique,
    );
  }

  static SceneDoc empty(String name) => SceneDoc(name: name);

  SceneDoc copyWith({
    int? version,
    String? name,
    int? width,
    int? height,
    List<SceneNode>? nodes,
    bool? showGrid,
  }) {
    return SceneDoc(
      version: version ?? this.version,
      name: name ?? this.name,
      width: width ?? this.width,
      height: height ?? this.height,
      nodes: nodes ?? this.nodes,
      showGrid: showGrid ?? this.showGrid,
    );
  }

  SceneDoc withNodeAdded(SceneNode node) =>
      copyWith(nodes: [...nodes, node]);

  SceneDoc withNodeRemoved(String id) =>
      copyWith(nodes: nodes.where((n) => n.id != id).toList());

  SceneDoc withNodeUpdated(SceneNode node) => copyWith(
        nodes: nodes.map((n) => n.id == node.id ? node : n).toList(),
      );

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
