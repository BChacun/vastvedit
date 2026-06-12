import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';
import '../providers/projects_provider.dart';
import 'home_screen.dart';

// ── Processing state ──────────────────────────────────────────────────────────

enum _Stage { idle, processing, done, error }

class _ProcessingState {
  final _Stage stage;
  final double progress;
  final String statusMsg;
  final List<String> logs;
  final String? outputPath;

  const _ProcessingState({
    this.stage = _Stage.idle,
    this.progress = 0,
    this.statusMsg = '',
    this.logs = const [],
    this.outputPath,
  });

  _ProcessingState copyWith({
    _Stage? stage,
    double? progress,
    String? statusMsg,
    List<String>? logs,
    String? outputPath,
  }) =>
      _ProcessingState(
        stage: stage ?? this.stage,
        progress: progress ?? this.progress,
        statusMsg: statusMsg ?? this.statusMsg,
        logs: logs ?? this.logs,
        outputPath: outputPath ?? this.outputPath,
      );
}

// ── Screen ────────────────────────────────────────────────────────────────────

class ProjectScreen extends ConsumerStatefulWidget {
  final String projectId;
  const ProjectScreen({super.key, required this.projectId});

  @override
  ConsumerState<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends ConsumerState<ProjectScreen> {
  // Settings
  double _silenceThreshold = -30.0;
  double _minSilenceDuration = 0.5;
  double _padding = 0.1;

  // Cached durations (clipId → seconds)
  final Map<String, double> _durations = {};

  // Processing
  _ProcessingState _proc = const _ProcessingState();
  final ScrollController _logScroll = ScrollController();

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Project? get _project {
    final list = ref.read(projectsProvider).value;
    if (list == null) return null;
    try {
      return list.firstWhere((p) => p.id == widget.projectId);
    } catch (_) {
      return null;
    }
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      _proc = _proc.copyWith(logs: [..._proc.logs, msg]);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void _loadDuration(Clip clip) async {
    if (_durations.containsKey(clip.id)) return;
    try {
      final ff = ref.read(ffmpegServiceProvider);
      final d = await ff.getVideoDuration(clip.filePath);
      if (mounted) setState(() => _durations[clip.id] = d);
    } catch (_) {}
  }

  // ── Project mutations ──────────────────────────────────────────────────────

  Future<void> _importVideos() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'avi', 'mkv', 'm4v', 'webm'],
      allowMultiple: true,
      dialogTitle: 'Select video files',
    );
    if (result == null || result.files.isEmpty) return;

    final project = _project;
    if (project == null) return;

    final newClips = result.files
        .where((f) => f.path != null)
        .map((f) => Clip(
              id: const Uuid().v4(),
              filePath: f.path!,
              name: f.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
            ))
        .toList();

