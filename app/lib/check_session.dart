import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_files.dart';
import 'boot_report.dart';
import 'config_file.dart';
import 'serial_link.dart';

enum WriteStage { idle, sending, saving, checking, done, failed }

/// The Check tab's connection to the logger: reads its startup report, asks it for CONFIG.TXT, saves new settings
/// to CONFIG.TXT when asked, and keeps a copy of everything it prints in a log file on the phone.
///
/// At the logger's "Enter Serial Number" prompt it sends only "GT:CONFIG.TXT" (send that file over the cable) and a
/// blank line (no more commands), so the logger runs exactly as CONFIG.TXT says. To change settings it sends them with
/// the GN:/CF: startup commands, then SVC (firmware 1.0.0-2 and later), which saves them to CONFIG.TXT; then it
/// restarts the logger and checks that the new boot reports the same settings.
class CheckSession extends ChangeNotifier {
  CheckSession(this.link, {this.replyTimeout = const Duration(seconds: 3), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    report = BootReport(clock: _clock);
  }

  final SerialLink link;
  final Duration replyTimeout;
  final DateTime Function() _clock;
  late BootReport report;
  String status = 'starting';
  final _subs = <StreamSubscription>[];
  LogRecorder? _recorder;

  static const promptTimeout = Duration(seconds: 20); // from a restart to the logger's prompt
  static const noSvcReply = 'The logger didn\'t answer the save command: its firmware is too old to save CONFIG.TXT '
      '(it needs 1.0.0-2 or newer; update it from the Plot tab). Nothing was changed.';

  // Saving settings
  ConfigValues? _pending; // to be sent at the next prompt
  ConfigValues? _saved; // saved; checked against the next boot's settings
  bool _awaitingNewBoot = false;
  WriteStage writeStage = WriteStage.idle;
  String writeMessage = '';
  List<String> _commands = [];
  int _index = 0;
  int _tries = 0;
  Timer? _timer;
  bool _notifyScheduled = false;

  bool get connected => status == 'connected';

  /// Name of the log file this check is being saved to (in [LogRecorder.folder]), if any lines have arrived.
  String? get logFileName => _recorder?.fileName;
  bool get writing => writeStage == WriteStage.sending || writeStage == WriteStage.saving || writeStage == WriteStage.checking;

  void start() {
    status = link.currentStatus;
    _subs.add(link.status.listen(_onStatus));
    _subs.add(link.lines.listen(_onLine));
  }

  /// Writes the lines received so far to the saved log (it's also written every few seconds).
  Future<void> flushLog() => _recorder?.flush() ?? Future.value();

  /// Restarts the logger to check it again.
  Future<void> checkAgain() async {
    if (connected) await link.restartLogger();
  }

  /// Sends [values] to the logger at its next startup and saves them to CONFIG.TXT. Progress is in [writeStage] and
  /// [writeMessage].
  Future<void> saveConfig(ConfigValues values) async {
    if (!connected) {
      _setWrite(WriteStage.failed, 'Plug in the logger first');
      return;
    }
    _pending = values;
    _saved = null;
    _setWrite(WriteStage.sending, 'Restarting the logger');
    _startTimer(promptTimeout, 'The logger didn\'t restart (no startup prompt). Nothing was changed.');
    await link.restartLogger();
  }

  void _onStatus(String s) {
    status = s;
    if (s == 'disconnected') {
      unawaited(_recorder?.close());
      _recorder = null;
      if (writing) _fail('The logger was unplugged before the settings were saved and checked', restart: false);
    }
    _notifySoon();
  }

  void _onLine(String raw) {
    if (link.plotMode || link.rawMode) return;
    final line = BootReport.strip(raw.trim());
    if (line.startsWith('Firmware: ') && report.lines.isNotEmpty) _newBoot();
    report.addLine(raw);
    (_recorder ??= LogRecorder(_clock)).add(raw.trim(), serial: report.serialNumber);
    if (line == 'Enter Serial Number') {
      _answerPrompt();
    } else if (_commands.isNotEmpty) {
      _onReply(line);
    }
    if (writeStage == WriteStage.checking && !_awaitingNewBoot && report.settings != null && _saved != null) _verify();
    _notifySoon();
  }

  void _newBoot() {
    unawaited(_recorder?.close());
    _recorder = null;
    report = BootReport(clock: _clock);
    _awaitingNewBoot = false;
  }

  void _answerPrompt() {
    final pending = _pending;
    if (pending == null) {
      link.write('GT:CONFIG.TXT\r\n\n'); // send CONFIG.TXT; the blank line means no more commands
      return;
    }
    _pending = null;
    _commands = [...pending.commands(), 'SVC'];
    _saved = pending;
    _index = 0;
    _tries = 0;
    _setWrite(WriteStage.sending, 'Sending the settings');
    _sendCurrent();
  }

  void _sendCurrent() {
    final command = _commands[_index];
    link.write('$command\r\n');
    _startTimer(replyTimeout, command == 'SVC' ? noSvcReply : 'The logger didn\'t answer $command. Nothing was saved.');
  }

  void _onReply(String line) {
    final command = _commands[_index];
    bool? ok; // null: not a reply to this command
    if (command.startsWith('GN:')) {
      if (line.startsWith('Gains accepted:')) ok = line.split(':').last.trim() == command.substring(3);
      if (line.startsWith('Gains rejected')) ok = false;
    } else if (command.startsWith('CF:')) {
      if (line.startsWith('Config set: ')) ok = line.substring('Config set: '.length).trim() == command.substring(3);
      if (line.startsWith('Config rejected')) ok = false;
    } else if (command == 'SVC') {
      if (line.startsWith('Config saved:')) ok = true;
      if (line.startsWith('Config save failed')) {
        _fail('The logger couldn\'t save CONFIG.TXT: ${line.substring(line.indexOf(':') + 1).trim()}');
        return;
      }
    }
    if (ok == null) return;
    _timer?.cancel();
    if (!ok) {
      // Garbled on the way: the logger keeps listening, so send it again.
      if (++_tries < 3) {
        _sendCurrent();
      } else {
        _fail('The logger kept rejecting "$command". Nothing was saved.');
      }
      return;
    }
    _index++;
    _tries = 0;
    if (_index < _commands.length) {
      if (_commands[_index] == 'SVC') _setWrite(WriteStage.saving, 'Saving CONFIG.TXT');
      _sendCurrent();
      return;
    }
    _commands = [];
    _awaitingNewBoot = true;
    _setWrite(WriteStage.checking, 'Saved. Restarting the logger to check the new CONFIG.TXT');
    _startTimer(promptTimeout, 'Saved, but the logger didn\'t restart to check it. Tap "Check again".');
    unawaited(link.restartLogger());
  }

  void _verify() {
    final saved = _saved!;
    _saved = null;
    _timer?.cancel();
    final diffs = saved.differencesFrom(report.settings!, serialNumber: report.serialNumber);
    if (diffs.isEmpty && report.configErrors.isEmpty) {
      _setWrite(WriteStage.done, 'Saved and checked: the logger read the new CONFIG.TXT');
    } else {
      _setWrite(WriteStage.failed, 'Saved, but after restarting the logger reports ${[...diffs, ...report.configErrors].join('; ')}');
    }
  }

  void _fail(String message, {bool restart = true}) {
    _timer?.cancel();
    _commands = [];
    _pending = null;
    _saved = null;
    _awaitingNewBoot = false;
    _setWrite(WriteStage.failed, message);
    // Settings sent before the failure apply until the logger restarts: restart it so it runs as CONFIG.TXT says.
    if (restart && connected) unawaited(link.restartLogger());
  }

  void _startTimer(Duration d, String message) {
    _timer?.cancel();
    _timer = Timer(d, () => _fail(message));
  }

  void _setWrite(WriteStage stage, String message) {
    writeStage = stage;
    writeMessage = message;
    _notifySoon();
  }

  /// Clears a finished save's message.
  void dismissWrite() {
    if (writing) return;
    _setWrite(WriteStage.idle, '');
  }

  // Many lines can arrive at once; redraw the screen at most 10 times a second.
  void _notifySoon() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    Timer(const Duration(milliseconds: 100), () {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_recorder?.close());
    super.dispose();
  }
}

/// Everything the logger prints during one check (one startup and the lines after it), saved on the phone in
/// startup_logs/ as `aspen_SN<serial>_<UTC time>.txt`, each line stamped with the phone's UTC time like the bench
/// recorder's captures. Written every few seconds, so a log survives the app closing; capped at [maxBytes].
class LogRecorder {
  LogRecorder(this._clock) : started = _clock();

