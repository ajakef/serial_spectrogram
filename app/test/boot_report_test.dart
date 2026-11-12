import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/boot_report.dart';

// The startup report reader, fed a real serial capture (test/fixtures: firmware 0.8.5-75 at 400 sps x 4 channels, no
// CONFIG.TXT, bench recorder's time stamps removed) and made-up boots with problems.
void main() {
  BootReport feed(Iterable<String> lines) {
    final r = BootReport();
    for (final l in lines) {
      r.addLine(l);
    }
    return r;
  }

  test('a real boot: waits for GPS time, then OK to unplug', () {
    final lines = File('test/fixtures/boot_400x4_no_config.txt').readAsLinesSync();
    final gpsTime = lines.indexWhere((l) => RegExp(r'^H,[\d.]+,\d').hasMatch(l));
    final r = feed(lines.sublist(0, gpsTime));
    expect(r.firmware, startsWith('0.8.5-75'));
    expect(r.resetCause, contains('reset pin'));
    expect(r.serialNumber, 2);
    expect(r.startupDone, isTrue);
    expect(r.settings!.gains, [128, 128, 128, 128]);
    expect(r.settings!.sampleRate, 400);
    expect(r.settings!.channels, ['HDF', 'EHZ', 'EHN', 'EHE']);
    expect(r.items['power']!.detail, startsWith('Battery 4.'));
    expect(r.items['clock']!.state, CheckState.ok); // "failed 1 times ... then success" is normal
    expect(r.items['sd']!.state, CheckState.ok);
    expect(r.items['sd']!.detail, '15.7 GB free of 15.9 GB');
    expect(r.items['config']!.state, CheckState.warn);
    expect(r.items['config']!.detail, contains('No CONFIG.TXT'));
    // the old firmware's default codes don't follow the rate: flagged
    expect(r.items['config']!.notes, contains(contains('SEED convention for 400 sps is CDF')));
    expect(r.items['adc']!.state, CheckState.ok);
    expect(r.items['adc']!.detail, '4 channels responding');
    expect(r.items['gps']!.state, CheckState.warn);
    expect(r.overall.state, CheckState.warn);
    expect(r.overall.headline, 'Waiting for GPS time');

    for (final l in lines.sublist(gpsTime)) {
      r.addLine(l);
    }
    expect(r.gpsLocked, isTrue);
    expect(r.items['gps']!.state, CheckState.ok);
    expect(r.items['recording']!.state, CheckState.ok);
    expect(r.items['recording']!.detail, contains('20261112_042929..00002..log'));
    expect(r.items['station']!.detail, '00002 (network none, location none); serial number 2');
    expect(r.overall.state, CheckState.ok);
    expect(r.overall.headline, 'Logging: OK to unplug');
    expect(r.overall.detail, contains('warning'));
    expect(r.lines.where((l) => l.kind == LineKind.bad), isEmpty);
  });

  List<String> boot({
    String sd = 'success, SDHC/SDXC, FAT32, 15.9 GB, 15.7 GB free',
    List<String> config = const ['[2.37] Reading CONFIG.TXT...', '[2.38] Reading CONFIG.TXT...success'],
    String gps = 'answered in 200 ms, success',
    String settings = 'gains 128,64,64,64; 400 sps; gps_mode 1, cycle 30 min, quota 20, settle 20 s; compression on; '
        'SEED codes XP.00002..CDF.DHZ.DHN.DHE; files 1440 min',
    List<bool> adcs = const [true, true, true, true],
    List<String> extra = const [],
  }) =>
      [
        '[0.0] Firmware: 1.0.0-2_2026-11-12T06:16:49Z',
        '[0.1] Reset cause: reset pin (button or serial port)',
        '[0.25] Checking voltages...Vbatt 4.78 V (min 2.6), Vcc 3.28 V (min 3.1)',
        '[0.3] Beginning TCXO...success, 3262 ticks (32768/sec expected), 301 ms after power-on',
        '[0.52] Beginning SHTC3 temp/RH sensor...success',
        '[0.53] Beginning INA3221 power monitor...success',
        '[0.54] Beginning SD card (CS pin 13, 48 MHz)...',
        '[0.55] Beginning SD card (CS pin 13, 48 MHz)...$sd',
        ...config,
        'Enter Serial Number',
        '[2.6] Serial number: 2',
        '[2.6] Beginning GPS...$gps',
        '[3.5] Config: $settings',
        for (var i = 0; i < 4; i++) '[3.6] ADC${i + 1} at 12: ${adcs[i] ? 'detected' : 'not detected'}',
        ...extra,
        '[4.2] Startup done',
      ];

  test('CONFIG.TXT errors make it a problem, with the errors listed', () {
    final r = feed(boot(config: [
      '[2.37] Reading CONFIG.TXT...',
      '[2.38] Error: invalid sample rate 300 in CONFIG.TXT; using 200',
      '[2.38] Reading CONFIG.TXT...done, but invalid values were replaced by defaults (see above)',
      '[2.38] Error code 6',
    ]));
    expect(r.items['config']!.state, CheckState.fail);
    expect(r.items['config']!.notes, contains('invalid sample rate 300 in CONFIG.TXT; using 200'));
    expect(r.overall.state, CheckState.fail);
    expect(r.overall.headline, 'Problem: CONFIG.TXT');
  });

  test('no SD card: not recording', () {
    final r = feed(boot(
      sd: 'failed: card not found',
      config: ['[2.3] No SD card, so no CONFIG.TXT; using defaults', '[2.3] Error code 1'],
    ));
    expect(r.items['sd']!.state, CheckState.fail);
    expect(r.items['recording']!.state, CheckState.fail);
    expect(r.overall.headline, 'Problem: SD card');
  });

  test('an enabled channel whose ADC is missing is a problem; a disabled one is not', () {
    expect(feed(boot(adcs: [true, false, true, true])).items['adc']!.state, CheckState.fail);
    final oneChannel = feed(boot(
      settings: 'gains 128,0,0,0; 200 sps; gps_mode 1, cycle 30 min, quota 20; SEED codes XP.00002..HDF.EHZ.EHN.EHE',
      adcs: [true, false, false, false],
    ));
    expect(oneChannel.items['adc']!.state, CheckState.ok);
    expect(oneChannel.items['adc']!.detail, '1 channel responding');
  });

  test('GPS turned off in CONFIG.TXT: no waiting for GPS time, but a warning', () {
    final r = feed(boot(
      gps: 'detected, turned off (gps_mode 3)',
      settings: 'gains 128,0,0,0; 200 sps; gps_mode 3, cycle 30 min, quota 20; SEED codes XP.00002..HDF.EHZ.EHN.EHE',
      extra: ['Log renamed to 20261112_000000.XP.00002..log'],
    ));
    expect(r.items['gps']!.state, CheckState.warn);
    expect(r.overall.state, CheckState.ok);
  });

  test('settings that are allowed but probably unintended are warned about', () {
    final s = LoggerSettings.parse('Config: gains 128,64,0,64; 1000 sps; gps_mode 1, cycle 30 min, quota 10; '
        'SEED codes .1..HDF.GHZ.GHN.GHE')!;
    final w = BootReport.settingsWarnings(s);
    expect(w, contains(contains('gps_quota 10')));
    expect(w, contains(contains('Only 2 of the 3 seismic channels')));
    expect(w, contains(contains('FDF')));
    expect(w.where((x) => x.contains('GHZ')), isEmpty); // right for 1000 sps
  });

  test('CONFIG.TXT sent with GT: is decoded and checked against its CRC', () {
    const text = '128 # channel 1 gain\n0 # channel 2 gain\n';
    final b64 = base64.encode(utf8.encode(text));
    final crc = crc32(utf8.encode(text)).toRadixString(16).padLeft(8, '0');
    final r = feed(['GET begin CONFIG.TXT ${text.length}', '=$b64', 'GET end CONFIG.TXT ${text.length} $crc']);
    expect(r.configFile!.text, text);
    expect(r.configLines, isNotNull);
    final bad = feed(['GET begin CONFIG.TXT ${text.length}', '=$b64', 'GET end CONFIG.TXT ${text.length} 00000000']);
    expect(bad.configFile!.text, isNull);
    expect(bad.configFile!.error, contains('CRC'));
  });

  test('CRC-32 matches zlib', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
  });

  test('default channel codes follow the sample rate', () {
    expect([for (var i = 0; i < 4; i++) BootReport.defaultChannelCode(i, 200)], ['HDF', 'EHZ', 'EHN', 'EHE']);
    expect([for (var i = 0; i < 4; i++) BootReport.defaultChannelCode(i, 800)], ['CDF', 'DHZ', 'DHN', 'DHE']);
    expect([for (var i = 0; i < 4; i++) BootReport.defaultChannelCode(i, 1000)], ['FDF', 'GHZ', 'GHN', 'GHE']);
  });
}
