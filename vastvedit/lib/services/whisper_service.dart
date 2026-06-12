import 'dart:io';

class WhisperService {
  String? _cachedWhisperPath;
  String? _cachedPipPath;
  String? _cachedPipxPath;

  // ── Shell helper ──────────────────────────────────────────────────────────

  /// Runs [command] in a login shell so the user's full PATH (Homebrew,
  /// pyenv, ~/.local/bin, etc.) is available — exactly as in Terminal.app.
  Future<String?> _loginShellWhich(String command) async {
    for (final shell in ['/bin/zsh', '/bin/bash']) {
      try {
        final r = await Process.run(shell, ['-l', '-c', 'which $command']);
        if (r.exitCode == 0) {
          final p = r.stdout.toString().trim().split('\n').first.trim();
          if (p.isNotEmpty && await File(p).exists()) return p;
        }
      } catch (_) {}
    }
    return null;
  }

  // ── Binary detection ──────────────────────────────────────────────────────

  Future<String?> get executablePath async {
    if (_cachedWhisperPath != null) return _cachedWhisperPath;

    final home = Platform.environment['HOME'] ?? '';

    // 1. Fixed locations that don't depend on a Python version number.
    final fixed = [
      '/opt/homebrew/bin/whisper',
      '/usr/local/bin/whisper',
      '$home/.local/bin/whisper', // pipx default
      '/usr/bin/whisper',
    ];
    for (final p in fixed) {
      if (await File(p).exists()) return _cachedWhisperPath = p;
    }

    // 2. Dynamic scan of ~/Library/Python/<version>/bin/whisper.
    //    Covers every Python version (3.9, 3.10, … 3.14, 3.15, …) without
    //    hardcoding version numbers — pip --user always installs here on macOS.
    final pyLibDir = Directory('$home/Library/Python');
    if (await pyLibDir.exists()) {
      final entries = await pyLibDir.list().toList();
      // Sort descending so the newest version is tried first.
      entries.sort((a, b) => b.path.compareTo(a.path));
      for (final entry in entries) {
        if (entry is Directory) {
          final p = '${entry.path}/bin/whisper';
          if (await File(p).exists()) return _cachedWhisperPath = p;
        }
      }
    }

    // 3. Login shell fallback — picks up the user's full PATH (Homebrew,
    //    pyenv, conda, ~/.local/bin, etc.) exactly as Terminal.app does.
    final found = await _loginShellWhich('whisper');
    if (found != null) return _cachedWhisperPath = found;

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

    final found = await _loginShellWhich('pip3') ?? await _loginShellWhich('pip');
    if (found != null) return _cachedPipPath = found;

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

    final found = await _loginShellWhich('pipx');
    if (found != null) return _cachedPipxPath = found;

    return null;
  }

  Future<bool> get canInstall async =>
      (await pipxPath) != null || (await pipPath) != null;

  // ── Install strategy ──────────────────────────────────────────────────────

  Future<String> get installMethodDescription async {
    if (await pipxPath != null) {
      return 'pipx install openai-whisper  (recommended — isolated environment)';
    }
    if (await pipPath != null) {
      return 'pip3 install --break-system-packages --user openai-whisper';
    }
    return 'No installer found (install pipx or Python first)';
  }

  /// Installs openai-whisper using the best available method, then performs
  /// a login-shell re-scan to locate the newly installed binary.
  Future<void> install({void Function(String)? onOutput}) async {
    _cachedWhisperPath = null; // force re-detection after install

    Future<int> run(String exe, List<String> args) async {
      onOutput?.call('\n▶ $exe ${args.join(' ')}\n');
      final process = await Process.start(exe, args);
      process.stdout.transform(const SystemEncoding().decoder).listen(onOutput);
      process.stderr.transform(const SystemEncoding().decoder).listen(onOutput);
      return process.exitCode;
    }

    // ── Strategy 1: pipx ─────────────────────────────────────────────────
    final pipx = await pipxPath;
    if (pipx != null) {
      onOutput?.call('Using pipx — the recommended installer for Homebrew Python.\n');
      final code = await run(pipx, ['install', 'openai-whisper']);
      if (code == 0) return;
      onOutput?.call('\n⚠ pipx failed — falling back to pip3…\n');
    }

    // ── Strategy 2: pip3 --break-system-packages --user ───────────────────
    final pip = await pipPath;
    if (pip == null) {
      throw Exception(
        'No Python installer found (tried pipx and pip3).\n\n'
        'Install one of:\n'
        '  brew install pipx   ← recommended\n'
        '  brew install python',
      );
    }

    onOutput?.call('Trying pip3 --break-system-packages --user…\n');
    var code = await run(
        pip, ['install', '--break-system-packages', '--user', 'openai-whisper']);
    if (code == 0) return;

    // ── Strategy 3: pip3 --break-system-packages (system-wide) ───────────
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
