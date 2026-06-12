import 'dart:io';

class WhisperService {
  String? _cachedWhisperPath;
  String? _cachedPipPath;

  // ── Whisper detection ─────────────────────────────────────────────────────

  /// Absolute path to the `whisper` binary, or `null` if not installed.
  Future<String?> get executablePath async {
    if (_cachedWhisperPath != null) return _cachedWhisperPath;

    final home = Platform.environment['HOME'] ?? '';
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
      if (await File(p).exists()) return _cachedWhisperPath = p;
    }

    try {
      final r = await Process.run('/usr/bin/which', ['whisper']);
      if (r.exitCode == 0) {
        final p = r.stdout.toString().trim();
        if (p.isNotEmpty) return _cachedWhisperPath = p;
      }
    } catch (_) {}

    return null;
  }

  Future<bool> get isAvailable async => (await executablePath) != null;

  // ── pip detection ─────────────────────────────────────────────────────────

  /// Absolute path to `pip3`, or `null` if Python / pip are not found.
  Future<String?> get pipPath async {
    if (_cachedPipPath != null) return _cachedPipPath;

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      '/opt/homebrew/bin/pip3',
      '/usr/local/bin/pip3',
      '$home/.local/bin/pip3',
      '/opt/homebrew/bin/pip',
      '/usr/local/bin/pip',
      '/usr/bin/pip3',
    ];

    for (final p in candidates) {
      if (await File(p).exists()) return _cachedPipPath = p;
    }

    try {
      final r = await Process.run('/usr/bin/which', ['pip3']);
      if (r.exitCode == 0) {
        final p = r.stdout.toString().trim();
        if (p.isNotEmpty) return _cachedPipPath = p;
      }
    } catch (_) {}

    return null;
  }

  Future<bool> get canInstall async => (await pipPath) != null;

  // ── Installation ──────────────────────────────────────────────────────────

  /// Installs `openai-whisper` via pip and streams output to [onOutput].
  ///
  /// Tries a plain install first; retries with `--user` if the environment is
  /// "externally managed" (PEP 668 / macOS system Python).
  ///
  /// Throws an [Exception] with a human-readable message on failure.
  Future<void> install({void Function(String)? onOutput}) async {
    final pip = await pipPath;
    if (pip == null) {
      throw Exception(
        'pip3 not found.\n'
        'Install Python 3 via Homebrew:  brew install python\n'
        'or download it from https://python.org',
      );
    }

    Future<int> runPip(List<String> args) async {
      onOutput?.call('▶ $pip ${args.join(' ')}\n');
      final process = await Process.start(pip, args);
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen((s) => onOutput?.call(s));
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((s) => onOutput?.call(s));
      return process.exitCode;
    }

    // First attempt
    var code = await runPip(['install', 'openai-whisper']);

    // If it failed due to an externally-managed environment (PEP 668), retry
    // with --user
    if (code != 0) {
      onOutput?.call('\n⚠ Standard install failed — retrying with --user flag…\n');
      code = await runPip(['install', '--user', 'openai-whisper']);
    }

    if (code != 0) {
      throw Exception(
        'pip install failed (exit code $code).\n'
        'Try running manually in Terminal:\n'
        '  pip3 install openai-whisper',
      );
    }

    // Invalidate cached path so the next isAvailable check re-scans
    _cachedWhisperPath = null;
  }

  // ── Transcription ─────────────────────────────────────────────────────────

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
        'Enable Subtitles in the panel to install it automatically.',
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
    if (exitCode != 0) throw Exception('whisper exited with code $exitCode');

    final stem = inputPath.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final srtPath = '$outputDir/$stem.srt';

    if (!await File(srtPath).exists()) {
      throw Exception('Whisper finished but SRT not found at $srtPath');
    }

    return srtPath;
  }
}
