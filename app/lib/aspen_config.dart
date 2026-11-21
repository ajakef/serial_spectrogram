import 'dart:convert';

import 'aspen_config_spec.dart';

/// Checks an Aspen config file (CONFIG.TXT, or a config sequence file CONFIG01.TXT, ...) with the logger's own rules
/// (firmware 1.0.0-34 and later), for the Check tab: the logger's messages for each mistake, warnings about things it
/// accepts silently, and the settings it would use. What each setting does: config_file_aspen.md in the gemlog
/// repository (https://github.com/ajakef/gemlog/blob/main/config_file_aspen.md).
///
/// THIS FILE MUST AGREE WITH THE FIRMWARE (aspen-firmware: src/firmware_logic.cpp and other_functions.h; see
/// "---- CONFIG.TXT ----" in src/firmware_logic.h) and with gemlog's copy of the same rules (gemlog/aspen_config.py).
/// The settings table comes from aspen_config_spec.dart, generated from the firmware's docs/config_spec.json, which
/// the firmware's host tests write from its own code together with example lines and files and what the firmware makes
/// of them; test/aspen_config_test.dart checks this file against those examples. After a firmware change to how
/// config files are read, run aspen-firmware/tools/sync_config_spec.sh and make the tests pass.
///
/// Files are handled as bytes (latin1: each byte one character), so that lengths and odd characters count as they do
/// on the logger.

const configRulesFirmware = '1.0.0-34';

/// The firmware's settings table and examples (aspen_config_spec.dart).
class AspenConfigSpec {
  static final Map<String, dynamic> json = jsonDecode(aspenConfigSpecJson) as Map<String, dynamic>;
  static final List<Map<String, dynamic>> settings = [for (final s in json['settings'] as List) s as Map<String, dynamic>];
  static final Map<String, Map<String, dynamic>> byName = {for (final s in settings) s['name'] as String: s};
  static int get lineMax => json['line_max'] as int;
  static List<int> get sampleRates => [for (final r in byName['sample_rate']!['values'] as List) r as int];
  static List<int> get gains => [for (final g in byName['gains']!['values'] as List) g as int];
  static List<int> get defaultGains => [for (final g in byName['gains']!['default'] as List) g as int];
}

const _spaces = ' \t\r\n';
const _bom = 'ï»¿';
const _nameMax = 23; // ConfigFileLine.name holds 23 characters
const _valueMax = 39; // ConfigFileLine.value holds 39
const _int32Min = -2147483648;

String _cString(String s) {
  final i = s.indexOf('\u0000');
  return i < 0 ? s : s.substring(0, i);
}

String _lstrip(String s) {
  var i = 0;
  while (i < s.length && _spaces.contains(s[i])) {
    i++;
  }
  return s.substring(i);
}

String _rstrip(String s) {
  var i = s.length;
  while (i > 0 && _spaces.contains(s[i - 1])) {
    i--;
  }
  return s.substring(0, i);
}

String _asciiLower(String s) => String.fromCharCodes(s.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c));

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

bool _isDigits(String s) => s.isNotEmpty && s.split('').every(_isDigit);

/// parseWholeNumber: an optional '-' and 1-9 digits, nothing else.
int? _wholeNumber(String text) {
  final digits = text.startsWith('-') ? text.substring(1) : text;
  if (!_isDigits(digits) || digits.length > 9) return null;
  final x = int.parse(digits);
  return text.startsWith('-') ? -x : x;
}

/// One line as the logger reads it: its setting text (comment removed, at most lineMax characters), whether it was
/// longer, and the line as written (comment included) for showing.
class RawConfigLine {
  RawConfigLine(this.text, this.cut, this.shown);
  final String text;
  final bool cut;
  final String shown;
}

