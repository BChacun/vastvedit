import 'dart:io';

class WhisperService {
  String? _cachedPath;

  /// Returns the absolute path to the `whisper` binary, or `null` if not found.
  Future<String?> get executablePath async {
    if (_cachedPath != null) return _cachedPath;

    final home = Platform.environment['HOME'] ?? '';

    // Common install locations (pip, pipx, homebrew, pyenv…)
    final candidates = [
      '/opt/homebrew/bin/whisper',
      '/usr/local/bin/whisper',
      '$home/.local/bin/whisper',
      '$home/Library/Python/3.12/bin/whisper',
      '$home/Library/Python/3.11/bin/whisper',
      '$home/Library/Python/3.10/bin/whisper',
      '$home/Library/Python/3.9/bin/whisper',
      '/usr/bin/whisper',
    ];

    for (final p in candidates) {
      if (await File(p).exists()) return _cachedPath = p;
    }

    // Last resort: ask the shell
    try {
      final r = await Process.run('which', ['whisper']);
      if (r.exitCode == 0) {
        final p = r.stdout.toString().trim();
        if (p.isNotEmpty) return _cachedPath = p;
      }
    } catch (_) {}

    return null;
  }

  Future<bool> get isAvailable async => (await executablePath) != null;

  /// Runs Whisper on [inputPath] and returns the path of the generated SRT file.
  ///
  /// [language] is an ISO-639-1 code: `'en'`, `'fr'`, etc.
  /// [model]    is `'tiny'`, `'base'`, `'small'`, `'medium'`, or `'large'`.
  /// [outputDir] is where Whisper writes the SRT file.
  Future<String> transcribe({
    required String inputPath,
    required String language,
    required String model,
    required String outputDir,
    void Function(String)? onLog,
  }) async {
    final exe = await executablePath;
    if (exe == null) {
      throw Exception(
        'openai-whisper is not installed.\n'
        'Install it with:  pip install openai-whisper\n'
        'Then restart VastEdit.',
      );
    }

    final args = [
      inputPath,
      '--language', language,
      '--model', model,
      '--output_format', 'srt',
      '--output_dir', outputDir,
      '--verbose', 'False',
    ];

    onLog?.call('whisper ${args.join(' ')}');

    final process = await Process.start(exe, args);
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((s) => onLog?.call(s.trim()));
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) => onLog?.call(s.trim()));

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw Exception('whisper exited with code $exitCode');
    }

    // Whisper names the SRT after the input file (stem only)
    final stem = inputPath.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final srtPath = '$outputDir/$stem.srt';

    if (!await File(srtPath).exists()) {
      throw Exception(
        'Whisper ran successfully but SRT was not found at $srtPath.\n'
        'Check the output directory permissions.',
      );
    }

    return srtPath;
  }
}
