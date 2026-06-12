import 'dart:io';

import '../models/project.dart';
import '../models/subtitle_options.dart';
import 'whisper_service.dart';

typedef VideoInterval = (double start, double end);

class FfmpegService {
  String? _ffmpegPath;
  String? _ffprobePath;
  bool? _subtitlesAvailable;

  // ── Binary detection ──────────────────────────────────────────────────────

  Future<String> get ffmpegPath async {
    if (_ffmpegPath != null) return _ffmpegPath!;
    // Prefer ffmpeg-full (keg-only Homebrew formula that includes libass,
    // freetype, and every other codec). Falls back to the standard ffmpeg.
    for (final p in [
      '/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg', // Apple Silicon, keg-only
      '/usr/local/opt/ffmpeg-full/bin/ffmpeg',    // Intel Mac, keg-only
      '/opt/homebrew/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
      '/usr/bin/ffmpeg',
    ]) {
      if (await File(p).exists()) return _ffmpegPath = p;
    }
    return _ffmpegPath = 'ffmpeg';
  }

  Future<String> get ffprobePath async {
    if (_ffprobePath != null) return _ffprobePath!;
    for (final p in [
      '/opt/homebrew/opt/ffmpeg-full/bin/ffprobe',
      '/usr/local/opt/ffmpeg-full/bin/ffprobe',
      '/opt/homebrew/bin/ffprobe',
      '/usr/local/bin/ffprobe',
      '/usr/bin/ffprobe',
    ]) {
      if (await File(p).exists()) return _ffprobePath = p;
    }
    return _ffprobePath = 'ffprobe';
  }

  /// Returns true if the current ffmpeg binary was compiled with libass
  /// (required for the `subtitles` filter used to burn subtitle files).
  ///
  /// The standard `brew install ffmpeg` does NOT include libass.
  /// `brew install ffmpeg-full` does.
  Future<bool> get subtitlesAvailable async {
    if (_subtitlesAvailable != null) return _subtitlesAvailable!;
    final ff = await ffmpegPath;
    try {
      final r = await Process.run(ff, ['-hide_banner', '-h', 'filter=subtitles']);
      final out = '${r.stdout}${r.stderr}';
      return _subtitlesAvailable = !out.contains('Unknown filter');
    } catch (_) {
      return _subtitlesAvailable = false;
    }
  }

  // ── Probe ─────────────────────────────────────────────────────────────────

  Future<double> getVideoDuration(String path) async {
    final probe = await ffprobePath;
    final result = await Process.run(probe, [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      path,
    ]);
    return double.tryParse(result.stdout.toString().trim()) ?? 0.0;
  }

  // ── Silence detection ─────────────────────────────────────────────────────

  Future<List<VideoInterval>> detectSilence(
    String path, {
    double threshold = -30.0,
    double minDuration = 0.5,
  }) async {
    final ff = await ffmpegPath;
    final result = await Process.run(ff, [
      '-i', path,
      '-af', 'silencedetect=n=${threshold}dB:d=$minDuration',
      '-f', 'null', '-',
    ]);

    final output = result.stderr.toString();
    final intervals = <VideoInterval>[];
    double? start;

    final startRe = RegExp(r'silence_start: (-?[\d.e+]+)');
    final endRe = RegExp(r'silence_end: ([\d.e+]+)');

    for (final line in output.split('\n')) {
      final sm = startRe.firstMatch(line);
      final em = endRe.firstMatch(line);
      if (sm != null) {
        start = (double.tryParse(sm.group(1) ?? '0') ?? 0.0).clamp(0.0, double.infinity);
      } else if (em != null && start != null) {
        final end = double.tryParse(em.group(1) ?? '0') ?? 0.0;
        final s = start;
        if (end > s) intervals.add((s, end));
        start = null;
      }
    }

    if (start != null) {
      final s = start;
      final duration = await getVideoDuration(path);
      if (duration > s) intervals.add((s, duration));
    }

    return intervals;
  }