/// Splits a config file's text into lines as the logger does (ConfigLineAssembler): '\n' ends a line, '\r' is
/// dropped, '#' starts a comment, and only the first lineMax characters before it are kept.
List<RawConfigLine> splitConfigLines(String text) {
  final lineMax = AspenConfigSpec.lineMax;
  final lines = <RawConfigLine>[];
  var kept = StringBuffer(), shown = StringBuffer();
  var keptLength = 0;
  var cut = false, inComment = false, started = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    started = true;
    if (c == '\n') {
      lines.add(RawConfigLine(_cString(kept.toString()), cut, shown.toString()));
      kept = StringBuffer();
      shown = StringBuffer();
      keptLength = 0;
      cut = inComment = started = false;
      continue;
    }
    if (c != '\r') shown.write(c);
    if (c == '#') inComment = true;
    if (c == '\r' || inComment) continue;
    if (keptLength < lineMax) {
      kept.write(c);
      keptLength++;
    } else {
      cut = true;
    }
  }
  if (started) lines.add(RawConfigLine(_cString(kept.toString()), cut, shown.toString()));
  return lines;
}

/// detectConfigFormat: 'utf16', 'positional' (starts with a digit, '-' or '+'), or 'named'.
String detectConfigFormat(String firstLine) {
  if (firstLine.startsWith('ÿþ') || firstLine.startsWith('þÿ')) return 'utf16';
  var p = firstLine.startsWith(_bom) ? firstLine.substring(3) : firstLine;
  p = _lstrip(p);
  if (p.isNotEmpty && (_isDigit(p[0]) || p[0] == '-' || p[0] == '+')) return 'positional';
  return 'named';
}

int _nameDistance(String a, String b) {
  if (a.length > 24 || b.length > 24) return 99;
  final row = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    var diagonal = row[0];
    row[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final above = row[j];
      var best = diagonal + (a[i - 1] == b[j - 1] ? 0 : 1);
      if (row[j - 1] + 1 < best) best = row[j - 1] + 1;
      if (above + 1 < best) best = above + 1;
      row[j] = best;
      diagonal = above;
    }
  }
  return row[b.length];
}

String? _closestSetting(String name) {
  final test = name.startsWith('test_');
  String? best;
  var bestDistance = 99;
  for (final s in AspenConfigSpec.settings) {
    final candidate = s['name'] as String;
    if (candidate.startsWith('test_') != test) continue;
    final d = (name.length >= 3 && candidate.startsWith(name)) ? 1 : _nameDistance(name, candidate);
    if (d < bestDistance) {
      best = candidate;
      bestDistance = d;
    }
  }
  return bestDistance <= (name.length >= 8 ? 3 : 2) ? best : null;
}

/// parseSeedCode: letters and digits (made uppercase), up to maxLength (exactly, if exact).
String? _seedCode(String text, int maxLength, bool exact) {
  final code = StringBuffer();
  var n = 0;
  for (final unit in text.codeUnits) {
    final c = unit >= 97 && unit <= 122 ? unit - 32 : unit;
    final ok = (c >= 65 && c <= 90) || (c >= 48 && c <= 57);
    if (!ok || n >= maxLength) return null;
    code.writeCharCode(c);
    n++;
  }
  if (n == 0 || (exact && n != maxLength)) return null;
  return code.toString();
}

int? _numberValue(Map<String, dynamic> setting, String text) {
  var x = _wholeNumber(text);
  if (x == null) {
    final words = setting['words'] as Map<String, dynamic>?;
    x = words?[_asciiLower(text)] as int?;
  }
  if (x == null || x < (setting['min'] as int) || x > (setting['max'] as int)) return null;
  final values = setting['values'] as List?;
  if (values != null && !values.contains(x)) return null;
  return x;
}