    await ref.read(projectsProvider.notifier).save(
          project.copyWith(clips: [...project.clips, ...newClips]),
        );
  }

  Future<void> _removeClip(Clip clip) async {
    final project = _project;
    if (project == null) return;
    final clips = project.clips.where((c) => c.id != clip.id).toList();
    await ref.read(projectsProvider.notifier).save(project.copyWith(clips: clips));
  }

  Future<void> _reorderClips(int oldIndex, int newIndex) async {
    final project = _project;
    if (project == null) return;
    final clips = [...project.clips];
    if (newIndex > oldIndex) newIndex -= 1;
    final item = clips.removeAt(oldIndex);
    clips.insert(newIndex, item);
    await ref.read(projectsProvider.notifier).save(project.copyWith(clips: clips));
  }

  Future<void> _renameProject() async {
    final project = _project;
    if (project == null) return;
    final controller = TextEditingController(text: project.name);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Rename project', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          autofocus: true,
          decoration: const InputDecoration(
            enabledBorder:
                UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
            focusedBorder:
                UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Rename', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == project.name) return;
    await ref.read(projectsProvider.notifier).save(project.copyWith(name: name.trim()));
  }

  // ── Processing ─────────────────────────────────────────────────────────────

  Future<void> _processAndExport() async {
    final project = _project;
    if (project == null || project.clips.isEmpty) {
      _showSnack('Add at least one clip before exporting.');
      return;
    }

    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save rough cut',
      fileName: '${project.name.replaceAll(RegExp(r'[^\w\s-]'), '_')}_rough_cut.mp4',
      type: FileType.custom,
      allowedExtensions: ['mp4'],
    );
    if (outputPath == null) return;

    setState(() {
      _proc = const _ProcessingState(stage: _Stage.processing, statusMsg: 'Starting…');
    });

    try {
      final ffmpeg = ref.read(ffmpegServiceProvider);
      await ffmpeg.processProject(
        project: project,
        outputPath: outputPath,
        silenceThreshold: _silenceThreshold,
        minSilenceDuration: _minSilenceDuration,
        padding: _padding,
        onLog: _log,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _proc = _proc.copyWith(
              progress: p,
              statusMsg: p < 0.86 ? 'Processing clips…' : 'Stitching…',
            );
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _proc = _proc.copyWith(
          stage: _Stage.done,
          progress: 1.0,
          statusMsg: 'Export complete!',
          outputPath: outputPath,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _proc = _proc.copyWith(
          stage: _Stage.error,
          statusMsg: 'Error: $e',
        );
      });
      _log('ERROR: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.surface2),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(projectsProvider);
    final project = async.value?.cast<Project?>().firstWhere(
          (p) => p?.id == widget.projectId,
          orElse: () => null,
        );

    if (project == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Kick off duration loads
    for (final clip in project.clips) {
      _loadDuration(clip);
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 16),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: GestureDetector(
          onTap: _renameProject,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(project.name,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined, color: AppColors.muted, size: 14),
            ],
          ),
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Left: clip list ──────────────────────────────────────────────
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ClipListHeader(
                  count: project.clips.length,
                  onImport: _processAndExport.runtimeType == _processAndExport.runtimeType
                      ? _importVideos
                      : null,
                ),
                Expanded(child: _buildClipList(project)),
              ],
            ),
          ),

          // ── Divider ──────────────────────────────────────────────────────
          const VerticalDivider(width: 1, color: AppColors.border),

          // ── Right: settings + output ──────────────────────────────────────
          SizedBox(
            width: 320,
            child: _RightPanel(
              silenceThreshold: _silenceThreshold,
              minSilenceDuration: _minSilenceDuration,
              padding: _padding,
              onThresholdChanged: (v) => setState(() => _silenceThreshold = v),
              onMinDurationChanged: (v) => setState(() => _minSilenceDuration = v),
              onPaddingChanged: (v) => setState(() => _padding = v),
              proc: _proc,
              onExport: _proc.stage == _Stage.processing ? null : _processAndExport,
              onReset: () => setState(() => _proc = const _ProcessingState()),
              logScroll: _logScroll,
              clipCount: project.clips.length,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipList(Project project) {
    if (project.clips.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_outlined, size: 56, color: AppColors.muted),
            const SizedBox(height: 12),
            const Text('No clips yet', style: TextStyle(color: AppColors.muted, fontSize: 16)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Import Videos'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: _importVideos,
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      onReorder: _reorderClips,
      itemCount: project.clips.length,
      proxyDecorator: (child, index, animation) => Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
        elevation: 6,
        child: child,
      ),
      itemBuilder: (_, i) {
        final clip = project.clips[i];
        final exists = File(clip.filePath).existsSync();
        return _ClipTile(
          key: ValueKey(clip.id),
          clip: clip,
          index: i,
          duration: _durations[clip.id],
          fileExists: exists,
          onDelete: () => _removeClip(clip),
        );
      },
    );
  }
}

// ── Clip list header ──────────────────────────────────────────────────────────

class _ClipListHeader extends StatelessWidget {
  final int count;
  final VoidCallback? onImport;

  const _ClipListHeader({required this.count, this.onImport});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppColors.surface,
      child: Row(
        children: [
          Text(
            '$count clip${count == 1 ? '' : 's'}',
            style: const TextStyle(color: AppColors.subtle, fontSize: 13),
          ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Import Videos'),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            onPressed: onImport,
          ),
        ],
      ),
    );
  }
}

// ── Clip tile ─────────────────────────────────────────────────────────────────

class _ClipTile extends StatelessWidget {
  final Clip clip;
  final int index;
  final double? duration;
  final bool fileExists;
  final VoidCallback onDelete;

  const _ClipTile({
    required super.key,
    required this.clip,
    required this.index,
    required this.duration,
    required this.fileExists,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: fileExists ? AppColors.border : AppColors.danger.withAlpha(100),
        ),
      ),
      child: ListTile(
        dense: true,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.drag_handle, color: AppColors.muted, size: 18),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(color: AppColors.subtle, fontSize: 11),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              fileExists ? Icons.movie_outlined : Icons.broken_image_outlined,
              color: fileExists ? AppColors.accent : AppColors.danger,
              size: 18,
            ),
          ],
        ),
        title: Text(
          clip.name,
          style: TextStyle(
            color: fileExists ? Colors.white : AppColors.danger,
            fontSize: 13,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          fileExists
              ? (duration != null ? _fmtDuration(duration!) : clip.filePath.split('/').last)
              : 'File not found',
          style: TextStyle(
            color: fileExists ? AppColors.muted : AppColors.danger.withAlpha(180),
            fontSize: 11,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close, color: AppColors.muted, size: 16),
          tooltip: 'Remove clip',
          onPressed: onDelete,
        ),
      ),
    );
  }

  String _fmtDuration(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).toStringAsFixed(1);
    return '${m}m ${sec}s';
  }
}

