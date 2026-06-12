import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/project.dart';
import '../services/ffmpeg_service.dart';
import '../services/storage_service.dart';
import '../services/whisper_service.dart';

final storageServiceProvider = Provider<StorageService>((_) => StorageService());
final ffmpegServiceProvider = Provider<FfmpegService>((_) => FfmpegService());
final whisperServiceProvider = Provider<WhisperService>((_) => WhisperService());

class ProjectsNotifier extends AsyncNotifier<List<Project>> {
  @override
  Future<List<Project>> build() async {
    return ref.read(storageServiceProvider).loadProjects();
  }

  Future<void> add(Project project) async {
    final current = state.value ?? <Project>[];
    await _persist([...current, project]);
  }

  Future<void> save(Project project) async {
    final current = state.value ?? <Project>[];
    await _persist(current.map((p) => p.id == project.id ? project : p).toList());
  }

  Future<void> remove(String projectId) async {
    final current = state.value ?? <Project>[];
    await _persist(current.where((p) => p.id != projectId).toList());
  }

  Future<void> _persist(List<Project> list) async {
    state = AsyncData(list);
    await ref.read(storageServiceProvider).saveProjects(list);
  }
}

final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, List<Project>>(ProjectsNotifier.new);