List<int>? _gainList(String text) {
  final allowed = AspenConfigSpec.gains;
  final fields = text.split(',');
  if (fields.length > 4) return null;
  final gains = <int>[];
  for (final f in fields) {
    if (!_isDigits(f)) return null;
    var value = 0;
    for (final c in f.codeUnits) {
      value = value * 10 + (c - 48);
      if (value > 255) return null;
    }
    if (!allowed.contains(value)) return null;
    gains.add(value);
  }
  while (gains.length < 4) {
    gains.add(0);
  }
  if (gains.every((g) => g == 0)) return null;
  return gains;
}

List<Object>? _codeAssignment(String name, String text) {
  final s = AspenConfigSpec.byName[name]!;
  if (text == '-') return [name, '-'];
  final code = _seedCode(text, s['max_length'] as int, s['exact'] as bool);
  return code == null ? null : [name, code];
}

/// What the logger makes of one line of a named config file (parseConfigFileLine), comment already removed.
class ParsedConfigLine {
  String status = 'blank'; // ok, blank, no_equals, unknown_name, test_setting, extra_text, bad_value
  String name = ''; // as written, lowercase, for messages
  String value = ''; // as written, for messages
  List<List<Object>> assignments = []; // [setting, value]: codes take '-' for the default, others a number
  String? suggestion; // for unknown names
}

ParsedConfigLine parseConfigLine(String line) {
  final out = ParsedConfigLine();
  // a non-breaking space (bytes C2 A0) is a space; the firmware copies at most lineMax characters
  final buffer = StringBuffer();
  var length = 0;
  for (var i = 0; i < line.length && length < AspenConfigSpec.lineMax; i++) {
    if (line[i] == 'Â' && i + 1 < line.length && line[i + 1] == ' ') {
      buffer.write(' ');
      i++;
    } else {
      buffer.write(line[i]);
    }
    length++;
  }
  final text = buffer.toString();
  var p = text.startsWith(_bom) ? text.substring(3) : text;
  p = _lstrip(p);
  if (p.isEmpty) return out;
  final eq = p.indexOf('=');
  final namePart = _rstrip(eq < 0 ? p : p.substring(0, eq));
  out.name = _asciiLower(namePart.length > _nameMax ? namePart.substring(0, _nameMax) : namePart);
  final name = out.name;
  if (eq < 0) {
    out.status = 'no_equals';
    return out;
  }
  final shownValue = _rstrip(_lstrip(p.substring(eq + 1)));
  out.value = shownValue.length > _valueMax ? shownValue.substring(0, _valueMax) : shownValue;
  final setting = AspenConfigSpec.byName[name];
  if (setting == null) {
    out.status = 'unknown_name';
    out.suggestion = _closestSetting(name);
    return out;
  }
  final test = setting['config_txt'] != true && name.startsWith('test_');

  // the value with spaces removed around commas; spaces anywhere else mean two values
  final value = StringBuffer();
  var last = '';
  var pendingSpace = false, extra = false;
  var n = 0;
  for (final c in p.substring(eq + 1).split('')) {
    if (_spaces.contains(c)) {
      pendingSpace = true;
      continue;
    }
    if (pendingSpace && n > 0 && last != ',' && c != ',') extra = true;
    pendingSpace = false;
    if (n >= 63) {
      out.status = 'bad_value';
      return out;
    }
    value.write(c);
    last = c;
    n++;
  }
  final v = value.toString();
  if (v.isEmpty) {
    out.status = 'bad_value';
    return out;
  }
  if (extra) {
    out.status = 'extra_text';
    return out;
  }

  final kind = setting['type'] as String;
  List<List<Object>>? items;
  if (v == '-') {
    if (kind == 'gains') {
      final d = AspenConfigSpec.defaultGains;
      items = [for (var i = 0; i < 4; i++) ['gain${i + 1}', d[i]]];
    } else if (kind == 'channels') {
      items = [for (var i = 0; i < 4; i++) ['channel${i + 1}', '-']];
    } else if (kind == 'code') {
      items = [[name, '-']];
    } else if (name != 'run_minutes') {
      items = [[name, setting['default'] as int]];
    }
  } else if (kind == 'gains') {
    final g = _gainList(v);
    if (g != null) items = [for (var i = 0; i < 4; i++) ['gain${i + 1}', g[i]]];
  } else if (kind == 'channels') {
    final entries = v.split(',');
    if (entries.length <= 4 && entries.every((e) => e.length <= 8)) {
      final list = [for (var i = 0; i < entries.length; i++) _codeAssignment('channel${i + 1}', entries[i])];
      if (!list.contains(null)) items = [for (final a in list) a!];
    }
  } else if (kind == 'code') {
    final a = _codeAssignment(name, v);
    if (a != null) items = [a];
  } else if (name == 'run_minutes') {
    final x = _wholeNumber(v);
    if (x != null && x >= (setting['min'] as int) && x <= (setting['max'] as int)) items = [[name, x]];
  } else {
    final x = _numberValue(setting, v);
    if (x != null) items = [[name, x]];
  }
  if (items == null) {
    out.status = 'bad_value';
    return out;
  }
  out.assignments = items;
  out.status = test ? 'test_setting' : 'ok';
  return out;
}

