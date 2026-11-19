import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_files.dart';

/// Colors for one field (the text between two commas) of a line on the Raw tab. Null means "as usual".
class FieldStyle {
  const FieldStyle({this.text, this.highlight});

  final Color? text;
  final Color? highlight;

  bool get isPlain => text == null && highlight == null;

  TextStyle get textStyle => TextStyle(color: text, backgroundColor: highlight);

  Map<String, Object?> toJson() => {'text': text?.toARGB32(), 'highlight': highlight?.toARGB32()};

  factory FieldStyle.fromJson(Map<dynamic, dynamic> j) => FieldStyle(
        text: j['text'] == null ? null : Color(j['text'] as int),
        highlight: j['highlight'] == null ? null : Color(j['highlight'] as int),
      );

  FieldStyle copyWith({Color? text, Color? highlight, bool clearText = false, bool clearHighlight = false}) =>
      FieldStyle(
        text: clearText ? null : (text ?? this.text),
        highlight: clearHighlight ? null : (highlight ?? this.highlight),
      );
}

/// A saved coloring of the Raw tab's lines: one [FieldStyle] per field. It applies only to lines that have exactly
/// that many fields when split at commas (so other kinds of lines, such as startup messages, are left alone).
class RawColorScheme {
  RawColorScheme({required this.styles, this.enabled = true});

  static const delimiter = ',';

  final List<FieldStyle> styles;
  bool enabled;

  int get fields => styles.length;

  /// The line's fields, or null if it doesn't have the number of fields this scheme was made for.
  List<String>? split(String line) {
    final parts = line.split(delimiter);
    return parts.length == fields ? parts : null;
  }

  /// The line drawn in color, or null if the scheme doesn't apply to it (or is off).
  TextSpan? span(String line, TextStyle base) {
    if (!enabled) return null;
    final parts = split(line);
    if (parts == null) return null;
    return TextSpan(style: base, children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) const TextSpan(text: delimiter),
        TextSpan(text: parts[i], style: styles[i].textStyle),
      ],
    ]);
  }

  Map<String, Object?> toJson() => {'enabled': enabled, 'fields': [for (final s in styles) s.toJson()]};

  static RawColorScheme? fromJson(Object? j) {
    if (j is! Map || j['fields'] is! List) return null;
    final styles = [for (final f in j['fields'] as List) FieldStyle.fromJson(f as Map)];
    if (styles.isEmpty) return null;
    return RawColorScheme(styles: styles, enabled: j['enabled'] != false);
  }

  /// The scheme saved on this phone, or null if there isn't one (or the file is unreadable).
  static Future<RawColorScheme?> load() async {
    try {
      final f = File('${(await AppFiles.dir('raw')).path}/color_scheme.json');
      if (!f.existsSync()) return null;
      return fromJson(jsonDecode(await f.readAsString()));
    } catch (e) {
      debugPrint('Raw color scheme not loaded: $e');
      return null;
    }
  }

  Future<void> save() async {
    try {
      final f = File('${(await AppFiles.dir('raw')).path}/color_scheme.json');
      await f.writeAsString(jsonEncode(toJson()));
    } catch (e) {
      debugPrint('Raw color scheme not saved: $e');
    }
  }
}

/// Colors offered for text (null = the usual black) and for highlighting (null = none).
const textPalette = <Color?>[
  null,
  Color(0xFFC62828), // red
  Color(0xFFE65100), // orange
  Color(0xFF2E7D32), // green
  Color(0xFF1565C0), // blue
  Color(0xFF6A1B9A), // purple
  Color(0xFF4E342E), // brown
  Color(0xFF757575), // grey
  Color(0xFFFFFFFF), // white (for the dark highlights)
];

const highlightPalette = <Color?>[
  null,
  Color(0xFFFFF59D), // yellow
  Color(0xFFC8E6C9), // light green
  Color(0xFFBBDEFB), // light blue
  Color(0xFFF8BBD0), // pink
  Color(0xFFFFE0B2), // light orange
  Color(0xFFE0E0E0), // light grey
  Color(0xFF1565C0), // dark blue
  Color(0xFF2E7D32), // dark green
  Color(0xFFC62828), // dark red
  Color(0xFF212121), // near black
];
