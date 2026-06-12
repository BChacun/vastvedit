import 'dart:io';

class WhisperService {
  String? _cachedWhisperPath;
  String? _cachedPipPath;
  String? _cachedPipxPath;

  // ── Binary detection ──────────────────────────────────────────────────────

  Future<String?> get executablePath async {
    if (_cachedWhisperPath != null) return _cachedWhisperPath;

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      '/opt/homebrew/bin/whisper',
      '/usr/local/bin/whisper',
      '$home/.local/bin/whisper',          // pipx default
      '$home/.local/pipx/venvs/openai-whisper/bin/whisper',
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

  Future<String?> get pipxPath async {
    if (_cachedPipxPath != null) return _cachedPipxPath;

    final home = Platform.environment['HOME'] ?? '';
    final candidates = [
      '/opt/homebrew/bin/pipx',
      '/usr/local/bin/pipx',
      '$home/.local/bin/pipx',
    ];

    for (final p in candidates) {
      if (await File(p).exists()) return _cachedPipxPath = p;
    }

    try {
      final r = await Process.run('/usr/bin/which', ['pipx']);
      if (r.exitCode == 0) {
        final p = r.stdout.toString().trim();
        if (p.isNotEmpty) return _cachedPipxPath = p;
      }
    } catch (_) {}

    return null;
  }

  Future<bool> get canInstall async =>
      (await pipxPath) != null || (await pipPath) != null;

  // ── Install strategy ──────────────────────────────────────────────────────

  /// Returns a human-readable description of the install method that will be used.
  Future<String> get installMethodDescription async {
    if (await pipxPath != null) {
      return 'pipx install openai-whisper  (recommended — isolated environment)';
    }
    if (await pipPath != null) {
      return 'pip3 install --break-system-packages --user openai-whisper';
    }
    return 'No installer found';
  }

  /// Installs openai-whisper using the best available method:
  ///   1. pipx          — cleanest, no environment conflicts
  ///   2. pip3 --break-system-packages --user  — user-level, safe
  ///   3. pip3 --break-system-packages         — system-wide, last resort
  Future<void> install({void Function(String)? onOutput}) async {
    // Always reset cached path so re-detection runs after install.
    _cachedWhisperPath = null;

    Future<int> run(String exe, List<String> args) async {
      onOutput?.call('\n▶ $exe ${args.join(' ')}\n');
      final process = await Process.start(exe, args);
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(onOutput);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(onOutput);
      return process.exitCode;
    }

    // ── Strategy 1: pipx ─────────────────────────────────────────────────
    final pipx = await pipxPath;
    if (pipx != null) {
      onOutput?.call('Using pipx — the recommended installer for Homebrew Python.\n');
      final code = await run(pipx, ['install', 'openai-whisper']);
      if (code == 0) return;
      onOutput?.call('\n⚠ pipx install failed — falling back to pip3…\n');
    }

    // ── Strategy 2 & 3: pip3 ─────────────────────────────────────────────
    final pip = await pipPath;
    if (pip == null) {
      throw Exception(
        'No Python installer found (tried pipx and pip3).\n\n'
        'Install one of:\n'
        '  brew install pipx   (recommended)\n'
        '  brew install python',
      );
    }

    // 2. --break-system-packages --user  (safe: user-level only)
    onOutput?.call('Trying pip3 with --break-system-packages --user…\n');
    var code = await run(pip, ['install', '--break-system-packages', '--user', 'openai-whisper']);
    if (code == 0) return;

    // 3. --break-system-packages (system-wide, last resort)
    onOutput?.call('\n⚠ User install failed — trying system-wide…\n');
    code = await run(pip, ['install', '--break-system-packages', 'openai-whisper']);
    if (code == 0) return;

    throw Exception(
      'All install attempts failed.\n\n'
      'Try installing pipx first, then retry:\n'
      '  brew install pipx\n'
      '  pipx install openai-whisper',
    );
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
        'Enable the Subtitles toggle to install it automatically.',
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