String _problemMessage(String problem, ParsedConfigLine parsed, String fileName, int lineNumber) {
  final name = parsed.name, value = parsed.value;
  final allowed = AspenConfigSpec.byName[name]?['allowed'] as String? ?? '';
  final String body;
  switch (problem) {
    case 'no_equals':
      body = '"$name" has no \'=\' (expected name = value)';
    case 'unknown_name':
      body = '"$name" is not a setting${parsed.suggestion != null ? ' (did you mean ${parsed.suggestion}?)' : ''}';
    case 'extra_text':
      body = '$name = $value has more than one value (allowed: $allowed)';
    case 'bad_value':
      body = '$name = $value isn\'t allowed (allowed: $allowed)';
    case 'test_setting_here':
      body = '$name is a test setting: it works only in config sequence files (CONFIG01.TXT, ...) and CF: serial '
          'commands';
    case 'run_minutes_here':
      body = 'run_minutes works only in config sequence files (CONFIG01.TXT, CONFIG02.TXT, ...)';
    case 'set_twice':
      body = '$name is set twice';
    default:
      body = 'longer than ${AspenConfigSpec.lineMax} characters before any comment';
  }
  return 'Error: $fileName line $lineNumber: $body; ${problem == 'set_twice' ? 'this line is used' : 'ignored'}';
}

/// What a named file holds, read as NamedConfigReader does.
class NamedConfigRead {
  final problems = <List<Object>>[]; // [line number, kind]
  final messages = <String>[]; // the logger's "Error: ..." lines
  final problemsByLine = <int, String>{}; // line number: its message
  final settings = <String, Object>{}; // the last value given for each setting
  bool hasRunMinutes = false;
}

NamedConfigRead readNamedConfig(List<RawConfigLine> lines, {required bool sequenceFile, String fileName = 'CONFIG.TXT'}) {
  final r = NamedConfigRead();
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final number = i + 1;
    final parsed = parseConfigLine(lines[i].text);
    final info = AspenConfigSpec.byName[parsed.name];
    final test = info != null && info['config_txt'] != true && parsed.name.startsWith('test_');
    String? problem;
    var apply = false;
    final status = parsed.status;
    if (lines[i].cut) {
      problem = 'too_long';
    } else if (status == 'blank') {
      // nothing
    } else if (status == 'no_equals' || status == 'unknown_name') {
      problem = status;
    } else if (status == 'extra_text' || status == 'bad_value') {
      problem = test && !sequenceFile ? 'test_setting_here' : status;
    } else if (status == 'test_setting' && !sequenceFile) {
      problem = 'test_setting_here';
    } else {
      final runMinutes = parsed.assignments.length == 1 && parsed.assignments[0][0] == 'run_minutes';
      if (runMinutes && !sequenceFile) {
        problem = 'run_minutes_here';
      } else {
        r.hasRunMinutes = r.hasRunMinutes || runMinutes;
        final ids = {for (final a in parsed.assignments) a[0] as String};
        if (ids.intersection(seen).isNotEmpty) problem = 'set_twice';
        seen.addAll(ids);
        apply = true;
      }
    }
    if (apply) {
      for (final a in parsed.assignments) {
        r.settings[a[0] as String] = a[1];
      }
    }
    if (problem != null) {
      r.problems.add([number, problem]);
      final message = _problemMessage(problem, parsed, fileName, number);
      r.messages.add(message);
      r.problemsByLine[number] = message;
    }
  }
  return r;
}

