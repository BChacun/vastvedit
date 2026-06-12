import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/project.dart';

class StorageService {
  Future<File> get _projectsFile async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/vastvedit');
    await folder.create(recursive: true);
    return File('${folder.path}/projects.json');
  }

  Future<List<Project>> loadProjects() async {
    try {
      final file = await _projectsFile;
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProjects(List<Project> projects) async {
    final file = await _projectsFile;
    await file.writeAsString(jsonEncode(projects.map((p) => p.toJson()).toList()));
  }
}
