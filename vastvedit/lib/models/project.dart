class Clip {
  final String id;
  final String filePath;
  final String name;

  const Clip({required this.id, required this.filePath, required this.name});

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'name': name,
      };

  factory Clip.fromJson(Map<String, dynamic> json) => Clip(
        id: json['id'] as String,
        filePath: json['filePath'] as String,
        name: json['name'] as String,
      );

  Clip copyWith({String? name}) => Clip(id: id, filePath: filePath, name: name ?? this.name);
}

class Project {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<Clip> clips;

  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.clips,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'clips': clips.map((c) => c.toJson()).toList(),
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        clips: (json['clips'] as List<dynamic>)
            .map((c) => Clip.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  Project copyWith({String? name, List<Clip>? clips}) => Project(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        clips: clips ?? this.clips,
      );
}
