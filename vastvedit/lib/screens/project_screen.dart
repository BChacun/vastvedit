import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';
import '../models/subtitle_options.dart';
import '../providers/projects_provider.dart';
import '../services/whisper_service.dart';
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
  // ── Silence settings ───────────────────────────────────────────────────────
  double _silenceThreshold = -30.0;
  double _minSilenceDuration = 0.5;
  double _padding = 0.1;

  // ── Subtitle settings ──────────────────────────────────────────────────────
  SubtitleOptions _subtitles = const SubtitleOptions();

  // ── Cached clip durations ──────────────────────────────────────────────────
  final Map<String, double> _durations = {};

  // ── Processing ─────────────────────────────────────────────────────────────
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
    setState(() => _proc = _proc.copyWith(logs: [..._proc.logs, msg]));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void _loadDuration(Clip clip) async {
    if (_durations.containsKey(clip.id)) return;
    try {
      final d = await ref.read(ffmpegServiceProvider).getVideoDuration(clip.filePath);
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
    await ref.read(projectsProvider.notifier).save(
          project.copyWith(clips: project.clips.where((c) => c.id != clip.id).toList()),
        );
  }

  Future<void> _reorderClips(int oldIndex, int newIndex) async {
    final project = _project;
    if (project == null) return;
    final clips = [...project.clips];
    if (newIndex > oldIndex) newIndex -= 1;
    clips.insert(newIndex, clips.removeAt(oldIndex));
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
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: AppColors.muted))),
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

  // ── Export ─────────────────────────────────────────────────────────────────

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
      final whisper = _subtitles.enabled ? ref.read(whisperServiceProvider) : null;

      await ffmpeg.processProject(
        project: project,
        outputPath: outputPath,
        silenceThreshold: _silenceThreshold,
        minSilenceDuration: _minSilenceDuration,
        padding: _padding,
        subtitles: _subtitles,
        whisperService: whisper,
        onLog: _log,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            final msg = p < 0.78
                ? 'Processing clips…'
                : p < 0.82
                    ? 'Stitching…'
                    : p < 0.92
                        ? 'Transcribing audio…'
                        : 'Burning subtitles…';
            _proc = _proc.copyWith(progress: p, statusMsg: msg);
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
      setState(() => _proc = _proc.copyWith(stage: _Stage.error, statusMsg: 'Error: $e'));
      _log('ERROR: $e');
    }
  }

  void _showSnack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.surface2));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectsProvider).value?.cast<Project?>().firstWhere(
          (p) => p?.id == widget.projectId,
          orElse: () => null,
        );

    if (project == null) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator()),
      );
    }

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
          // ── Clip list ──────────────────────────────────────────────────────
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ClipListHeader(count: project.clips.length, onImport: _importVideos),
                Expanded(child: _buildClipList(project)),
              ],
            ),
          ),

          const VerticalDivider(width: 1, color: AppColors.border),

          // ── Right panel ────────────────────────────────────────────────────
          SizedBox(
            width: 330,
            child: _RightPanel(
              // silence
              silenceThreshold: _silenceThreshold,
              minSilenceDuration: _minSilenceDuration,
              padding: _padding,
              onThresholdChanged: (v) => setState(() => _silenceThreshold = v),
              onMinDurationChanged: (v) => setState(() => _minSilenceDuration = v),
              onPaddingChanged: (v) => setState(() => _padding = v),
              // subtitles
              subtitles: _subtitles,
              onSubtitlesChanged: (s) => setState(() => _subtitles = s),
              whisperService: ref.read(whisperServiceProvider),
              // processing
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
                  backgroundColor: AppColors.accent, foregroundColor: Colors.white),
              onPressed: _importVideos,
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      onReorder: _reorderClips,
      proxyDecorator: (child, index, animation) => Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
        elevation: 6,
        child: child,
      ),
      itemCount: project.clips.length,
      itemBuilder: (_, i) {
        final clip = project.clips[i];
        return _ClipTile(
          key: ValueKey(clip.id),
          clip: clip,
          index: i,
          duration: _durations[clip.id],
          fileExists: File(clip.filePath).existsSync(),
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
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: AppColors.surface,
        child: Row(
          children: [
            Text('$count clip${count == 1 ? '' : 's'}',
                style: const TextStyle(color: AppColors.subtle, fontSize: 13)),
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
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: fileExists ? AppColors.border : AppColors.danger.withAlpha(100)),
        ),
        child: ListTile(
          dense: true,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.drag_handle, color: AppColors.muted, size: 18),
              const SizedBox(width: 8),
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                    color: AppColors.surface2, borderRadius: BorderRadius.circular(4)),
                child: Center(
                    child: Text('${index + 1}',
                        style: const TextStyle(color: AppColors.subtle, fontSize: 11))),
              ),
              const SizedBox(width: 10),
              Icon(
                fileExists ? Icons.movie_outlined : Icons.broken_image_outlined,
                color: fileExists ? AppColors.accent : AppColors.danger,
                size: 18,
              ),
            ],
          ),
          title: Text(clip.name,
              style:
                  TextStyle(color: fileExists ? Colors.white : AppColors.danger, fontSize: 13),
              overflow: TextOverflow.ellipsis),
          subtitle: Text(
            fileExists
                ? (duration != null ? _fmtDuration(duration!) : clip.filePath.split('/').last)
                : 'File not found',
            style: TextStyle(
                color: fileExists ? AppColors.muted : AppColors.danger.withAlpha(180),
                fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close, color: AppColors.muted, size: 16),
            tooltip: 'Remove clip',
            onPressed: onDelete,
          ),
        ),
      );

  String _fmtDuration(double s) =>
      '${(s ~/ 60)}m ${(s % 60).toStringAsFixed(1)}s';
}

