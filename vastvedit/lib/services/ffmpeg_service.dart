import 'dart:async';
import 'dart:io';

import '../models/project.dart';

typedef VideoInterval = (double start, double end);

class FfmpegService {
  String? _ffmpegPath;
  String? _ffprobePath;

  Future<String> get ffmpegPath async {
    if (_ffmpegPath != null) return _ffmpegPath!;
    for (final p in ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg']) {
      if (await File(p).exists()) return _ffmpegPath = p;
    }
    return _ffmpegPath = 'ffmpeg';
  }

  Future<String> get ffprobePath async {
    if (_ffprobePath != null) return _ffprobePath!;
    for (final p in ['/opt/homebrew/bin/ffprobe', '/usr/local/bin/ffprobe', '/usr/bin/ffprobe']) {
      if (await File(p).exists()) return _ffprobePath = p;
    }
    return _ffprobePath = 'ffprobe';
  }

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

    // clip ends in silence
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
    // Shrink each silence interval by padding on each side so we keep a bit of context around speech.
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

    // Drop segments shorter than 50 ms to avoid tiny glitches
    return nonSilent.where((ni) => ni.$2 - ni.$1 >= 0.05).toList();
  }

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

    final parts = <String>[];
    for (int i = 0; i < nonSilentIntervals.length; i++) {
      final (s, e) = nonSilentIntervals[i];
      parts.add('[0:v]trim=start=$s:end=$e,setpts=PTS-STARTPTS[v$i]');
      parts.add('[0:a]atrim=start=$s:end=$e,asetpts=PTS-STARTPTS[a$i]');
    }

    final n = nonSilentIntervals.length;
    if (n == 1) {
      parts.add('[v0][a0]concat=n=1:v=1:a=1[vout][aout]');
    } else {
      final inputs = List.generate(n, (i) => '[v$i][a$i]').join('');
      parts.add('${inputs}concat=n=$n:v=1:a=1[vout][aout]');
    }

    final filterComplex = parts.join(';');

    final args = [
      '-i', inputPath,
      '-filter_complex', filterComplex,
      '-map', '[vout]',
      '-map', '[aout]',
      '-c:v', 'libx264',
      '-crf', '18',
      '-preset', 'medium',
      '-c:a', 'aac',
      '-b:a', '192k',
      '-movflags', '+faststart',
      '-y', outputPath,
    ];

    onLog?.call('  ffmpeg ${args.join(' ')}');

    final process = await Process.start(ff, args);

    // Forward ffmpeg's stderr (progress/info) to the log callback
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((chunk) => onLog?.call(chunk.trim()));

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw Exception('ffmpeg exited with code $exitCode while processing $inputPath');
    }
  }

  Future<void> concatClips({
    required List<String> clipPaths,
    required String outputPath,
    void Function(String)? onLog,
  }) async {
    final ff = await ffmpegPath;
    final concatFile = '${Directory.systemTemp.path}/vastvedit_concat_${DateTime.now().millisecondsSinceEpoch}.txt';

    await File(concatFile).writeAsString(
      clipPaths.map((p) => "file '${p.replaceAll("'", "'\\''")}'").join('\n'),
    );

    onLog?.call('Concat list written to $concatFile');

    final args = [
      '-f', 'concat',
      '-safe', '0',
      '-i', concatFile,
      '-c', 'copy',
      '-movflags', '+faststart',
      '-y', outputPath,
    ];

    onLog?.call('ffmpeg ${args.join(' ')}');

    final process = await Process.start(ff, args);
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((chunk) => onLog?.call(chunk.trim()));

    final exitCode = await process.exitCode;
    await File(concatFile).delete().catchError((_) => File(concatFile));

    if (exitCode != 0) {
      throw Exception('ffmpeg concat exited with code $exitCode');
    }
  }

  Future<void> processProject({
    required Project project,
    required String outputPath,
    required double silenceThreshold,
    required double minSilenceDuration,
    required double padding,
    void Function(String)? onLog,
    void Function(double)? onProgress,
    void Function()? isCancelled,
  }) async {
    final tmpDir = Directory(
      '${Directory.systemTemp.path}/vastvedit_${project.id}_${DateTime.now().millisecondsSinceEpoch}',
    );
    await tmpDir.create(recursive: true);

    try {
      final processedPaths = <String>[];
      final clips = project.clips;
      final total = clips.length;

      for (int i = 0; i < total; i++) {
        final clip = clips[i];
        onLog?.call('\n── Clip ${i + 1}/$total: ${clip.name}');
        onProgress?.call(i / total * 0.85);

        if (!await File(clip.filePath).exists()) {
          throw Exception('File not found: ${clip.filePath}');
        }

        final duration = await getVideoDuration(clip.filePath);
        onLog?.call('  Duration: ${_fmt(duration)}');

        onLog?.call('  Detecting silence (threshold: ${silenceThreshold}dB, min: ${minSilenceDuration}s)…');
        final silentIntervals = await detectSilence(
          clip.filePath,
          threshold: silenceThreshold,
          minDuration: minSilenceDuration,
        );
        onLog?.call('  Found ${silentIntervals.length} silent interval(s).');

        final nonSilent = computeNonSilentIntervals(silentIntervals, duration, padding);
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

      onLog?.call('\n── Stitching ${processedPaths.length} clip(s)…');
      onProgress?.call(0.9);

      if (processedPaths.length == 1) {
        await File(processedPaths.first).copy(outputPath);
      } else {
        await concatClips(clipPaths: processedPaths, outputPath: outputPath, onLog: onLog);
      }

      onProgress?.call(1.0);
      onLog?.call('\n✓ Export complete: $outputPath');
    } finally {
      await tmpDir.delete(recursive: true).catchError((_) => tmpDir);
    }
  }

  String _fmt(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$m:$s';
  }
}
