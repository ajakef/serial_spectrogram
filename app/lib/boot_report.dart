import 'dart:convert';

import 'config_file.dart';

/// Reads the Aspen's startup report (the lines it prints over the cable as it starts) and the health (H) lines after
/// it, and turns them into the Check tab's checklist. Plain Dart, no Flutter, so it can be tested on a computer with
/// saved serial captures.
///
/// It matches the wording of the firmware's startup messages (aspen-firmware: bootLog lines in setup(), GPS_functions.h,
/// SD_functions.h, other_functions.h). If that wording changes, update the patterns here; lines it doesn't recognize
/// still appear in the engineer view.

enum CheckState { pending, ok, warn, fail }

class CheckItem {
  CheckItem(this.id, this.title, [this.state = CheckState.pending, this.detail = '']);
  final String id;
  final String title;
  CheckState state;
  String detail; // one short line for the field view
  final List<String> notes = []; // more lines (warnings, errors) shown under it
}

/// The settings the logger reports in its "Config:" line, once CONFIG.TXT and any startup commands are applied.
class LoggerSettings {
  LoggerSettings({
    required this.gains,
    required this.sampleRate,
    required this.gpsMode,
    required this.gpsCycleMinutes,
    required this.gpsQuota,
    this.gpsSettleS,
    this.network = '',
    this.station = '',
    this.location = '',
    this.channels = const ['', '', '', ''],
    this.fileMinutes,
  });

  final List<int> gains;
  final int sampleRate;
  final int gpsMode;
  final int gpsCycleMinutes;
  final int gpsQuota;
  final int? gpsSettleS;
  final String network;
  final String station;
  final String location;
  final List<String> channels;
  final int? fileMinutes;

  static final _gains = RegExp(r'gains (\d+),(\d+),(\d+),(\d+)');
  static final _rate = RegExp(r'(\d+) sps');
  static final _gps = RegExp(r'gps_mode (\d+), cycle (\d+) min, quota (\d+)(?:, settle (\d+) s)?');
  static final _codes = RegExp(r'SEED codes ([^;]*)');
  static final _files = RegExp(r'files (\d+) min');

  /// Reads a "Config: ..." line; null if it isn't one.
  static LoggerSettings? parse(String line) {
    if (!line.startsWith('Config: ')) return null;
    final g = _gains.firstMatch(line);
    final r = _rate.firstMatch(line);
    final p = _gps.firstMatch(line);
    if (g == null || r == null || p == null) return null;
    var codes = ['', '', '', '', '', '', ''];
    final c = _codes.firstMatch(line);
    if (c != null) {
      final parts = c[1]!.trim().split('.');
      if (parts.length == 7) codes = parts;
    }
    final f = _files.firstMatch(line);
    return LoggerSettings(
      gains: [for (var i = 1; i <= 4; i++) int.parse(g[i]!)],
      sampleRate: int.parse(r[1]!),
      gpsMode: int.parse(p[1]!),
      gpsCycleMinutes: int.parse(p[2]!),
      gpsQuota: int.parse(p[3]!),
      gpsSettleS: p[4] == null ? null : int.parse(p[4]!),
      network: codes[0],
      station: codes[1],
      location: codes[2],
      channels: codes.sublist(3),
      fileMinutes: f == null ? null : int.parse(f[1]!),
    );
  }

  int get channelCount => gains.where((g) => g > 0).length;

  /// network.station.location, as SEED writes it (blank parts stay empty).
  String get stationId => '$network.$station.$location';

  /// The same in words: "00002 (network XP, location none)".
  String get stationText =>
      '${station.isEmpty ? '?' : station} (network ${network.isEmpty ? 'none' : network}, '
      'location ${location.isEmpty ? 'none' : location})';

  String get gpsText => switch (gpsMode) {
        1 => 'on until $gpsQuota fixes, every $gpsCycleMinutes min',
        2 => 'always on',
        3 => 'off (no GPS timing)',
        4 => 'on until $gpsQuota fixes, about every $gpsCycleMinutes min (adjusted to keep timing errors small)',
        _ => 'mode $gpsMode',
      };