/// The file's format, from its first line with anything on it besides a comment.
String configFileFormat(List<RawConfigLine> lines) {
  for (final l in lines) {
    if (parseConfigLine(l.text).status != 'blank') return detectConfigFormat(l.text);
  }
  return 'named';
}

/// The number n in a config sequence file's name (CONFIG`n`.TXT, 1-3 digits, any case), or -1.
int configSequenceNumber(String name) {
  final m = RegExp(r'^CONFIG([0-9]{1,3})\.TXT$', caseSensitive: false).firstMatch(name);
  return m == null ? -1 : int.parse(m.group(1)!);
}

// ---- The original positional format (ReadConfigPositional) ----

const _positionalNames = [
  'channel 1 gain', 'channel 2 gain', 'channel 3 gain', 'channel 4 gain', 'sample rate', 'gps_mode',
  'gps_cycle_minutes', 'gps_quota', 'use_compression', 'network', 'station', 'location', 'channel', 'channel',
  'channel', 'channel', 'checkin_minutes', 'checkin_hour',
];
const positionalLabels = [
  'channel 1 gain', 'channel 2 gain', 'channel 3 gain', 'channel 4 gain', 'sample rate', 'gps_mode',
  'gps_cycle_minutes', 'gps_quota', 'use_compression', 'network code', 'station code', 'location code',
  'channel 1 code', 'channel 2 code', 'channel 3 code', 'channel 4 code', 'checkin_minutes', 'checkin_hour',
];
// Words in a positional file's comments that name each setting, to spot a missing or extra line.
final _commentPatterns = [
  for (var i = 1; i <= 4; i++) RegExp('channel\\s*$i\\s*gain'),
  RegExp(r'sample[ _]rate'), RegExp(r'gps[ _]mode'), RegExp(r'cycle'), RegExp(r'quota'), RegExp(r'compression'),
  RegExp(r'network'), RegExp(r'station'), RegExp(r'location'),
  for (var i = 1; i <= 4; i++) RegExp('channel\\s*$i\\s*code'),
  RegExp(r'checkin_minutes|check-in.*minutes'), RegExp(r'checkin_hour|hour'),
];

/// strtol as the positional reader uses it: the number at the start, or null if there is none ("missing").
int? _strtol(String text) {
  final m = RegExp(r'^[+-]?[0-9]+').firstMatch(text);
  if (m == null) return null;
  var x = BigInt.parse(m.group(0)!.replaceFirst('+', ''));
  if (x > BigInt.from(2147483647)) x = BigInt.from(2147483647);
  if (x < BigInt.from(_int32Min)) x = BigInt.from(_int32Min);
  return x == BigInt.from(_int32Min) ? null : x.toInt();
}

class PositionalConfigRead {
  final messages = <String>[];
  final warnings = <String>[];
  final settings = <String, Object>{};
  final labels = <int, String>{}; // line number: what it is read as
  final problemsByLine = <int, String>{};
}