  List<VideoInterval> computeNonSilentIntervals(
    List<VideoInterval> silentIntervals,
    double duration,
    double padding,
  ) {
    final padded = silentIntervals
        .map((si) => (si.$1 + padding, si.$2 - padding))
        .where((si) => si.$2 > si.$1)
        .toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));

    final nonSilent = <VideoInterval>[];
    double pos = 0.0;

    for (final si in padded) {
      if (si.$1 > pos + 0.01) nonSilent.add((pos, si.$1));
      if (si.$2 > pos) pos = si.$2;
    }
    if (pos < duration - 0.05) nonSilent.add((pos, duration));

    // Drop segments shorter than 300 ms — they are typically padding artifacts
    // (e.g. a silence that starts at t=0 produces a spurious 0→padding sliver)
    // and can cause ffmpeg concat failures with very short encoded chunks.
    return nonSilent.where((ni) => ni.$2 - ni.$1 >= 0.3).toList();
  }

  // ── Per-clip silence removal ──────────────────────────────────────────────

  Future<void> processClip({
    required String inputPath,
    required String outputPath,
    required List<VideoInterval> nonSilentIntervals,
    void Function(String)? onLog,
  }) async {
    final ff = await ffmpegPath;

    if (nonSilentIntervals.isEmpty) {
      onLog?.call('  No speech found, clip skipped.');
      return;
    }

    final n = nonSilentIntervals.length;
    final parts = <String>[];

    if (n == 1) {
      // Single segment — no concat needed, map trim outputs directly.
      final (s, e) = nonSilentIntervals[0];
      parts.add('[0:v]trim=start=$s:end=$e,setpts=PTS-STARTPTS[vout]');
      parts.add('[0:a]atrim=start=$s:end=$e,asetpts=PTS-STARTPTS[aout]');
    } else {
      // Multiple segments — explicitly split the input streams so each trim
      // filter gets its own private copy.  Reusing [0:v]/[0:a] as inputs to
      // multiple filter chains causes failures on many ffmpeg builds.
      final vSplitOuts = List.generate(n, (i) => '[vi$i]').join('');
      final aSplitOuts = List.generate(n, (i) => '[ai$i]').join('');
      parts.add('[0:v]split=$n$vSplitOuts');
      parts.add('[0:a]asplit=$n$aSplitOuts');

      for (int i = 0; i < n; i++) {
        final (s, e) = nonSilentIntervals[i];
        parts.add('[vi$i]trim=start=$s:end=$e,setpts=PTS-STARTPTS[v$i]');
        parts.add('[ai$i]atrim=start=$s:end=$e,asetpts=PTS-STARTPTS[a$i]');
      }

      final concatInputs = List.generate(n, (i) => '[v$i][a$i]').join('');
      parts.add('${concatInputs}concat=n=$n:v=1:a=1[vout][aout]');
    }

    final args = [
      '-i', inputPath,
      '-filter_complex', parts.join(';'),
      '-map', '[vout]',
      '-map', '[aout]',
      '-c:v', 'libx264', '-crf', '18', '-preset', 'medium',
      '-c:a', 'aac', '-b:a', '192k',
      '-max_muxing_queue_size', '9999',
      '-movflags', '+faststart',
      '-y', outputPath,
    ];

    onLog?.call('  ffmpeg ${args.join(' ')}');

    final process = await Process.start(ff, args);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((c) => onLog?.call(c.trim()));

    final code = await process.exitCode;
    if (code != 0) throw Exception('ffmpeg failed (code $code) on $inputPath');
  }

  // ── Concat ────────────────────────────────────────────────────────────────

  Future<void> concatClips({
    required List<String> clipPaths,
    required String outputPath,
    void Function(String)? onLog,
  }) async {
    final ff = await ffmpegPath;
    final listFile =
        '${Directory.systemTemp.path}/vastvedit_concat_${DateTime.now().millisecondsSinceEpoch}.txt';

    await File(listFile).writeAsString(
      clipPaths.map((p) => "file '${p.replaceAll("'", "'\\''")}'").join('\n'),
    );

    final args = [
      '-f', 'concat', '-safe', '0',
      '-i', listFile,
      '-c', 'copy',
      '-movflags', '+faststart',
      '-y', outputPath,
    ];

    onLog?.call('ffmpeg ${args.join(' ')}');

    final process = await Process.start(ff, args);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((c) => onLog?.call(c.trim()));

    final code = await process.exitCode;
    await File(listFile).delete().catchError((_) => File(listFile));
    if (code != 0) throw Exception('ffmpeg concat failed (code $code)');
  }

  // ── Subtitle burning ──────────────────────────────────────────────────────

  /// Burns subtitles into [inputPath] and writes the result to [outputPath].
  ///
  /// Requires the `subtitles` filter (libass). The standard Homebrew ffmpeg
  /// does NOT include it — install with: brew install ffmpeg-full
  ///
  /// We convert the SRT → ASS in Dart so the style is embedded in the file
  /// header, avoiding the ffmpeg filter-string parser entirely.
  Future<void> burnSubtitles({
    required String inputPath,
    required String srtPath,
    required String outputPath,
    required String tmpDir,
    required SubtitleStyle style,
    void Function(String)? onLog,
  }) async {
    final ff = await ffmpegPath;

    // Fail early with a helpful message rather than a cryptic filter error.
    if (!await subtitlesAvailable) {
      throw Exception(
        'Your ffmpeg build does not include subtitle support (libass).\n\n'
        'The standard Homebrew ffmpeg is compiled without it.\n'
        'Fix: install ffmpeg-full in Terminal, then restart VastEdit:\n\n'
        '  brew install ffmpeg-full',
      );
    }

    final srtContent = await File(srtPath).readAsString();
    final assContent = _srtToAss(srtContent, style);
    final assPath = '$tmpDir/subs_${DateTime.now().millisecondsSinceEpoch}.ass';
    await File(assPath).writeAsString(assContent, flush: true);

    final args = [
      '-i', inputPath,
      '-vf', 'subtitles=$assPath',
      '-c:v', 'libx264', '-crf', '18', '-preset', 'medium',
      '-c:a', 'copy',
      '-movflags', '+faststart',
      '-y', outputPath,
    ];

    onLog?.call('ffmpeg ${args.join(' ')}');

    final process = await Process.start(ff, args);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((c) => onLog?.call(c.trim()));

    final code = await process.exitCode;
    await File(assPath).delete().catchError((_) => File(assPath));
    if (code != 0) throw Exception('ffmpeg subtitle burn failed (code $code)');
  }

  // ── SRT → ASS conversion ─────────────────────────────────────────────────

  /// Converts an SRT string to ASS format with [style] embedded in the header.
  String _srtToAss(String srt, SubtitleStyle style) {
    final dialogues = <String>[];
    final blocks = srt.trim().split(RegExp(r'\r?\n\s*\r?\n'));

    for (final block in blocks) {
      final lines = block.trim().split(RegExp(r'\r?\n'));
      if (lines.isEmpty) continue;
      int i = 0;

      // Skip optional numeric index line.
      if (RegExp(r'^\d+$').hasMatch(lines[i].trim())) i++;
      if (i >= lines.length) continue;

      // Timestamp line: HH:MM:SS,mmm --> HH:MM:SS,mmm
      final timeLine = lines[i].trim();
      if (!timeLine.contains('-->')) continue;
      final tp = timeLine.split('-->');
      if (tp.length != 2) continue;
      final start = _srtToAssTime(tp[0].trim());
      final end   = _srtToAssTime(tp[1].trim());
      i++;

      // Text — strip Whisper HTML tags, join with ASS soft line-break \N.
      final text = lines
          .sublist(i)
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) => l.replaceAll(RegExp(r'<[^>]+>'), ''))
          .join(r'\N');

      if (text.isEmpty) continue;
      dialogues.add('Dialogue: 0,$start,$end,Default,,0000,0000,0000,,$text');
    }

    return [
      '[Script Info]',
      'ScriptType: v4.00+',
      'WrapStyle: 0',
      'ScaledBorderAndShadow: yes',
      'PlayResX: 1920',
      'PlayResY: 1080',
      '',
      '[V4+ Styles]',
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
          'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
          'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
          'Alignment, MarginL, MarginR, MarginV, Encoding',
      style.toAssStyleLine(),
      '',
      '[Events]',
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
      ...dialogues,
      '',
    ].join('\n');
  }

  /// Converts SRT timestamp `HH:MM:SS,mmm` → ASS timestamp `H:MM:SS.cc`.
  String _srtToAssTime(String s) {
    final norm = s.replaceAll(',', '.').replaceAll(' ', '');
    final dot  = norm.lastIndexOf('.');
    String t;
    int cs;
    if (dot >= 0) {
      t  = norm.substring(0, dot);
      cs = (int.tryParse(norm.substring(dot + 1).padRight(3, '0').substring(0, 3)) ?? 0) ~/ 10;
    } else {
      t  = norm;
      cs = 0;
    }
    final p = t.split(':');
    if (p.length != 3) return '0:00:00.00';
    final h   = int.tryParse(p[0]) ?? 0;
    final m   = int.tryParse(p[1]) ?? 0;
    final sec = int.tryParse(p[2]) ?? 0;
    return '$h:${m.toString().padLeft(2,'0')}:${sec.toString().padLeft(2,'0')}.${cs.toString().padLeft(2,'0')}';
  }

  // ── Full project pipeline ─────────────────────────────────────────────────

  Future<void> processProject({
    required Project project,
    required String outputPath,
    required double silenceThreshold,
    required double minSilenceDuration,
    required double padding,
    SubtitleOptions? subtitles,
    WhisperService? whisperService,
    void Function(String)? onLog,
    void Function(double)? onProgress,
  }) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final tmpDir = Directory('${Directory.systemTemp.path}/vastvedit_${project.id}_$stamp');
    await tmpDir.create(recursive: true);

    // When subtitles are enabled we need a separate rough-cut path so we can
    // burn subs on top as a second pass.
    final needsSubtitlePass = subtitles != null && subtitles.enabled;
    final roughCutPath = needsSubtitlePass ? '${tmpDir.path}/rough_cut.mp4' : outputPath;

    try {
      // ── Phase 1: per-clip silence removal ──────────────────────────────────
      final processedPaths = <String>[];
      final clips = project.clips;
      final total = clips.length;
      // Silence removal = 0 → 80 % of progress bar
      // (subtitle phase gets the remaining 20 %)
      final silenceShare = needsSubtitlePass ? 0.75 : 0.85;

      for (int i = 0; i < total; i++) {
        final clip = clips[i];
        onLog?.call('\n── Clip ${i + 1}/$total: ${clip.name}');
        onProgress?.call(i / total * silenceShare);

        if (!await File(clip.filePath).exists()) {
          throw Exception('File not found: ${clip.filePath}');
        }

        final duration = await getVideoDuration(clip.filePath);
        onLog?.call('  Duration: ${_fmt(duration)}');

        onLog?.call(
            '  Detecting silence (threshold: ${silenceThreshold}dB, min: ${minSilenceDuration}s)…');
        final silent = await detectSilence(
          clip.filePath,
          threshold: silenceThreshold,
          minDuration: minSilenceDuration,
        );
        onLog?.call('  Found ${silent.length} silent interval(s).');

        final nonSilent = computeNonSilentIntervals(silent, duration, padding);
        onLog?.call('  Non-silent segments: ${nonSilent.length}');

        if (nonSilent.isEmpty) {
          onLog?.call('  Clip is entirely silent — skipped.');
          continue;
        }

        final processedPath = '${tmpDir.path}/clip_$i.mp4';
        onLog?.call('  Removing silence…');
        await processClip(
          inputPath: clip.filePath,
          outputPath: processedPath,
          nonSilentIntervals: nonSilent,
          onLog: onLog,
        );
        processedPaths.add(processedPath);
        onLog?.call('  Done → $processedPath');
      }

      if (processedPaths.isEmpty) {
        throw Exception('All clips were silent — nothing to export.');
      }

      // ── Phase 2: stitch ────────────────────────────────────────────────────
      onLog?.call('\n── Stitching ${processedPaths.length} clip(s)…');
      onProgress?.call(needsSubtitlePass ? 0.78 : 0.88);

      if (processedPaths.length == 1) {
        await File(processedPaths.first).copy(roughCutPath);
      } else {
        await concatClips(clipPaths: processedPaths, outputPath: roughCutPath, onLog: onLog);
      }

      // ── Phase 3: subtitles (optional) ─────────────────────────────────────
      if (needsSubtitlePass && whisperService != null) {
        onLog?.call('\n── Transcribing audio (${subtitles.model.label} · ${subtitles.language.label})…');
        onProgress?.call(0.82);

        final srtPath = await whisperService.transcribe(
          inputPath: roughCutPath,
          language: subtitles.language.code,
          model: subtitles.model.id,
          outputDir: tmpDir.path,
          onLog: onLog,
        );
        onLog?.call('  SRT: $srtPath');

        // Optionally copy the SRT next to the output video
        if (subtitles.exportSrt) {
          final srtDest = outputPath.replaceAll(RegExp(r'\.[^.]+$'), '.srt');
          await File(srtPath).copy(srtDest);
          onLog?.call('  SRT exported → $srtDest');
        }

        onLog?.call('  Burning subtitles…');
        onProgress?.call(0.92);

        await burnSubtitles(
          inputPath: roughCutPath,
          srtPath: srtPath,
          outputPath: outputPath,
          tmpDir: tmpDir.path,
          style: subtitles.style,
          onLog: onLog,
        );

        await File(roughCutPath).delete().catchError((_) => File(roughCutPath));
      }

      onProgress?.call(1.0);
      onLog?.call('\n✓ Export complete → $outputPath');
    } finally {
      await tmpDir.delete(recursive: true).catchError((_) => tmpDir);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmt(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$m:$s';
  }
}
