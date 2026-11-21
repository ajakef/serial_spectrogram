import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/aspen_config.dart';

// The config file checker must agree with the logger's firmware: the expected results come from aspen_config_spec.dart,
// generated from the firmware's docs/config_spec.json (written by its host tests from its own code).
void main() {
  final spec = AspenConfigSpec.json;
  List<int> bytes(String latin1Text) => latin1.encode(latin1Text);

  test('the spec copy matches the firmware (when aspen-firmware is next to this repository)', () {
    final firmware = File('../../aspen-firmware/docs/config_spec.json');
    if (!firmware.existsSync()) return;
    expect(jsonDecode(firmware.readAsStringSync()), spec, reason: 'run aspen-firmware/tools/sync_config_spec.sh');
  });

  group('lines read as the firmware reads them', () {
    for (final c in spec['line_cases'] as List) {
      final line = c['line'] as String;
      test(jsonEncode(line), () {
        final parsed = parseConfigLine(line);
        expect(parsed.status, c['status']);
        if (c.containsKey('assignments')) expect(parsed.assignments, c['assignments']);
        if (c.containsKey('suggestion')) expect(parsed.suggestion, c['suggestion']);
      });
    }
  });

  group('files read as the firmware reads them', () {
    for (final c in spec['file_cases'] as List) {
      final name = c['name'] as String;
      final text = c['text'] as String;
      test('$name ${jsonEncode(text.length > 30 ? text.substring(0, 30) : text)}', () {
        final lines = splitConfigLines(text);
        expect(configFileFormat(lines), c['format']);
        if (c['format'] != 'named') return;
        final sequence = configSequenceNumber(name) >= 0;
        final r = readNamedConfig(lines, sequenceFile: sequence, fileName: sequence ? 'CONFIG01.TXT' : 'CONFIG.TXT');
        expect(r.problems, c['problems']);
        expect(r.messages, c['messages']);
        expect(r.settings, c['settings']);
        if (c.containsKey('has_run_minutes')) expect(r.hasRunMinutes, c['has_run_minutes']);
      });
    }
  });

  test('sequence file names', () {
    for (final c in spec['sequence_names'] as List) {
      expect(configSequenceNumber(c[0] as String), c[1], reason: c[0] as String);
    }
  });

  test('the standard CONFIG.TXT is clean', () {
    final r = checkAspenConfig(bytes((spec['file_cases'] as List)[0]['text'] as String), firmware: '1.0.0-34_x');
    expect(r.format, 'named');
    expect(r.errors, isEmpty);
    expect(r.warnings, isEmpty);
    expect(r.settings['sample_rate'], 200);
    expect([for (var i = 1; i <= 4; i++) r.settings['gain$i']], [128, 128, 128, 128]);
    expect(r.settings['channel1'], 'HDF');
  });

  test('mistakes come back as the logger\'s messages, shown on their lines', () {
    final r = checkAspenConfig(utf8.encode('sample_rate = 300\ngps_mod = 1\nbluetooth = off\n'));
    expect(r.errors, [
      'Error: CONFIG.TXT line 1: sample_rate = 300 isn\'t allowed (allowed: 100, 200, 400, 800, 1000, 2000 or 4000; '
          'default 200); ignored',
      'Error: CONFIG.TXT line 2: "gps_mod" is not a setting (did you mean gps_mode?); ignored',
    ]);
    expect(r.lines[1].problem, '"gps_mod" is not a setting (did you mean gps_mode?); ignored');
    expect(r.lines[2].problem, isNull);
    expect(r.settings['bluetooth'], 0);
  });

  test('startup checks: 4000 sps, duplicate codes, band codes', () {
    var r = checkAspenConfig(utf8.encode('sample_rate = 4000\ngains = 128, 32\n'));
    expect(r.errors, contains('Error: 4000 sps records channel 1 only; channels 2-4 off'));
    r = checkAspenConfig(utf8.encode('channels = HDF, HDF\n'));
    expect(r.errors, contains('Error: channel 2 has the same code as channel 1; using XX2'));
    r = checkAspenConfig(utf8.encode('sample_rate = 400\n'));
    expect([for (var i = 1; i <= 4; i++) r.settings['channel$i']], ['CDF', 'DHZ', 'DHN', 'DHE']);
  });

  test('positional files', () {
    final good = checkAspenConfig(bytes((spec['file_cases'] as List)[1]['text'] as String));
    expect(good.format, 'positional');
    expect(good.errors, isEmpty);
    expect(good.settings['sample_rate'], 400);
    expect(good.lines[4].setting, 'sample rate');
    final bad = checkAspenConfig(utf8.encode('128 # channel 1 gain\n100 # channel 2 gain\n64\n64\n450\n1\n30\n20\n1\nXYZ\n'));
    expect(bad.errors, [
      'Error: invalid channel 2 gain 100 in CONFIG.TXT; using 128',
      'Error: invalid sample rate 450 in CONFIG.TXT; using 200',
      'Error: invalid network code "XYZ" in CONFIG.TXT; using default',
    ]);
    final shifted = checkAspenConfig(
        utf8.encode('128 # channel 1 gain\n64 # channel 2 gain\n64 # channel 3 gain\n400 # sample rate\n1 # gps_mode\n'));
    expect(shifted.warnings.any((w) => w.contains('comment says sample rate')), isTrue);
  });

  test('UTF-16 files and mistakes in the first line', () {
    final utf16 = [0xFF, 0xFE, for (final c in 'gains = 128\n'.codeUnits) ...[c, 0]];
    expect(checkAspenConfig(utf16).format, 'utf16');
    final r = checkAspenConfig(utf8.encode('gains: 128\nsample_rate = 400\n'));
    expect(r.format, 'named');
    expect(r.settings['sample_rate'], 400);
  });

  test('sequence files', () {
    final ignored = checkAspenConfig(utf8.encode('sample_rate = 400\n'), fileName: 'CONFIG1.TXT');
    expect(ignored.sequence, isFalse);
    expect(ignored.warnings.single, contains('ignores this file'));
    final used = checkAspenConfig(utf8.encode('run_minutes = 60\ntest_card_full_s = 600\n'), fileName: 'CONFIG02.TXT');
    expect(used.sequence, isTrue);
    expect(used.errors, isEmpty);
    expect(used.settings['test_card_full_s'], 600);
  });

  test('older firmware is warned about', () {
    final named = utf8.encode('sample_rate = 400\n');
    expect(checkAspenConfig(named, firmware: '0.8.5-75_2026-11-01T00:00:00Z').warnings.single,
        contains('can\'t read a named CONFIG.TXT'));
    expect(checkAspenConfig(named, firmware: '1.0.0-31_2026-11-21T21:35:40Z').warnings.single,
        contains('slightly older rules'));
    expect(checkAspenConfig(named, firmware: '1.0.0-34_2026-11-22T00:00:00Z').warnings, isEmpty);
    expect(checkAspenConfig(utf8.encode('128\n'), firmware: '0.8.5-75').warnings, isEmpty);  // positional: fine
  });
}
