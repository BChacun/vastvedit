import 'dart:ui';

// ── Enums ─────────────────────────────────────────────────────────────────────

enum SubtitleLanguage {
  english('en', 'English'),
  french('fr', 'French');

  final String code;
  final String label;
  const SubtitleLanguage(this.code, this.label);
}

enum WhisperModel {
  tiny('tiny', 'Tiny', 'Fastest · least accurate'),
  base('base', 'Base', 'Fast · decent accuracy'),
  small('small', 'Small', 'Recommended balance'),
  medium('medium', 'Medium', 'High accuracy · slower');

  final String id;
  final String label;
  final String description;
  const WhisperModel(this.id, this.label, this.description);
}

enum SubtitlePosition {
  bottom('Bottom', 2),
  top('Top', 8);

  final String label;
  // ASS alignment numpad codes: 2 = bottom-centre, 8 = top-centre
  final int assAlignment;
  const SubtitlePosition(this.label, this.assAlignment);
}

// ── Style ─────────────────────────────────────────────────────────────────────

class SubtitleStyle {
  final Color fontColor;
  final double fontSize; // pts
  final bool hasBackground;
  final double backgroundOpacity; // 0.0–1.0
  final bool hasOutline;
  final SubtitlePosition position;

  const SubtitleStyle({
    this.fontColor = const Color(0xFFFFFFFF),
    this.fontSize = 24,
    this.hasBackground = true,
    this.backgroundOpacity = 0.45,
    this.hasOutline = true,
    this.position = SubtitlePosition.bottom,
  });

  SubtitleStyle copyWith({
    Color? fontColor,
    double? fontSize,
    bool? hasBackground,
    double? backgroundOpacity,
    bool? hasOutline,
    SubtitlePosition? position,
  }) =>
      SubtitleStyle(
        fontColor: fontColor ?? this.fontColor,
        fontSize: fontSize ?? this.fontSize,
        hasBackground: hasBackground ?? this.hasBackground,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        hasOutline: hasOutline ?? this.hasOutline,
        position: position ?? this.position,
      );

  /// Returns a full ASS [V4+ Styles] line with all style properties embedded.
  ///
  /// Used instead of the `force_style` ffmpeg filter option, which breaks
  /// consistently in Homebrew ffmpeg 7.x regardless of quoting/escaping.
  /// By embedding styles directly in the .ass file we avoid the filter-string
  /// parser entirely.
  String toAssStyleLine() {
    final fg = _assColor(fontColor, alpha: 0);
    const secondary = '&H000000FF'; // unused (karaoke), standard default
    final ol = _assColor(const Color(0xFF000000), alpha: 0);
    final bgAlpha = hasBackground
        ? ((1.0 - backgroundOpacity) * 255).round().clamp(0, 255)
        : 255;
    final back = _assColor(const Color(0xFF000000), alpha: bgAlpha);
    final borderStyle = hasBackground ? 3 : 1;
    final outlineWidth = hasOutline ? 2 : 0;

    // ASS Style field order:
    // Name, Fontname, Fontsize,
    // PrimaryColour, SecondaryColour, OutlineColour, BackColour,
    // Bold, Italic, Underline, StrikeOut,
    // ScaleX, ScaleY, Spacing, Angle,
    // BorderStyle, Outline, Shadow,
    // Alignment, MarginL, MarginR, MarginV, Encoding
    return 'Style: Default,'
        'Arial,${fontSize.round()},'
        '$fg,$secondary,$ol,$back,'
        '0,0,0,0,'
        '100,100,0,0,'
        '$borderStyle,$outlineWidth,0,'
        '${position.assAlignment},16,16,28,1';
  }
}

/// ASS color format: `&HAABBGGRR`  (00 = opaque, FF = transparent in alpha byte)
String _assColor(Color c, {required int alpha}) {
  String h(int v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0').toUpperCase();
  final b = (c.b * 255).round();
  final g = (c.g * 255).round();
  final r = (c.r * 255).round();
  return '&H${h(alpha)}${h(b)}${h(g)}${h(r)}';
}

// ── Options ───────────────────────────────────────────────────────────────────

class SubtitleOptions {
  final bool enabled;
  final SubtitleLanguage language;
  final WhisperModel model;
  final SubtitleStyle style;
  final bool exportSrt;

  const SubtitleOptions({
    this.enabled = false,
    this.language = SubtitleLanguage.english,
    this.model = WhisperModel.small,
    this.style = const SubtitleStyle(),
    this.exportSrt = false,
  });

  SubtitleOptions copyWith({
    bool? enabled,
    SubtitleLanguage? language,
    WhisperModel? model,
    SubtitleStyle? style,
    bool? exportSrt,
  }) =>
      SubtitleOptions(
        enabled: enabled ?? this.enabled,
        language: language ?? this.language,
        model: model ?? this.model,
        style: style ?? this.style,
        exportSrt: exportSrt ?? this.exportSrt,
      );
}