// ── Right panel ───────────────────────────────────────────────────────────────

class _RightPanel extends StatelessWidget {
  final double silenceThreshold;
  final double minSilenceDuration;
  final double padding;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<double> onMinDurationChanged;
  final ValueChanged<double> onPaddingChanged;
  final _ProcessingState proc;
  final VoidCallback? onExport;
  final VoidCallback onReset;
  final ScrollController logScroll;
  final int clipCount;

  const _RightPanel({
    required this.silenceThreshold,
    required this.minSilenceDuration,
    required this.padding,
    required this.onThresholdChanged,
    required this.onMinDurationChanged,
    required this.onPaddingChanged,
    required this.proc,
    required this.onExport,
    required this.onReset,
    required this.logScroll,
    required this.clipCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section('Processing Settings'),
          _slider(
            label: 'Silence threshold',
            value: silenceThreshold,
            min: -60,
            max: -10,
            display: '${silenceThreshold.round()} dB',
            onChanged: onThresholdChanged,
          ),
          _slider(
            label: 'Min silence duration',
            value: minSilenceDuration,
            min: 0.1,
            max: 3.0,
            display: '${minSilenceDuration.toStringAsFixed(1)} s',
            onChanged: onMinDurationChanged,
          ),
          _slider(
            label: 'Context padding',
            value: padding,
            min: 0,
            max: 0.5,
            display: '${padding.toStringAsFixed(2)} s',
            onChanged: onPaddingChanged,
          ),
          const Divider(color: AppColors.border, height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              icon: proc.stage == _Stage.processing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.output),
              label: Text(proc.stage == _Stage.processing ? 'Processing…' : 'Process & Export'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.surface2,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: clipCount == 0 ? null : onExport,
            ),
          ),
          if (proc.stage != _Stage.idle) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _StatusArea(proc: proc, onReset: onReset),
            ),
          ],
          const Divider(color: AppColors.border, height: 24),
          _section('Log'),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: proc.logs.isEmpty
                  ? const Center(
                      child: Text(
                        'Processing log will appear here.',
                        style: TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    )
                  : ListView.builder(
                      controller: logScroll,
                      itemCount: proc.logs.length,
                      itemBuilder: (_, i) => Text(
                        proc.logs[i],
                        style: const TextStyle(
                          color: Color(0xFF88CC88),
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: const TextStyle(color: AppColors.subtle, fontSize: 12)),
                Text(display,
                    style: const TextStyle(
                        color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
            SliderTheme(
              data: const SliderThemeData(
                activeTrackColor: AppColors.accent,
                thumbColor: AppColors.accent,
                inactiveTrackColor: AppColors.border,
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(value: value, min: min, max: max, onChanged: onChanged),
            ),
          ],
        ),
      );
}

// ── Status area ───────────────────────────────────────────────────────────────

class _StatusArea extends StatelessWidget {
  final _ProcessingState proc;
  final VoidCallback onReset;

  const _StatusArea({required this.proc, required this.onReset});

  @override
  Widget build(BuildContext context) {
    final color = switch (proc.stage) {
      _Stage.done => AppColors.success,
      _Stage.error => AppColors.danger,
      _ => AppColors.accent,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: proc.progress,
          backgroundColor: AppColors.border,
          valueColor: AlwaysStoppedAnimation(color),
          minHeight: 4,
        ),
        const SizedBox(height: 6),
        Text(
          proc.statusMsg,
          style: TextStyle(color: color, fontSize: 12),
        ),
        if (proc.stage == _Stage.done && proc.outputPath != null) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => Process.run('open', ['-R', proc.outputPath!]),
            child: const Text(
              'Reveal in Finder',
              style: TextStyle(
                color: AppColors.accent,
                fontSize: 12,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onReset,
            child: const Text('Reset', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
        ],
        if (proc.stage == _Stage.error) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: onReset,
            child: const Text('Dismiss', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
        ],
      ],
    );
  }
}