PositionalConfigRead readPositionalConfig(String text, {String fileName = 'CONFIG.TXT'}) {
  final r = PositionalConfigRead();
  final byName = AspenConfigSpec.byName;
  final values = <(int, String, String)>[]; // line number, value as the firmware sees it, comment
  final rawLines = text.split('\n');
  for (var i = 0; i < rawLines.length; i++) {
    final raw = rawLines[i];
    final hash = raw.indexOf('#');
    final comment = hash >= 0 ? _asciiLower(raw.substring(hash + 1)) : '';
    var kept = (hash < 0 ? raw : raw.substring(0, hash)).replaceAll(RegExp('[ \r\t]'), '');
    if (kept.length > 198) kept = kept.substring(0, 198);
    if (kept.isNotEmpty) values.add((i + 1, _cString(kept), comment));
  }
  void problem(int line, String message) {
    r.messages.add(message);
    r.problemsByLine[line] = message;
  }

  void warn(int line, String message) {
    r.warnings.add('line $line: $message');
    r.problemsByLine.putIfAbsent(line, () => message);
  }

  void invalid(int line, int x, int used, String name) =>
      problem(line, 'Error: invalid $name $x in $fileName; using $used');

  final gains = List<int>.of(AspenConfigSpec.defaultGains);
  for (var index = 0; index < values.length; index++) {
    final (number, value, comment) = values[index];
    if (index >= _positionalNames.length) {
      warn(number, 'an extra line: the logger reads only the first ${_positionalNames.length} values, so it ignores '
          'this');
      continue;
    }
    final label = positionalLabels[index];
    r.labels[number] = label;
    if (comment.trim().isNotEmpty && !_commentPatterns[index].hasMatch(comment)) {
      final others = [for (var k = 0; k < _commentPatterns.length; k++) if (_commentPatterns[k].hasMatch(comment)) k];
      if (others.isNotEmpty) {
        warn(number, 'read as $label, but its comment says ${positionalLabels[others.first]}: is a line above it '
            'missing or extra?');
      }
    }
    if (index >= 9 && index <= 15) {
      if (value == '-') continue;
      final name = ['network', 'station', 'location', 'channel1', 'channel2', 'channel3', 'channel4'][index - 9];
      final s = byName[name]!;
      final code = _seedCode(value, s['max_length'] as int, s['exact'] as bool);
      if (code == null) {
        problem(number, 'Error: invalid ${_positionalNames[index]} code "$value" in $fileName; using default');
      } else {
        r.settings[name] = code;
      }
      continue;
    }
    final x = _strtol(value);
    if (x == null) {
      warn(number, '"$value" isn\'t a number, so the logger ignores it and uses the default $label');
      continue;
    }
    if (!RegExp(r'^[+-]?[0-9]+$').hasMatch(value)) {
      warn(number, 'the logger reads only the number at the start of "$value"');
    }
    int def(String name) => byName[name]!['default'] as int;
    if (index < 4) {
      if (AspenConfigSpec.gains.contains(x)) {
        gains[index] = x;
      } else {
        invalid(number, x, gains[index], _positionalNames[index]);
      }
    } else if (index == 4) {
      if (AspenConfigSpec.sampleRates.contains(x)) {
        r.settings['sample_rate'] = x;
      } else {
        invalid(number, x, def('sample_rate'), 'sample rate');
      }
    } else if (index == 5) {
      if (x >= 1 && x <= 4) {
        r.settings['gps_mode'] = x;
      } else {
        invalid(number, x, def('gps_mode'), 'gps_mode');
      }
    } else if (index == 6 || index == 7) {
      final name = index == 6 ? 'gps_cycle_minutes' : 'gps_quota';
      if (x > 0 && x <= 255) {
        r.settings[name] = x;
      } else {
        invalid(number, x, def(name), name);
      }
    } else if (index == 8) {
      if (x != 0 && x != 1) invalid(number, x, 1, 'use_compression');
    } else if (index == 16) {
      if (x >= 0 && x <= 30) {
        r.settings['checkin_minutes'] = x;
      } else {
        invalid(number, x, def('checkin_minutes'), 'checkin_minutes');
      }
    } else if (index == 17) {
      if (x >= 0 && x <= 23) {
        r.settings['checkin_hour'] = x;
      } else {
        invalid(number, x, def('checkin_hour'), 'checkin_hour');
      }
    }
  }
  if (gains.every((g) => g == 0)) {
    r.messages.add('Error: all channels set to gain 0 in $fileName; using default gains');
    gains.setAll(0, AspenConfigSpec.defaultGains);
  }
  for (var i = 0; i < 4; i++) {
    r.settings['gain${i + 1}'] = gains[i];
  }
  return r;
}