// ── Right panel ───────────────────────────────────────────────────────────────

class _RightPanel extends StatefulWidget {
  final double silenceThreshold;
  final double minSilenceDuration;
  final double padding;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<double> onMinDurationChanged;
  final ValueChanged<double> onPaddingChanged;

  final SubtitleOptions subtitles;
  final ValueChanged<SubtitleOptions> onSubtitlesChanged;
  final WhisperService whisperService;

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
    required this.subtitles,
    required this.onSubtitlesChanged,
    required this.whisperService,
    required this.proc,
    required this.onExport,
    required this.onReset,
    required this.logScroll,
    required this.clipCount,
  });

  @override
  State<_RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<_RightPanel> {
  final ScrollController _settingsScroll = ScrollController();

  @override
  void dispose() {
    _settingsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Convenient shorthand so the body below can still read widget.* fields
    final w = widget;

    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Settings (scrollable, takes 3/5 of the panel height) ──────────
          Expanded(
            flex: 3,
            child: Scrollbar(
              controller: _settingsScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _settingsScroll,
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Silence settings ───────────────────────────────────────
                  _sectionHeader('Processing'),
                  _slider(
                    label: 'Silence threshold',
                    value: w.silenceThreshold,
                    min: -60,
                    max: -10,
                    display: '${w.silenceThreshold.round()} dB',
                    onChanged: w.onThresholdChanged,
                  ),
                  _slider(
                    label: 'Min silence duration',
                    value: w.minSilenceDuration,
                    min: 0.1,
                    max: 3.0,
                    display: '${w.minSilenceDuration.toStringAsFixed(1)} s',
                    onChanged: w.onMinDurationChanged,
                  ),
                  _slider(
                    label: 'Context padding',
                    value: w.padding,
                    min: 0,
                    max: 0.5,
                    display: '${w.padding.toStringAsFixed(2)} s',
                    onChanged: w.onPaddingChanged,
                  ),

                  const Divider(color: AppColors.border, height: 20),

                  // ── Subtitle panel ─────────────────────────────────────────
                  _SubtitlePanel(
                    options: w.subtitles,
                    onChanged: w.onSubtitlesChanged,
                    whisperService: w.whisperService,
                  ),

                  const Divider(color: AppColors.border, height: 20),

                  // ── Export button ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ElevatedButton.icon(
                      icon: w.proc.stage == _Stage.processing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.output),
                      label: Text(w.proc.stage == _Stage.processing
                          ? w.proc.statusMsg
                          : 'Process & Export'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.surface2,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: w.clipCount == 0 ? null : w.onExport,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── Status ─────────────────────────────────────────────────
                  if (w.proc.stage != _Stage.idle)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _StatusArea(proc: w.proc, onReset: w.onReset),
                    ),
                  const SizedBox(height: 16),
                ],
                ),   // Column
              ),     // SingleChildScrollView
            ),       // Scrollbar
          ),         // Expanded

          const Divider(color: AppColors.border, height: 1),

          // ── Log (takes remaining 2/5 of panel height) ─────────────────────
          _sectionHeader('Log'),
          Expanded(
            flex: 2,
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: w.proc.logs.isEmpty
                  ? const Center(
                      child: Text('Processing log will appear here.',
                          style: TextStyle(color: AppColors.muted, fontSize: 11)))
                  : ListView.builder(
                      controller: w.logScroll,
                      itemCount: w.proc.logs.length,
                      itemBuilder: (_, i) => Text(
                        w.proc.logs[i],
                        style: const TextStyle(
                            color: Color(0xFF88CC88), fontSize: 10, fontFamily: 'monospace'),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
              color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1),
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

// ── Subtitle panel ────────────────────────────────────────────────────────────

class _SubtitlePanel extends StatefulWidget {
  final SubtitleOptions options;
  final ValueChanged<SubtitleOptions> onChanged;
  final WhisperService whisperService;

  const _SubtitlePanel({
    required this.options,
    required this.onChanged,
    required this.whisperService,
  });

  @override
  State<_SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<_SubtitlePanel> {
  bool _expanded = false;
  // null = still checking, true = installed, false = not found
  bool? _whisperAvailable;

  SubtitleOptions get _o => widget.options;
  void _update(SubtitleOptions next) => widget.onChanged(next);

  static const _fontColors = {
    'White': Color(0xFFFFFFFF),
    'Yellow': Color(0xFFFFFF00),
    'Cyan': Color(0xFF00FFFF),
    'Black': Color(0xFF000000),
  };

  @override
  void initState() {
    super.initState();
    _checkWhisper();
  }

  Future<void> _checkWhisper() async {
    final available = await widget.whisperService.isAvailable;
    if (mounted) setState(() => _whisperAvailable = available);
  }

  // Called when the user flips the subtitle toggle ON.
  Future<void> _onToggleOn() async {
    // If we already know it's installed, just enable.
    if (_whisperAvailable == true) {
      _update(_o.copyWith(enabled: true));
      setState(() => _expanded = true);
      return;
    }

    // Still checking — wait for the result first.
    if (_whisperAvailable == null) {
      final available = await widget.whisperService.isAvailable;
      if (mounted) setState(() => _whisperAvailable = available);
      if (available) {
        _update(_o.copyWith(enabled: true));
        if (mounted) setState(() => _expanded = true);
        return;
      }
    }

    // Not installed — show install dialog.
    if (!mounted) return;
    final installed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WhisperInstallDialog(service: widget.whisperService),
    );

    if (installed == true && mounted) {
      setState(() {
        _whisperAvailable = true;
        _expanded = true;
      });
      _update(_o.copyWith(enabled: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final checking = _whisperAvailable == null;
    final notInstalled = _whisperAvailable == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header row ───────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text(
                'SUBTITLES',
                style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1),
              ),
              const SizedBox(width: 6),

              // Whisper status badge
              if (checking)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.muted),
                )
              else if (notInstalled)
                Tooltip(
                  message: 'openai-whisper not installed — toggle on to install',
                  child: Icon(Icons.warning_amber_rounded,
                      size: 14, color: AppColors.warning),
                )
              else if (_whisperAvailable == true)
                Tooltip(
                  message: 'openai-whisper is installed',
                  child: Icon(Icons.check_circle_outline,
                      size: 14, color: AppColors.success),
                ),

              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.75,
                child: Switch(
                  value: _o.enabled,
                  onChanged: (v) {
                    if (v) {
                      _onToggleOn();
                    } else {
                      _update(_o.copyWith(enabled: false));
                    }
                  },
                  activeThumbColor: AppColors.accent,
                ),
              ),
              const Spacer(),
              if (_o.enabled)
                IconButton(
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.muted,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
        ),

        // ── Expanded settings ─────────────────────────────────────────────
        if (_o.enabled && _expanded) ...[
          const SizedBox(height: 8),

          _row(
            label: 'Language',
            child: _segmented(
              values: SubtitleLanguage.values,
              current: _o.language,
              label: (l) => l.label,
              onSelect: (l) => _update(_o.copyWith(language: l)),
            ),
          ),

          const SizedBox(height: 10),

          _row(
            label: 'Model',
            child: DropdownButton<WhisperModel>(
              value: _o.model,
              dropdownColor: AppColors.surface2,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              underline: const SizedBox(),
              isDense: true,
              onChanged: (m) => m != null ? _update(_o.copyWith(model: m)) : null,
              items: WhisperModel.values
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(m.label,
                                style: const TextStyle(color: Colors.white, fontSize: 12)),
                            Text(m.description,
                                style: const TextStyle(color: AppColors.muted, fontSize: 10)),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('STYLE',
                style: TextStyle(
                    color: AppColors.border,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
          ),

          // Font size
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Font size',
                        style: TextStyle(color: AppColors.subtle, fontSize: 12)),
                    Text('${_o.style.fontSize.round()} pt',
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
                  child: Slider(
                    value: _o.style.fontSize,
                    min: 14,
                    max: 56,
                    divisions: 21,
                    onChanged: (v) =>
                        _update(_o.copyWith(style: _o.style.copyWith(fontSize: v))),
                  ),
                ),
              ],
            ),
          ),

          // Font color
          _row(
            label: 'Font color',
            child: Row(
              children: _fontColors.entries.map((e) {
                final selected = _o.style.fontColor == e.value;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () =>
                        _update(_o.copyWith(style: _o.style.copyWith(fontColor: e.value))),
                    child: Tooltip(
                      message: e.key,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: e.value,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? AppColors.accent : AppColors.border,
                            width: selected ? 2.5 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 10),

          // Background
          _row(
            label: 'Background',
            child: Row(
              children: [
                Transform.scale(
                  scale: 0.75,
                  child: Switch(
                    value: _o.style.hasBackground,
                    onChanged: (v) =>
                        _update(_o.copyWith(style: _o.style.copyWith(hasBackground: v))),
                    activeThumbColor: AppColors.accent,
                  ),
                ),
                if (_o.style.hasBackground) ...[
                  Expanded(
                    child: SliderTheme(
                      data: const SliderThemeData(
                        activeTrackColor: AppColors.accent,
                        thumbColor: AppColors.accent,
                        inactiveTrackColor: AppColors.border,
                        trackHeight: 2,
                        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
                      child: Slider(
                        value: _o.style.backgroundOpacity,
                        min: 0.1,
                        max: 1.0,
                        onChanged: (v) => _update(
                            _o.copyWith(style: _o.style.copyWith(backgroundOpacity: v))),
                      ),
                    ),
                  ),
                  Text('${(_o.style.backgroundOpacity * 100).round()}%',
                      style: const TextStyle(color: AppColors.subtle, fontSize: 11)),
                ],
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Outline
          _row(
            label: 'Outline',
            child: Transform.scale(
              scale: 0.75,
              alignment: Alignment.centerLeft,
              child: Switch(
                value: _o.style.hasOutline,
                onChanged: (v) =>
                    _update(_o.copyWith(style: _o.style.copyWith(hasOutline: v))),
                activeThumbColor: AppColors.accent,
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Position
          _row(
            label: 'Position',
            child: _segmented(
              values: SubtitlePosition.values,
              current: _o.style.position,
              label: (p) => p.label,
              onSelect: (p) =>
                  _update(_o.copyWith(style: _o.style.copyWith(position: p))),
            ),
          ),

          const SizedBox(height: 10),

          // Export SRT
          _row(
            label: 'Export .srt',
            child: Transform.scale(
              scale: 0.75,
              alignment: Alignment.centerLeft,
              child: Switch(
                value: _o.exportSrt,
                onChanged: (v) => _update(_o.copyWith(exportSrt: v)),
                activeThumbColor: AppColors.accent,
              ),
            ),
          ),

          // Preview
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: _SubtitlePreview(style: _o.style),
          ),
        ],
      ],
    );
  }

  Widget _row({required String label, required Widget child}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(label, style: const TextStyle(color: AppColors.subtle, fontSize: 12)),
            ),
            Expanded(child: child),
          ],
        ),
      );

  Widget _segmented<T>({
    required List<T> values,
    required T current,
    required String Function(T) label,
    required ValueChanged<T> onSelect,
  }) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: values.map((v) {
          final sel = v == current;
          return GestureDetector(
            onTap: () => onSelect(v),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: sel ? AppColors.accent : AppColors.surface2,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: sel ? AppColors.accent : AppColors.border),
              ),
              child: Text(label(v),
                  style: TextStyle(
                    color: sel ? Colors.white : AppColors.subtle,
                    fontSize: 11,
                    fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                  )),
            ),
          );
        }).toList(),
      );
}

// ── Whisper install dialog ────────────────────────────────────────────────────

enum _InstallStage { confirm, installing, done, error }

class _WhisperInstallDialog extends StatefulWidget {
  final WhisperService service;
  const _WhisperInstallDialog({required this.service});

  @override
  State<_WhisperInstallDialog> createState() => _WhisperInstallDialogState();
}

class _WhisperInstallDialogState extends State<_WhisperInstallDialog> {
  _InstallStage _stage = _InstallStage.confirm;
  bool _canInstall = true;
  String _installMethod = 'Detecting installer…';
  final List<String> _log = [];
  String? _errorMsg;
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _detectInstaller();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _detectInstaller() async {
    final canInstall = await widget.service.canInstall;
    final method = await widget.service.installMethodDescription;
    if (mounted) {
      setState(() {
        _canInstall = canInstall;
        _installMethod = method;
      });
    }
  }

  void _appendLog(String s) {
    if (!mounted) return;
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _install() async {
    setState(() {
      _stage = _InstallStage.installing;
      _log.clear();
    });
    try {
      await widget.service.install(onOutput: _appendLog);
      // Verify the binary is now reachable
      final ok = await widget.service.isAvailable;
      if (!mounted) return;
      if (ok) {
        setState(() => _stage = _InstallStage.done);
      } else {
        setState(() {
          _stage = _InstallStage.error;
          _errorMsg =
              'pip reported success but the whisper command was not found.\n'
              'You may need to restart VastEdit, or add the install location\n'
              'to your PATH.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _InstallStage.error;
        _errorMsg = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 480,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: switch (_stage) {
            _InstallStage.confirm => _buildConfirm(),
            _InstallStage.installing => _buildInstalling(),
            _InstallStage.done => _buildDone(),
            _InstallStage.error => _buildError(),
          },
        ),
      ),
    );
  }

  // ── Confirm ───────────────────────────────────────────────────────────────

  Widget _buildConfirm() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.download_rounded, color: AppColors.accent, size: 28),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Install openai-whisper',
                        style: TextStyle(
                            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    Text('Required for automatic subtitle generation',
                        style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _infoRow(Icons.mic_outlined, 'What it does',
              'openai-whisper transcribes speech to text locally on your machine — no internet required after install.'),
          const SizedBox(height: 12),
          _infoRow(Icons.storage_outlined, 'Download size',
              'Package: ~10 MB.  AI model weights are downloaded on first use (e.g. small model: ~250 MB).'),
          const SizedBox(height: 12),
          _infoRow(Icons.terminal_outlined, 'Install command',
              _installMethod),
          const SizedBox(height: 16),
          // Strategy explanation box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Install strategy',
                    style: TextStyle(
                        color: AppColors.subtle,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(
                  '1. pipx  (preferred — isolated, no system conflicts)\n'
                  '2. pip3 --break-system-packages --user  (user-level)\n'
                  '3. pip3 --break-system-packages  (system-wide fallback)',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 11, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          if (!_canInstall) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(20),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.warning.withAlpha(60)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppColors.warning, size: 16),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Neither pipx nor pip3 were found.\n\n'
                      'Install pipx first (recommended):\n'
                      '  brew install pipx\n\n'
                      'Or install Python:\n'
                      '  brew install python',
                      style: TextStyle(color: AppColors.warning, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Install'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: _canInstall ? _install : null,
              ),
            ],
          ),
        ],
      );

  // ── Installing ────────────────────────────────────────────────────────────

  Widget _buildInstalling() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
              ),
              SizedBox(width: 14),
              Text('Installing openai-whisper…',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          const Text('This may take a minute. Do not close this window.',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 16),
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: const Color(0xFF0D0D0D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            padding: const EdgeInsets.all(10),
            child: ListView.builder(
              controller: _logScroll,
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(
                    color: Color(0xFF88CC88), fontSize: 10, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      );

  // ── Done ──────────────────────────────────────────────────────────────────

  Widget _buildDone() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 48),
          const SizedBox(height: 16),
          const Text('openai-whisper installed!',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Subtitles are now enabled.\n'
            'The AI model weights will download automatically on your first export.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            ),
            child: const Text('Done'),
          ),
        ],
      );

  // ── Error ─────────────────────────────────────────────────────────────────

  Widget _buildError() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 24),
              SizedBox(width: 10),
              Text('Installation failed',
                  style: TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.danger.withAlpha(15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.danger.withAlpha(60)),
            ),
            child: Text(
              _errorMsg ?? 'Unknown error',
              style: const TextStyle(color: AppColors.danger, fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 16),
          const Text('You can install it manually in Terminal:',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0D0D),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppColors.border),
            ),
            child: const SelectableText(
              'pip3 install openai-whisper',
              style: TextStyle(color: Color(0xFF88CC88), fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Close', style: TextStyle(color: AppColors.muted)),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: _install,
              ),
            ],
          ),
        ],
      );

  Widget _infoRow(IconData icon, String label, String description) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.muted, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(description,
                    style: const TextStyle(color: AppColors.muted, fontSize: 11)),
              ],
            ),
          ),
        ],
      );
}