  final DateTime Function() _clock;
  final DateTime started;
  static const folder = 'startup_logs';
  static const maxBytes = 5 * 1024 * 1024;
  static const flushInterval = Duration(seconds: 5);
  final _buffer = StringBuffer();
  int? serial;
  File? _file;
  int _bytes = 0;
  bool _full = false;
  Timer? _timer;
  Future<void> _writes = Future.value();

  String get fileName => 'aspen_${serial != null ? 'SN${serial}_' : ''}${fileStamp(started)}.txt';

  void add(String line, {int? serial}) {
    if (_full) return;
    this.serial ??= serial;
    _buffer.writeln('${isoMillis(_clock())} $line');
    _timer ??= Timer(flushInterval, () => unawaited(flush()));
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty) return _writes;
    var text = _buffer.toString();
    _buffer.clear();
    _bytes += text.length;
    if (_bytes > maxBytes) {
      _full = true;
      text += '# log capped at ${maxBytes ~/ (1024 * 1024)} MB; later lines not saved\n';
    }
    return _writes = _writes.then((_) async {
      try {
        _file ??= File('${(await AppFiles.dir(folder)).path}/$fileName');
        await _file!.writeAsString(text, mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('Could not save the startup log: $e');
      }
    });
  }

  Future<void> close() => flush();

  /// The saved logs, newest first.
  static Future<List<File>> saved() async {
    final dir = await AppFiles.dir(folder);
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.txt')).toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }
}