/// defaultChannelCode: HDF, EHZ, EHN, EHE at 100-200 sps; band C/D at 400-800; F/G at 1000 and up.
String defaultChannelCodeFor(int channel, int sampleRate) {
  final (infrasound, seismic) = sampleRate >= 1000 ? ('F', 'G') : (sampleRate >= 250 ? ('C', 'D') : ('H', 'E'));
  return channel == 0 ? '${infrasound}DF' : '${seismic}H${'ZNE'[channel - 1]}';
}

/// One line of the file for showing: what it is read as (setting) or what's wrong with it (problem).
class ConfigLineNote {
  ConfigLineNote(this.lineNumber, this.text, {this.setting, this.problem});
  final int lineNumber; // 1-based, counting every line in the file
  final String text;
  final String? setting;
  final String? problem;
}

/// The result of checking one config file (see checkAspenConfig).
class AspenConfigCheck {
  AspenConfigCheck(this.fileName);
  final String fileName;
  String format = 'named'; // named, positional, or utf16 (unreadable: every setting takes its default)
  final errors = <String>[]; // the logger's own messages ("Error: ..."): red LED 6 flashes, the value is ignored
  final warnings = <String>[]; // accepted silently by the logger, but probably not what was meant
  final notes = <String>[];
  final settings = <String, Object>{}; // every setting as the logger would use it
  final lines = <ConfigLineNote>[];
  bool? sequence; // a config sequence file: whether the logger would run it
  bool get ok => errors.isEmpty;
}