// ── Subtitle preview chip ─────────────────────────────────────────────────────

class _SubtitlePreview extends StatelessWidget {
  final SubtitleStyle style;
  const _SubtitlePreview({required this.style});

  @override
  Widget build(BuildContext context) {
    final bg = style.hasBackground
        ? Colors.black.withAlpha((style.backgroundOpacity * 255).round())
        : Colors.transparent;
    final shadow = style.hasOutline
        ? [Shadow(color: Colors.black, blurRadius: 2, offset: const Offset(1, 1))]
        : <Shadow>[];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('Preview', style: TextStyle(color: AppColors.muted, fontSize: 10)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: bg,
            child: Text(
              'Bonjour, bienvenue !',
              style: TextStyle(
                color: style.fontColor,
                fontSize: (style.fontSize * 0.55).clamp(10, 26),
                shadows: shadow,
                fontWeight: FontWeight.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
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
        Text(proc.statusMsg, style: TextStyle(color: color, fontSize: 12)),
        if (proc.stage == _Stage.done && proc.outputPath != null) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => Process.run('open', ['-R', proc.outputPath!]),
            child: const Text('Reveal in Finder',
                style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 12,
                    decoration: TextDecoration.underline)),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onReset,
            child: const Text('Reset', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
        ],
        if (proc.stage == _Stage.error) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: onReset,
            child:
                const Text('Dismiss', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
        ],
      ],
    );
  }
}
