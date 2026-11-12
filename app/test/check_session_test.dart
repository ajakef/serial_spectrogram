import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/app_files.dart';
import 'package:serial_spectrogram/check_session.dart';
import 'package:serial_spectrogram/config_file.dart';
import 'package:serial_spectrogram/serial_link.dart';

/// A pretend logger on the other end of the USB cable: it restarts when the app toggles RTS, prints a short startup
/// report, and answers GN:/CF:/SVC/GT: as the firmware does (1.0.0-2, or an older one without SVC).
class _Logger {
  _Logger({this.hasSvc = true});

  final bool hasSvc;
  final written = <String>[];
  MockStreamHandlerEventSink? sink;
  var gains = [128, 32, 32, 32];
  var rate = 200;
  var restarts = 0;
  var savedText = '';
  final _running = <String, String>{}; // CF: settings applied at this boot

  void say(String text) => sink!.success(Uint8List.fromList(utf8.encode('$text\r\n')));

  void boot() {
    restarts++;
    _running.clear();
    say('[0.0] Firmware: 1.0.0-2_x');
    say('[0.3] Beginning SD card (CS pin 13, 48 MHz)...success, SDHC/SDXC, FAT32, 15.9 GB, 15.7 GB free');
    say('[2.3] Reading CONFIG.TXT...success');
    say('Enter Serial Number');
  }

  void finishBoot() {
    final r = int.tryParse(_running['sample_rate'] ?? '') ?? rate;
    say('[2.6] Serial number: 2');
    say('[3.5] Config: gains ${gains.join(',')}; $r sps; gps_mode 1, cycle 30 min, quota 20; SEED codes .00002..'
        '${r >= 400 ? 'CDF.DHZ.DHN.DHE' : 'HDF.EHZ.EHN.EHE'}');
    say('[4.2] Startup done');
  }

  Future<void> onWrite(String text) async {
    written.add(text);
    for (final line in text.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (line.startsWith('GN:')) {
        gains = line.substring(3).split(',').map(int.parse).toList();
        say('Gains accepted: ${gains.join(',')}');
      } else if (line.startsWith('CF:')) {
        final kv = line.substring(3).split('=');
        _running[kv[0]] = kv[1];
        say('Config set: ${line.substring(3)}');
      } else if (line == 'SVC' && hasSvc) {
        rate = int.parse(_running['sample_rate']!);
        savedText = 'saved';
        say('Config saved: CONFIG.TXT, 900 bytes (the old file is now CONFIG.BAK)');
      } else if (line.startsWith('GT:')) {
        say('GET error: cannot open CONFIG.TXT');
      }
    }
    if (text.endsWith('\n\n')) finishBoot(); // blank line: no more commands
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tmp;

  Future<(SerialLink, CheckSession, _Logger)> connect({bool hasSvc = true}) async {
    final logger = _Logger(hasSvc: hasSvc);
    var rts = true;
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async {
      switch (call.method) {
        case 'write':
          await logger.onWrite(utf8.decode(call.arguments as Uint8List));
        case 'setRts':
          final on = call.arguments as bool;
          if (on && !rts) Future<void>.delayed(const Duration(milliseconds: 5), logger.boot);
          rts = on;
        case 'filesDir':
          return tmp.path;
      }
      return null;
    });
    messenger.setMockStreamHandler(const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      logger.sink = sink;
    }));
    final link = SerialLink();
    final session = CheckSession(link, replyTimeout: const Duration(milliseconds: 200));
    session.start();
    link.start();
    await pumpEventQueue();
    logger.sink!.success('connected');
    logger.boot();
    await settle();
    return (link, session, logger);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('check_session_test');
    AppFiles.testRoot = tmp;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('at startup it asks only for CONFIG.TXT, so the logger runs as the file says', () async {
    final (_, session, logger) = await connect();
    expect(logger.written, ['GT:CONFIG.TXT\r\n\n']);
    expect(session.report.serialNumber, 2);
    expect(session.report.configFile!.error, contains('cannot open'));
    expect(session.report.startupDone, isTrue);
  });

  test('saving settings: sends them, saves, restarts, and checks the new boot', () async {
    final (_, session, logger) = await connect();
    final values = ConfigValues.fromReport(session.report.settings!, serialNumber: 2)..sampleRate = 400;
    await session.saveConfig(values);
    await settle(ms: 600);
    final sent = logger.written.map((w) => w.trim()).toList();
    expect(sent.skip(1).takeWhile((w) => w != 'SVC').first, 'GN:128,32,32,32');
    expect(sent, contains('CF:sample_rate=400'));
    expect(sent, contains('SVC'));
    expect(logger.rate, 400);
    expect(logger.restarts, 3); // connect, restart to send, restart to check
    expect(session.writeStage, WriteStage.done, reason: session.writeMessage);
    expect(session.report.settings!.sampleRate, 400);
  });

  test('old firmware without SVC: says so, and restarts the logger so nothing changes', () async {
    final (_, session, logger) = await connect(hasSvc: false);
    await session.saveConfig(ConfigValues.fromReport(session.report.settings!)..sampleRate = 400);
    await settle(ms: 600);
    expect(session.writeStage, WriteStage.failed);
    expect(session.writeMessage, CheckSession.noSvcReply);
    expect(logger.rate, 200);
    expect(logger.restarts, 3); // connect, restart to send, restart after failing
  });

  test('on the Plot tab it leaves the logger alone', () async {
    final (link, _, logger) = await connect();
    logger.written.clear();
    link.plotMode = true;
    logger.boot();
    await settle();
    expect(logger.written.where((w) => w.startsWith('GT:')), isEmpty);
  });

  test('each check is saved as a log file on the phone', () async {
    final (_, session, _) = await connect();
    await session.flushLog();
    final logs = await LogRecorder.saved();
    expect(logs.single.path, matches(RegExp(r'startup_logs/aspen_SN2_\d{8}_\d{6}\.txt$')));
    final text = logs.single.readAsStringSync();
    expect(text, contains('Z [0.0] Firmware: 1.0.0-2_x'));
    expect(text, contains('Z Enter Serial Number'));
  });
}

Future<void> settle({int ms = 100}) => Future<void>.delayed(Duration(milliseconds: ms));