  String get channelsText {
    final on = [for (var i = 0; i < 4; i++) if (gains[i] > 0) i];
    if (on.isEmpty) return 'none';
    return on.map((i) => '${channels[i].isEmpty ? 'ch${i + 1}' : channels[i]} (gain ${gains[i]})').join(', ');
  }
}

/// One health (H) line: the fields every firmware version puts first.
class HealthLine {
  HealthLine(this.tcxoSec, this.utcSec, this.battV, this.monitorV, this.mA, this.tempC, this.rh, this.vcc);
  final double? tcxoSec;
  final double? utcSec; // null until the logger has GPS time
  final double? battV;
  final double? monitorV;
  final double? mA;
  final double? tempC;
  final double? rh;
  final double? vcc;

  static HealthLine? parse(String line) {
    if (!line.startsWith('H,')) return null;
    final f = line.split(',');
    if (f.length < 9) return null;
    double? d(int i) => double.tryParse(f[i]);
    return HealthLine(d(1), d(2), d(3), d(4), d(5), d(6), d(7), d(8));
  }

  /// Names of the fields after Vcc, as the 1.0.0-1 firmware writes them (#H header in its log files). Older
  /// firmware had different fields there, so the engineer view labels them only if the count matches.
  static const laterFields = [
    'maxReadTime_us', 'maxWriteTime_us', 'maxDrainTime_us', 'drainDiff_ms', 'gpsOn', 'sync', 'timeErr_us',
    'tcxo_ppm', 'adc_ppm', 'maxRetimeTime_us', 'droppedRecords', 'missedSamples', 'slowDrains', 'peakDataRing_pct',
    'peakLogRing_pct', 'gpsFixes',
  ];
  static const firstFields = ['tcxoSec', 'utcSec', 'battV', 'V', 'mA', 'tempC', 'RH', 'Vcc'];
}

/// How a line looks in the engineer view.
enum LineKind { normal, good, warn, bad, data }

class ReportLine {
  ReportLine(this.time, this.text, this.kind);
  final DateTime time; // when the phone received it
  final String text; // as received (with the logger's [seconds] stamp, if any)
  final LineKind kind;
}

/// Meanings of the red-LED error codes (ErrorCode in the firmware's src/firmware_logic.h).
const errorCodeMeanings = {
  1: 'SD card can\'t be started (missing, unreadable, or not formatted): not recording',
  2: 'SD card works, but a data file can\'t be created or written (full or damaged?): not recording',
  3: 'SD card couldn\'t keep up and some data were lost; still recording',
  4: 'An enabled channel\'s ADC didn\'t respond: that channel\'s data are bad',
  5: 'GPS didn\'t respond, or its PPS line is noisy: no GPS timing',
  6: 'CONFIG.TXT has an invalid value; the default was used instead',
  7: 'The TCXO clock isn\'t counting: using the less accurate crystal',
};

/// The raw text of a file the logger sent with the GT: command, or why it couldn't.
class FileTransfer {
  FileTransfer(this.name);
  final String name;
  final StringBuffer _base64 = StringBuffer();
  int? expectedBytes;
  String? text; // set when complete and the CRC matches
  String? error;
  bool get done => text != null || error != null;
}

