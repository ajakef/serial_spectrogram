import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'raw_color_editor.dart';
import 'raw_colors.dart';
import 'serial_link.dart';

/// How the Raw tab turns with the phone.
enum RawOrientation { auto, portrait, landscape }

/// The Raw tab: every character the logger (or another serial device) sends, as plain text, like a serial monitor.
/// The baud rate can be changed to read devices other than the Aspen; it goes back to the Aspen's when you leave the tab.
class RawScreen extends StatefulWidget {
  const RawScreen({super.key, required this.link});

  final SerialLink link;

  /// Baud rates in the menu.
  static const bauds = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 500000, 921600];

  /// Lines kept; older ones are dropped.
  static const maxLines = 3000;

  @override
  State<RawScreen> createState() => _RawScreenState();
}

class _RawScreenState extends State<RawScreen> {
  static const _lineHeight = 16.0;
  static const _textStyle = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 16 / 12);
  static const _margin = 8.0;

  /// Width of one character (the font is monospaced).
  static final double _charWidth = (TextPainter(
    text: const TextSpan(text: '0000000000', style: _textStyle),
    textDirection: TextDirection.ltr,
  )..layout())
          .width /
      10;

  final _scroll = ScrollController();
  final _lines = <String>[];
  final _partial = <int>[]; // bytes of the line still being received
  final _decoder = const Utf8Decoder(allowMalformed: true);
  bool _dirty = false;
  int _maxChars = 0; // longest line seen (until Clear), for how far the text can be dragged sideways
  double _sideways = 0; // how far the text is dragged to the left
  int _dropped = 0; // lines removed from the top since the last redraw
  bool autoscroll = true;
  RawColorScheme? scheme; // saved on the phone; null until one is made
  RawOrientation orientation = RawOrientation.auto;
  late int baud = widget.link.baud;
  String status = '';
  Timer? _timer;
  final _subs = <StreamSubscription>[];

  SerialLink get link => widget.link;

  @override
  void initState() {
    super.initState();
    status = link.currentStatus;
    RawColorScheme.load().then((loaded) {
      if (mounted && scheme == null && loaded != null) setState(() => scheme = loaded);
    });
    _subs.add(link.bytes.listen(_addBytes));
    _subs.add(link.status.listen((s) {
      if (s == 'connected' && baud != SerialLink.normalBaud) {
        // Unplugged and replugged: the port opened at the logger's rate again, so put back the chosen one.
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (mounted) link.setBaud(baud);
        });
      }
      if (mounted) setState(() => status = s);
    }));
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_dirty) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _scroll.dispose();
    SystemChrome.setPreferredOrientations([]); // back to turning with the phone
    super.dispose();
  }

  /// Splits the incoming bytes into lines (on \n; \r is dropped). The unfinished last line is shown too, so prompts
  /// that don't end in a newline are visible.
  void _addBytes(Uint8List bytes) {
    for (final b in bytes) {
      if (b == 0x0A) {
        _lines.add(_decode(_partial));
        _partial.clear();
      } else if (b != 0x0D) {
        _partial.add(b);
        if (_partial.length >= 500) { // a line this long is probably not text: break it up
          _lines.add(_decode(_partial));
          _partial.clear();
        }
      }
    }
    if (_partial.length > _maxChars) _maxChars = _partial.length;
    final extra = _lines.length - RawScreen.maxLines;
    if (extra > 0) {
      _lines.removeRange(0, extra);
      _dropped += extra;
    }
    _dirty = true;
  }

  String _decode(List<int> bytes) {
    final line = _decoder.convert(bytes);
    if (line.length > _maxChars) _maxChars = line.length;
    return line;
  }

  int get _count => _lines.length + (_partial.isEmpty ? 0 : 1);

  String _lineAt(int i) => i < _lines.length ? _lines[i] : _decoder.convert(_partial);

  void _afterBuild() {
    final dropped = _dropped;
    _dropped = 0;
    _dirty = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (autoscroll) {
        _stickToEnd(2);
      } else if (dropped > 0) {
        // Keep the lines the user is reading in place while the oldest ones fall off the top.
        _scroll.jumpTo((_scroll.offset - dropped * _lineHeight).clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  /// Scrolls to the end. The list's length is only up to date after the frame that follows a change, so this
  /// checks again on the next frames.
  void _stickToEnd(int checksLeft) {
    if (!mounted || !_scroll.hasClients || !autoscroll) return;
    final end = _scroll.position.maxScrollExtent;
    if (_scroll.offset != end) _scroll.jumpTo(end);
    if (checksLeft > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _stickToEnd(checksLeft - 1));
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  Future<void> _setBaud(int value) async {
    setState(() => baud = value);
    if (status == 'connected') {
      try {
        await link.setBaud(value);
      } catch (e) {
        if (mounted) setState(() => status = 'error: $e');
      }
    }
  }

  void _setOrientation(RawOrientation o) {
    setState(() => orientation = o);
    SystemChrome.setPreferredOrientations(switch (o) {
      RawOrientation.auto => [],
      RawOrientation.portrait => [DeviceOrientation.portraitUp],
      RawOrientation.landscape => [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    });
  }

  Future<void> _editColors() async {
    final recent = [
      for (var i = _lines.length - 1; i >= 0 && _lines.length - i <= 60; i--) _lines[i], // newest first
    ];
    final made = await Navigator.push<RawColorScheme>(
        context, MaterialPageRoute(builder: (_) => RawColorEditor(recentLines: recent, current: scheme)));
    if (made == null || !mounted) return;
    setState(() => scheme = made);
    await made.save();
  }

  void _setColorsOn(bool on) {
    final current = scheme;
    if (current == null) {
      _editColors(); // nothing saved yet: make one
      return;
    }
    setState(() => current.enabled = on);
    current.save();
  }

  /// The only way the Raw tab restarts the logger (connecting doesn't).
  Future<void> _restart() => link.restartLogger();

  void _clear() {
    setState(() {
      _lines.clear();
      _partial.clear();
      _maxChars = 0;
      _sideways = 0;
      _dirty = false;
    });
  }

  Widget _toolbar() {
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Baud '),
              DropdownButton<int>(
                value: baud,
                items: [for (final b in RawScreen.bauds) DropdownMenuItem(value: b, child: Text('$b'))],
                onChanged: (b) {
                  if (b != null) _setBaud(b);
                },
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                value: autoscroll,
                onChanged: (v) => setState(() => autoscroll = v ?? true),
              ),
              const Text('Autoscroll'),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Rotation '),
              DropdownButton<RawOrientation>(
                value: orientation,
                items: const [
                  DropdownMenuItem(value: RawOrientation.auto, child: Text('Follow phone')),
                  DropdownMenuItem(value: RawOrientation.portrait, child: Text('Portrait')),
                  DropdownMenuItem(value: RawOrientation.landscape, child: Text('Landscape')),
                ],
                onChanged: (o) {
                  if (o != null) _setOrientation(o);
                },
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: scheme?.enabled ?? false, onChanged: (v) => _setColorsOn(v ?? false)),
              const Text('Colors'),
              IconButton(tooltip: 'Make or change the colors', icon: const Icon(Icons.palette_outlined), onPressed: _editColors),
            ]),
            IconButton(
              tooltip: 'Restart the logger',
              icon: const Icon(Icons.restart_alt),
              onPressed: status == 'connected' ? _restart : null,
            ),
            IconButton(tooltip: 'Clear the text', icon: const Icon(Icons.delete_outline), onPressed: _clear),
          ],
        ),
      ),
    );
  }

  /// One line, in the saved colors if they're on and the line has the right number of fields.
  Widget _lineWidget(String line) {
    final span = scheme?.span(line, _textStyle.copyWith(color: Colors.black));
    return span == null ? Text(line, style: _textStyle, softWrap: false) : Text.rich(span, softWrap: false);
  }

  /// The lines. Dragging sideways moves all of them together, so the scroll bar stays at the right edge.
  Widget _text(int count) {
    return LayoutBuilder(builder: (context, box) {
      final contentWidth = _maxChars * _charWidth + 2 * _margin;
      final room = (contentWidth - box.maxWidth).clamp(0.0, double.infinity); // how far the text can move
      if (_sideways > room) _sideways = room;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => setState(() => _sideways = (_sideways - d.delta.dx).clamp(0.0, room)),
        child: Stack(
          children: [
            NotificationListener<ScrollUpdateNotification>(
              onNotification: (n) {
                // Dragging the text away from the bottom stops autoscrolling (tick the box to resume).
                if (autoscroll && n.dragDetails != null && n.metrics.extentAfter > _lineHeight) {
                  setState(() => autoscroll = false);
                }
                return false;
              },
              child: Scrollbar(
                controller: _scroll,
                child: ClipRect(
                  child: ListView.builder(
                    controller: _scroll,
                    itemExtent: _lineHeight,
                    itemCount: count,
                    itemBuilder: (_, i) => Transform.translate(
                      offset: Offset(_margin - _sideways, 0),
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 0,
                        maxWidth: double.infinity,
                        child: _lineWidget(_lineAt(i)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (room > 0) // where the window is within the longest line
              Positioned(
                left: box.maxWidth * _sideways / contentWidth,
                bottom: 0,
                width: box.maxWidth * box.maxWidth / contentWidth,
                height: 3,
                child: const IgnorePointer(child: ColoredBox(color: Colors.black38)),
              ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    _afterBuild();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(),
            if (status != 'connected')
              Container(
                width: double.infinity,
                color: Colors.grey.shade300,
                padding: const EdgeInsets.only(left: 12),
                child: Row(children: [
                  Expanded(child: Text(status == 'disconnected' || status == 'no device' ? 'Not connected' : status)),
                  TextButton(onPressed: () => link.connect(reset: false), child: const Text('Connect')),
                ]),
              ),
            Expanded(child: _text(count)),
          ],
        ),
      ),
    );
  }
}