/// Version numbers like "1.0.0-34_2026-11-22T..." as (1, 0, 0, 34); null if it isn't one.
List<int>? firmwareVersionNumbers(String? firmware) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)-(\d+)').firstMatch(firmware?.trim() ?? '');
  return m == null ? null : [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < 4; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

/// Warnings about a file's format for a logger running `firmware` (as its startup report says).
List<String> firmwareConfigWarnings(String format, String? firmware) {
  final v = firmwareVersionNumbers(firmware);
  if (v == null || format != 'named') return const [];
  if (_compareVersions(v, [1, 0, 0, 30]) < 0) {
    return ['This logger\'s firmware ($firmware) can\'t read a named CONFIG.TXT (name = value lines): it silently '
        'uses the defaults. Update the firmware, or let the logger rewrite the file with Fix CONFIG.TXT.'];
  }
  if (_compareVersions(v, [1, 0, 0, 34]) < 0) {
    return ['This logger\'s firmware ($firmware) reads named files with slightly older rules than these checks '
        '($configRulesFirmware): no words such as "on" or "cycled", a mistake in the first setting line makes it '
        'ignore the whole file, and "-" doesn\'t undo an earlier line. Update the firmware.'];
  }
  return const [];
}

/// Checks a config file (its bytes as on the card) with the logger's own rules. fileName decides whether it is a
/// config sequence file (CONFIG01.TXT, ...); firmware (the logger's version, if known) adds warnings for older ones.
AspenConfigCheck checkAspenConfig(List<int> bytes, {String fileName = 'CONFIG.TXT', String? firmware}) {
  final result = AspenConfigCheck(fileName);
  final text = latin1.decode(bytes);
  final lines = splitConfigLines(text);
  result.format = configFileFormat(lines);
  final isSequence = configSequenceNumber(fileName) >= 0;
  var settings = <String, Object>{};
  var problemsByLine = <int, String>{};
  var labels = <int, String>{};
  if (result.format == 'utf16') {
    result.errors.add('Error: $fileName is saved as UTF-16 ("Unicode"), which the logger can\'t read: save it as plain '
        'text (UTF-8 or ANSI); using the defaults');
  } else if (result.format == 'positional') {
    final r = readPositionalConfig(text, fileName: fileName);
    result.errors.addAll(r.messages);
    result.warnings.addAll(r.warnings);
    settings = r.settings;
    problemsByLine = r.problemsByLine;
    labels = r.labels;
    result.notes.add('This is the original positional format (one value per line, in a fixed order). The named '
        'format (name = value) is easier to edit.');
  } else {
    final r = readNamedConfig(lines, sequenceFile: isSequence, fileName: isSequence ? fileName : 'CONFIG.TXT');
    result.errors.addAll(r.messages);
    settings = r.settings;
    problemsByLine = r.problemsByLine;
    if (isSequence) result.sequence = r.hasRunMinutes;
  }
  result.warnings.addAll(firmwareConfigWarnings(result.format, firmware));
  if (isSequence) {
    result.sequence ??= false;
    if (result.sequence!) {
      result.notes.add('Config sequence file: the logger uses it instead of CONFIG.TXT for ${settings['run_minutes']} '
          'min, then renames it and restarts with the next one.');
    } else {
      result.warnings.add('The logger ignores this file: a config sequence file needs a valid run_minutes line in '
          'the named format.');
    }
  }
  for (var i = 0; i < lines.length; i++) {
    final number = i + 1;
    final message = problemsByLine[number];
    result.lines.add(ConfigLineNote(number, lines[i].shown,
        setting: labels[number],
        problem: message?.replaceFirst(RegExp(r'^Error: \S+ line \d+: '), '')));
  }

  // The settings as the logger would use them: defaults, then the file, then what setup() does at startup.
  final effective = <String, Object>{
    for (final s in AspenConfigSpec.settings)
      if (s['type'] == 'number' && s['config_txt'] == true) s['name'] as String: s['default'] as int,
    for (var i = 0; i < 4; i++) 'gain${i + 1}': AspenConfigSpec.defaultGains[i],
    for (final name in ['network', 'station', 'location', 'channel1', 'channel2', 'channel3', 'channel4']) name: '-',
  }..addAll(settings);
  final gains = [for (var i = 1; i <= 4; i++) effective['gain$i'] as int];
  final rate = effective['sample_rate'] as int;
  if (rate >= 4000 && (gains[0] == 0 || gains.skip(1).any((g) => g != 0))) {
    result.errors.add('Error: $rate sps records channel 1 only; channels 2-4 off');
    gains.setAll(0, [gains[0] == 0 ? 128 : gains[0], 0, 0, 0]);
    for (var i = 0; i < 4; i++) {
      effective['gain${i + 1}'] = gains[i];
    }
  }
  for (final name in ['network', 'location']) {
    if (effective[name] == '-') effective[name] = '';
  }
  for (var i = 0; i < 4; i++) {
    if (effective['channel${i + 1}'] == '-') effective['channel${i + 1}'] = defaultChannelCodeFor(i, rate);
  }
  final codes = [for (var i = 1; i <= 4; i++) effective['channel$i'] as String];
  for (var i = 1; i < 4; i++) {
    for (var j = 0; j < i; j++) {
      if (gains[i] != 0 && gains[j] != 0 && codes[i] == codes[j]) {
        result.errors.add('Error: channel ${i + 1} has the same code as channel ${j + 1}; using XX${i + 1}');
        codes[i] = 'XX${i + 1}';
        effective['channel${i + 1}'] = codes[i];
        break;
      }
    }
  }
  result.settings.addAll(effective);
  return result;
}