class BootReport {
  BootReport({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    for (final item in _itemList) {
      items[item.id] = item;
    }
  }

  final DateTime Function() _clock;
  static const maxLines = 20000; // ~6 hours of health lines; older ones are dropped from memory (not from the saved log)

  final lines = <ReportLine>[];
  final items = <String, CheckItem>{};
  static List<CheckItem> get _itemList => [
        CheckItem('power', 'Power'),
        CheckItem('clock', 'Clock'),
        CheckItem('board', 'Temperature and power sensors'),
        CheckItem('sd', 'SD card'),
        CheckItem('config', 'CONFIG.TXT'),
        CheckItem('station', 'Station'),
        CheckItem('gps', 'GPS'),
        CheckItem('adc', 'Sensors (ADCs)'),
        CheckItem('recording', 'Recording'),
      ];

  String? firmware;
  String? resetCause;
  String? previousBootReached; // the boot before this one stopped in this step (hang or crash)
  int? serialNumber;
  LoggerSettings? settings;
  String? configValuesRead; // "CONFIG.TXT values:" line (firmware 1.0.0-2 and later)
  final configErrors = <String>[];
  bool? configFileFound; // null until known
  final errorCodes = <int>{};
  final adcDetected = <int, bool>{};
  bool startupDone = false;
  bool safeShutdown = false;
  String? logFileName;
  bool filesOpen = false;
  HealthLine? health;
  DateTime? gpsTimeAt; // when the first H line with GPS time arrived
  bool gpsFound = false;
  bool gpsOffByConfig = false;
  bool infrasoundOnlyUnit = false;
  FileTransfer? configFile; // CONFIG.TXT read with GT:
  List<ConfigLineNote>? configLines; // its lines, checked (null if not read, or not in the one-value-per-line format)
  final commandReplies = <String>[]; // "Gains accepted ...", "Config set ...", "Config saved ..." and failures
  String? currentStep; // the step the logger announced last ("Beginning SD card...")

  static final _stamp = RegExp(r'^\[\d+(?:\.\d+)?\] ');
  static final _step = RegExp(r'^(Beginning (.+?)|Checking voltages|Reading CONFIG\.TXT)\.\.\.(.*)$');
  static final _volts = RegExp(r'Vbatt ([\d.]+) V.*Vcc ([\d.]+) V');
  static final _sdSize = RegExp(r'([\d.]+) GB, ([\d.]+) GB free');
  static final _adc = RegExp(r'^ADC(\d) at \d+: (detected|not detected)$');
  static final _errorCode = RegExp(r'^Error code (\d+)');
  static final _serial = RegExp(r'^Serial number: (-?\d+)');

  bool get booted => firmware != null || lines.isNotEmpty;

  /// The logger's text without its "[seconds] " time stamp.
  static String strip(String line) => line.replaceFirst(_stamp, '');

  void addLine(String raw) {
    final line = strip(raw.trim());
    final kind = _read(line);
    if (lines.length >= maxLines) lines.removeRange(0, lines.length - maxLines + 1);
    lines.add(ReportLine(_clock(), raw.trim(), kind));
  }

  LineKind _read(String line) {
    if (line.isEmpty) return LineKind.normal;
    // GT: file transfer (CONFIG.TXT)
    if (line.startsWith('GET begin ')) {
      final parts = line.split(' ');
      configFile = FileTransfer(parts.length > 2 ? parts[2] : '?')
        ..expectedBytes = parts.length > 3 ? int.tryParse(parts[3]) : null;
      return LineKind.normal;
    }
    if (line.startsWith('=') && configFile != null && !configFile!.done) {
      configFile!._base64.write(line.substring(1));
      return LineKind.data;
    }
    if (line.startsWith('GET end ')) {
      _finishTransfer(line);
      _update();
      return LineKind.normal;
    }
    if (line.startsWith('GET error')) {
      configFile = FileTransfer('CONFIG.TXT')..error = line;
      return LineKind.normal;
    }

    final h = HealthLine.parse(line);
    if (h != null) {
      health = h;
      if (h.utcSec != null && gpsTimeAt == null) gpsTimeAt = _clock();
      _update();
      return LineKind.data;
    }
    if (line.startsWith('Firmware: ')) {
      firmware = line.substring('Firmware: '.length).trim();
      _update();
      return LineKind.normal;
    }
    if (line.startsWith('Reset cause:')) {
      resetCause = line.substring('Reset cause:'.length).trim();
      return LineKind.normal;
    }
    if (line.startsWith('Previous boot reached: ')) {
      previousBootReached = line.substring('Previous boot reached: '.length).trim();
      return LineKind.warn;
    }
    if (line.startsWith('Infrasound-only unit')) {
      infrasoundOnlyUnit = true;
      return LineKind.normal;
    }
    if (line.startsWith('CONFIG.TXT values: ')) {
      configValuesRead = line.substring('CONFIG.TXT values: '.length);
      return LineKind.normal;
    }
    if (line == 'No CONFIG.TXT; using defaults') {
      configFileFound = false;
      _update();
      return LineKind.warn;
    }
    if (line == 'No SD card, so no CONFIG.TXT; using defaults') {
      configFileFound = false;
      _update();
      return LineKind.bad;
    }
    if (line.startsWith('Error: ')) {
      configErrors.add(line.substring('Error: '.length));
      _update();
      return LineKind.bad;
    }
    final err = _errorCode.firstMatch(line);
    if (err != null) {
      errorCodes.add(int.parse(err[1]!));
      _update();
      return LineKind.bad;
    }
    final sn = _serial.firstMatch(line);
    if (sn != null) {
      serialNumber = int.parse(sn[1]!);
      _update();
      return LineKind.normal;
    }
    final settingsLine = LoggerSettings.parse(line);
    if (settingsLine != null) {
      settings = settingsLine;
      _update();
      return LineKind.normal;
    }
    final adc = _adc.firstMatch(line);
    if (adc != null) {
      final ok = adc[2] == 'detected';
      adcDetected[int.parse(adc[1]!)] = ok;
      _update();
      return ok ? LineKind.normal : LineKind.bad;
    }
    if (line == 'Startup done') {
      startupDone = true;
      currentStep = null;
      _update();
      return LineKind.good;
    }
    if (line.startsWith('Log renamed to ')) {
      logFileName = line.substring('Log renamed to '.length).trim();
      filesOpen = true;
      _update();
      return LineKind.good;
    }
    if (line.startsWith('Opened ') && line.contains('.mseed')) {
      filesOpen = true;
      _update();
      return LineKind.normal;
    }
    if (line.startsWith('Beginning safe shutdown')) {
      safeShutdown = true;
      _update();
      return LineKind.bad;
    }
    if (line.startsWith('Gains accepted') || line.startsWith('Config set') || line.startsWith('Config saved')) {
      commandReplies.add(line);
      return LineKind.good;
    }
    if (line.startsWith('Gains rejected') || line.startsWith('Config rejected') || line.startsWith('Config save failed')) {
      commandReplies.add(line);
      return LineKind.bad;
    }
    final step = _step.firstMatch(line);
    if (step != null) {
      final name = step[2] ?? step[1]!;
      final result = step[3]!.trim();
      if (result.isEmpty) {
        currentStep = name;
        return LineKind.normal;
      }
      currentStep = null;
      _stepResult(name, result);
      _update();
      return stepSucceeded(result) || name == 'Checking voltages' ? LineKind.normal : LineKind.bad;
    }
    if (line.startsWith('GPS sent: ')) return LineKind.data;
    return LineKind.normal;
  }

  /// Whether a step's result says it worked: "success", "answered in 200 ms, success", "failed 1 times (...), then
  /// success, ..." (the TCXO's normal start).
  static bool stepSucceeded(String result) => RegExp(r'(^|, |then )success').hasMatch(result);

  // Results of "Beginning X...result" steps.
  String? tcxoResult, shtc3Result, inaResult, sdResult, gpsResult, configResult;
  double? bootBattV, bootVcc;
  double? cardGb, cardFreeGb;

  void _stepResult(String name, String result) {
    if (name == 'Checking voltages') {
      final v = _volts.firstMatch(result);
      if (v != null) {
        bootBattV = double.tryParse(v[1]!);
        bootVcc = double.tryParse(v[2]!);
      }
    } else if (name.startsWith('TCXO')) {
      tcxoResult = result;
    } else if (name.startsWith('SHTC3')) {
      shtc3Result = result;
    } else if (name.startsWith('INA3221')) {
      inaResult = result;
    } else if (name.startsWith('SD card')) {
      sdResult = result;
      final s = _sdSize.firstMatch(result);
      if (s != null) {
        cardGb = double.tryParse(s[1]!);
        cardFreeGb = double.tryParse(s[2]!);
      }
    } else if (name.startsWith('GPS')) {
      gpsResult = result;
      gpsOffByConfig = result.contains('gps_mode 3');
      gpsFound = result.contains('success') || result.startsWith('detected, turned off') || result.contains('acknowledged');
    } else if (name == 'Reading CONFIG.TXT') {
      configResult = result;
      configFileFound = !result.startsWith('failed to open');
    }
  }

  void _finishTransfer(String line) {
    final t = configFile;
    if (t == null || t.done) return;
    final parts = line.split(' '); // GET end <name> <bytes> <crc>
    try {
      final bytes = base64.decode(t._base64.toString());
      final crc = parts.length > 4 ? int.parse(parts[4], radix: 16) : null;
      if (crc != null && crc32(bytes) != crc) {
        t.error = 'garbled on the way (CRC mismatch)';
      } else {
        t.text = utf8.decode(bytes, allowMalformed: true);
      }
    } catch (e) {
      t.error = 'garbled on the way ($e)';
    }
  }

  /// Seconds from startup done (or now) that GPS time has been awaited; used for "waiting" messages.
  bool get gpsLocked => health?.utcSec != null;

  bool get gpsExpected => !(gpsOffByConfig || settings?.gpsMode == 3);

  void _update() {
    final s = settings;
    // Power: printed only; the user judges whether it's enough.
    final power = items['power']!;
    final battV = health?.battV ?? bootBattV;
    if (battV != null) {
      power.state = safeShutdown ? CheckState.fail : CheckState.ok;
      power.detail = 'Battery ${battV.toStringAsFixed(2)} V'
          '${health?.mA != null ? ', drawing ${health!.mA!.toStringAsFixed(1)} mA' : ''}';
    }
    if (safeShutdown) power.detail = 'Voltage too low: the logger shut itself down';

    // Clock
    final clock = items['clock']!;
    if (errorCodes.contains(7)) {
      clock
        ..state = CheckState.warn
        ..detail = 'TCXO not counting: using the less accurate crystal';
    } else if (tcxoResult != null) {
      final ok = stepSucceeded(tcxoResult!);
      clock
        ..state = ok ? CheckState.ok : CheckState.warn
        ..detail = ok ? 'TCXO running' : 'TCXO problem: $tcxoResult';
    }

    // Board sensors
    final board = items['board']!;
    if (shtc3Result != null || inaResult != null) {
      final bad = [
        if (shtc3Result != null && !stepSucceeded(shtc3Result!)) 'temperature/humidity sensor $shtc3Result',
        if (inaResult != null && !stepSucceeded(inaResult!)) 'power monitor $inaResult',
      ];
      board
        ..state = bad.isEmpty ? CheckState.ok : CheckState.warn
        ..detail = bad.isEmpty
            ? (health?.tempC != null ? '${health!.tempC!.toStringAsFixed(1)} °C, ${health!.rh?.toStringAsFixed(0) ?? '?'}% RH' : 'Working')
            : 'Readings will be missing from the log (recording unaffected)';
      board.notes
        ..clear()
        ..addAll(bad);
    }

    // SD card
    final sd = items['sd']!;
    if (errorCodes.contains(1) || (sdResult != null && !stepSucceeded(sdResult!))) {
      sd
        ..state = CheckState.fail
        ..detail = 'Not working: nothing will be recorded';
      sd.notes
        ..clear()
        ..add(sdResult ?? errorCodeMeanings[1]!);
    } else if (errorCodes.contains(2)) {
      sd
        ..state = CheckState.fail
        ..detail = 'Can\'t write files (full or damaged?): not recording';
    } else if (sdResult != null) {
      sd
        ..state = errorCodes.contains(3) ? CheckState.warn : CheckState.ok
        ..detail = cardFreeGb != null
            ? '${cardFreeGb!.toStringAsFixed(1)} GB free of ${cardGb!.toStringAsFixed(1)} GB'
            : 'Working';
      if (errorCodes.contains(3)) sd.notes.add(errorCodeMeanings[3]!);
    }

    // CONFIG.TXT
    final config = items['config']!;
    config.notes
      ..clear()
      ..addAll(configErrors);
    if (configFileFound == false) {
      final noCard = sdResult != null && !stepSucceeded(sdResult!);
      config
        ..state = noCard ? CheckState.fail : CheckState.warn
        ..detail = noCard ? 'Can\'t be read without an SD card: using defaults' : 'No CONFIG.TXT on the card: using defaults';
    } else if (configFileFound == true || configResult != null) {
      final bad = configErrors.isNotEmpty || errorCodes.contains(6) || configResult?.startsWith('failed') == true;
      config
        ..state = bad ? CheckState.fail : CheckState.ok
        ..detail = bad ? 'Has problems: defaults used for the values below' : 'Read without errors';
    } else if (configErrors.isNotEmpty) {
      config
        ..state = CheckState.fail
        ..detail = 'Has problems';
    }
    if (s != null) config.notes.addAll(settingsWarnings(s));
    final fileText = configFile?.text;
    if (fileText != null) {
      configLines = checkConfigFile(fileText);
      for (final note in configLines ?? const <ConfigLineNote>[]) {
        if (note.problem != null) config.notes.add('Line ${note.lineNumber}: ${note.problem}');
      }
    }
    if (config.state == CheckState.ok && config.notes.isNotEmpty) config.state = CheckState.warn;

    // Station
    final station = items['station']!;
    if (s != null) {
      station
        ..state = s.network.isEmpty ? CheckState.warn : CheckState.ok
        ..detail = '${s.stationText}${serialNumber != null ? '; serial number $serialNumber' : ''}';
      station.notes
        ..clear()
        ..addAll([if (s.network.isEmpty) 'No network code']);
    } else if (serialNumber != null) {
      station.detail = 'Serial number $serialNumber';
    }

    // GPS
    final gps = items['gps']!;
    if (errorCodes.contains(5) && !gpsLocked) {
      gps
        ..state = CheckState.fail
        ..detail = 'Not working: no GPS timing';
      gps.notes
        ..clear()
        ..add(gpsResult ?? errorCodeMeanings[5]!);
    } else if (!gpsExpected) {
      gps
        ..state = CheckState.warn
        ..detail = 'Turned off in CONFIG.TXT (gps_mode 3): no GPS timing';
    } else if (gpsLocked) {
      gps
        ..state = CheckState.ok
        ..detail = 'Has GPS time';
    } else if (gpsResult != null) {
      gps
        ..state = gpsFound ? CheckState.warn : CheckState.fail
        ..detail = gpsFound ? 'Waiting for GPS time (keep the antenna\'s view of the sky clear)' : 'Not detected: $gpsResult';
    }

    // ADCs: only enabled channels matter.
    final adc = items['adc']!;
    if (s != null && (adcDetected.isNotEmpty || startupDone)) {
      final missing = [
        for (var i = 0; i < 4; i++)
          if (s.gains[i] > 0 && adcDetected[i + 1] != true) 'channel ${i + 1}${s.channels[i].isEmpty ? '' : ' (${s.channels[i]})'}',
      ];
      if (missing.isNotEmpty && (startupDone || adcDetected.length >= 4)) {
        adc
          ..state = CheckState.fail
          ..detail = 'Not responding: ${missing.join(', ')}';
      } else if (missing.isEmpty) {
        adc
          ..state = CheckState.ok
          ..detail = '${s.channelCount} channel${s.channelCount == 1 ? '' : 's'} responding';
      }
    } else if (errorCodes.contains(4)) {
      adc
        ..state = CheckState.fail
        ..detail = errorCodeMeanings[4]!;
    }

    // Recording
    final rec = items['recording']!;
    if (sd.state == CheckState.fail) {
      rec
        ..state = CheckState.fail
        ..detail = 'Not recording (SD card)';
    } else if (filesOpen) {
      rec
        ..state = CheckState.ok
        ..detail = logFileName != null ? 'Writing ${logFileName!}' : 'Writing data files';
    } else if (startupDone) {
      rec
        ..state = CheckState.warn
        ..detail = 'Started; files open when GPS time arrives (data are kept until then)';
    }
  }

  /// Settings that are allowed but probably not intended (shown as amber warnings).
  static List<String> settingsWarnings(LoggerSettings s) {
    final out = <String>[];
    if (s.gpsMode == 3) out.add('gps_mode 3: GPS off, so the data have no GPS timing');
    if (s.gpsMode != 2 && s.gpsMode != 3 && s.gpsQuota < 20) {
      out.add('gps_quota ${s.gpsQuota} is below 20 (10 gave timing errors in Nov 2026 tests)');
    }
    final seismic = s.gains.sublist(1);
    final on = seismic.where((g) => g > 0).length;
    if (on > 0 && on < 3) out.add('Only $on of the 3 seismic channels are on');
    final have = <String>[], want = <String>[];
    for (var i = 0; i < 4; i++) {
      final code = s.channels[i];
      if (s.gains[i] == 0 || code.length != 3) continue;
      final expected = seedBandCode(s.sampleRate, longPeriod: i == 0);
      if (expected != null && code[0] != expected) {
        have.add(code);
        want.add('$expected${code.substring(1)}');
      }
    }
    if (have.isNotEmpty) {
      out.add('Channel code${have.length == 1 ? '' : 's'} ${have.join(', ')}: the SEED convention for '
          '${s.sampleRate} sps is ${want.join(', ')}');
    }
    return out;
  }

  /// SEED band code for a sample rate (as the firmware's seedBandCode): H/E at 80-250 sps, C/D at 250-1000, F/G at
  /// 1000-5000. longPeriod: the sensor's corner period is 10 s or more (infrasound), otherwise shorter (geophones).
  static String? seedBandCode(int sampleRate, {required bool longPeriod}) {
    if (sampleRate >= 80 && sampleRate < 250) return longPeriod ? 'H' : 'E';
    if (sampleRate >= 250 && sampleRate < 1000) return longPeriod ? 'C' : 'D';
    if (sampleRate >= 1000 && sampleRate < 5000) return longPeriod ? 'F' : 'G';
    return null;
  }

  /// Default channel code for channel index 0-3 at a sample rate (the firmware's defaultChannelCode, 1.0.0-1 and later).
  static String defaultChannelCode(int index, int sampleRate) {
    final band = seedBandCode(sampleRate, longPeriod: index == 0) ?? (index == 0 ? 'H' : 'E');
    return band + const ['DF', 'HZ', 'HN', 'HE'][index];
  }

  /// Overall verdict for the banner at the top of the Check tab.
  ({CheckState state, String headline, String detail}) get overall {
    if (!booted) {
      return (state: CheckState.pending, headline: 'Waiting for the logger to start', detail: '');
    }
    final fails = items.values.where((i) => i.state == CheckState.fail).toList();
    if (fails.isNotEmpty) {
      return (state: CheckState.fail, headline: 'Problem: ${fails.first.title}', detail: fails.first.detail);
    }
    if (!startupDone) {
      return (
        state: CheckState.pending,
        headline: 'Starting up',
        detail: currentStep != null ? '$currentStep...' : '',
      );
    }
    if (gpsExpected && !gpsLocked) {
      return (state: CheckState.warn, headline: 'Waiting for GPS time', detail: 'Don\'t unplug yet');
    }
    final warns = items.values.where((i) => i.state == CheckState.warn).length;
    return (
      state: CheckState.ok,
      headline: 'Logging: OK to unplug',
      detail: warns == 0 ? '' : '$warns warning${warns == 1 ? '' : 's'} below',
    );
  }
}

/// CRC-32 as zlib computes it (the logger's GT: command sends one).
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
