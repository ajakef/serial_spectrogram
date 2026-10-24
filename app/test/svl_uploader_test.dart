import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/svl_uploader.dart';

/// A pretend Artemis bootloader on the other end of the cable, following svl.py's description of the protocol.
class FakeBoard implements SvlPort {
  FakeBoard({this.corruptFirstFrame = false, this.respondsToU = true});

  final bool corruptFirstFrame;
  final bool respondsToU;
  final List<int> toHost = [];
  final received = BytesBuilder();
  final rtsLog = <bool>[];
  int baud = 0;
  bool done = false;
  bool _corrupted = false;
  final List<int> _fromHost = [];

  void _send(int cmd, List<int> data) {
    final payload = [cmd, ...data];
    final crc = SvlUploader.crc16(payload);
    final length = payload.length + 2;
    toHost.addAll([length >> 8, length & 0xFF, ...payload, crc >> 8, crc & 0xFF]);
  }

  @override
  Future<void> writeBytes(List<int> bytes) async {
    _fromHost.addAll(bytes);
    if (_fromHost.length == 1 && _fromHost[0] == 0x55) {
      _fromHost.clear();
      if (respondsToU) _send(0x01, [0, 1]); // version
      return;
    }
    if (_fromHost.length < 2) return;
    final length = (_fromHost[0] << 8) | _fromHost[1];
    if (_fromHost.length < 2 + length) return;
    final payload = _fromHost.sublist(2, 2 + length);
    _fromHost.clear();
    expect(SvlUploader.crc16(payload), 0);
    final data = payload.sublist(1, payload.length - 2);
    switch (payload[0]) {
      case 0x02:
        _send(0x03, []); // ask for the first frame
      case 0x04:
        if (corruptFirstFrame && !_corrupted) {
          _corrupted = true;
          _send(0x05, []); // pretend the checksum failed
        } else {
          received.add(data);
          _send(0x03, []);
        }
      case 0x06:
        done = true;
    }
  }

  @override
  Future<Uint8List?> readBytes(int count, Duration timeout) async {
    if (toHost.length < count) return null;
    final bytes = Uint8List.fromList(toHost.sublist(0, count));
    toHost.removeRange(0, count);
    return bytes;
  }

  @override
  void clearInput() => toHost.clear();

  @override
  Future<void> setBaud(int b) async => baud = b;

  @override
  Future<void> setRts(bool asserted) async => rtsLog.add(asserted);
}

void main() {
  final program = Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256)); // 3 frames

  test('checksum matches svl.py', () {
    expect(SvlUploader.crc16('123456789'.codeUnits), 0xFEE8);
    expect(SvlUploader.crc16(List.generate(256, (i) => i)), 0x3B7A);
    expect(SvlUploader.crc16([3, 0, 1]), 0x8039);
  });

  test('delivers the whole program', () async {
    final board = FakeBoard();
    final progress = <double>[];
    await SvlUploader(board).upload(program, onProgress: progress.add);
    expect(board.received.takeBytes(), program);
    expect(board.done, isTrue);
    expect(board.baud, 115200);
    expect(board.rtsLog, [false, true]); // RTS released, then asserted: one reset
    expect(progress.last, 1.0);
  });

  test('resends a frame the board rejected', () async {
    final board = FakeBoard(corruptFirstFrame: true);
    await SvlUploader(board).upload(program);
    expect(board.received.takeBytes(), program);
    expect(board.done, isTrue);
  });

  test('gives up, with a useful message, if the board never answers', () async {
    final board = FakeBoard(respondsToU: false);
    await expectLater(SvlUploader(board).upload(program), throwsA(isA<SvlException>()));
    expect(board.rtsLog.length, 9); // four tries, with 2, 3, 2 and 2 RTS changes
  });

  test('recognizes program images', () {
    expect(SvlUploader.looksLikeProgram(Uint8List.fromList([0xf8, 0xff, 0x05, 0x10, 0x55, 0xf6, 0x02, 0x00])), isTrue);
    expect(SvlUploader.looksLikeProgram(Uint8List.fromList(':10000000'.codeUnits)), isFalse); // a .hex file
    expect(SvlUploader.looksLikeProgram(Uint8List(3)), isFalse);
  });

  test('refuses an empty or oversized file', () async {
    await expectLater(SvlUploader(FakeBoard()).upload(Uint8List(0)), throwsA(isA<SvlException>()));
    await expectLater(SvlUploader(FakeBoard()).upload(Uint8List(2 * 1024 * 1024)), throwsA(isA<SvlException>()));
  });
}
