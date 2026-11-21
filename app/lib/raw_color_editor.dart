import 'package:flutter/material.dart';

import 'raw_colors.dart';

/// Where the Raw tab's color scheme is made: pick one of the recent lines as the example (its commas show which
/// field is which), then tap a field to choose its colors. The result applies only to lines with the same number of fields.
class RawColorEditor extends StatefulWidget {
  const RawColorEditor({super.key, required this.recentLines, this.current, required this.onChanged});

  /// Recent lines from the Raw tab, newest first.
  final List<String> recentLines;
  final RawColorScheme? current;

  /// Called after every change, so the Raw tab can apply and save it (there is no Save button).
  final void Function(RawColorScheme) onChanged;

  @override
  State<RawColorEditor> createState() => _RawColorEditorState();
}

class _RawColorEditorState extends State<RawColorEditor> {
  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

  late List<FieldStyle> styles;
  late Delimiter delimiter;
  final _custom = TextEditingController();
  bool useCustom = false;
  int selected = 0;

  /// Recent lines that contain the delimiter at least once.
  List<String> get lines => [for (final l in widget.recentLines) if (delimiter.appearsIn(l)) l];

  @override
  void initState() {
    super.initState();
    styles = [...?widget.current?.styles];
    delimiter = widget.current?.delimiter ?? _bestGuess();
    if (!Delimiter.presets.contains(delimiter)) {
      useCustom = true;
      _custom.text = delimiter.text;
    }
    // Start from a recent line that fits the saved scheme; otherwise the newest line.
    final fit = widget.current == null ? -1 : lines.indexWhere((l) => widget.current!.split(l) != null);
    selected = fit < 0 ? 0 : fit;
    if (lines.isNotEmpty) _resize();
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  /// With nothing saved: the first of comma, comma and space, tab, or spaces that the newest line has.
  Delimiter _bestGuess() {
    for (final d in [Delimiter.commaSpace, Delimiter.comma, Delimiter.tab, Delimiter.spaces]) {
      if (widget.recentLines.any(d.appearsIn)) return d;
    }
    return Delimiter.comma;
  }

  List<String> get fields {
    final l = lines;
    return l.isEmpty ? const [] : delimiter.split(l[selected.clamp(0, l.length - 1)]).fields;
  }

  void _setDelimiter(Delimiter d) => setState(() {
        delimiter = d;
        selected = 0;
        _resize();
        _autosave();
      });

  /// One style per field of the chosen example line: kept for fields that were already styled, plain for new ones.
  void _resize() {
    final n = fields.length;
    styles = [for (var i = 0; i < n; i++) i < styles.length ? styles[i] : const FieldStyle()];
  }

  /// Applies and saves the current choices (when there is a line to base them on).
  void _autosave() {
    if (lines.isEmpty || fields.isEmpty) return;
    widget.onChanged(RawColorScheme(styles: [...styles], delimiter: delimiter, enabled: true)); // changing colors turns them on
  }

  /// The menu's value: a preset, or null for "Other".
  Delimiter? get _menuValue => useCustom ? null : delimiter;

  void _pick(int i) => setState(() {
        selected = i;
        _resize();
      });

  Future<void> _editField(int i) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (context, setSheet) {
        void change(FieldStyle s) {
          setState(() => styles[i] = s);
          setSheet(() {});
          _autosave();
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Field ${i + 1}: ${fields[i].isEmpty ? '(empty)' : fields[i]}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text('Text color'),
                const SizedBox(height: 6),
                _swatches(textPalette, styles[i].text, (c) => change(styles[i].copyWith(text: c, clearText: c == null))),
                const SizedBox(height: 12),
                const Text('Highlight color'),
                const SizedBox(height: 6),
                _swatches(highlightPalette, styles[i].highlight,
                    (c) => change(styles[i].copyWith(highlight: c, clearHighlight: c == null))),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hide this field'),
                  subtitle: const Text('Leaves it out of the lines on the Raw tab'),
                  value: styles[i].hidden,
                  onChanged: (v) => change(styles[i].copyWith(hidden: v)),
                ),
                Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _swatches(List<Color?> palette, Color? chosen, void Function(Color?) onTap) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final c in palette)
          GestureDetector(
            onTap: () => onTap(c),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c ?? Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: c == chosen ? Colors.black : Colors.black26, width: c == chosen ? 3 : 1),
              ),
              child: c == null ? const Icon(Icons.block, size: 20, color: Colors.black45) : null,
            ),
          ),
      ],
    );
  }

  /// A line as it will look with the colors chosen so far (plain if it has a different number of fields).
  Widget _preview(String line) {
    final span = RawColorScheme(styles: styles, delimiter: delimiter).span(line, _mono.copyWith(color: Colors.black), showHidden: true);
    return Text.rich(span ?? TextSpan(text: line, style: _mono), softWrap: false, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    final f = fields;
    final lines = this.lines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Colors for lines'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('What separates the fields?', style: TextStyle(fontWeight: FontWeight.bold)),
          Row(children: [
            DropdownButton<Delimiter?>(
              value: _menuValue,
              items: [
                for (final d in Delimiter.presets) DropdownMenuItem(value: d, child: Text(d.label)),
                const DropdownMenuItem(value: null, child: Text('Other...')),
              ],
              onChanged: (d) {
                if (d == null) {
                  setState(() => useCustom = true);
                  if (_custom.text.isNotEmpty) _setDelimiter(Delimiter(_custom.text));
                } else {
                  setState(() => useCustom = false);
                  _setDelimiter(d);
                }
              },
            ),
            if (useCustom)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: TextField(
                    controller: _custom,
                    decoration: const InputDecoration(hintText: 'type it here', isDense: true),
                    onChanged: (t) => _setDelimiter(Delimiter(t)),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No recent lines contain that separator. Plug in the logger, let some data arrive on the Raw '
                  'tab, or choose another separator.'),
            )
          else ...[
                Text(
                  'Colors are used only for lines with exactly ${f.length} fields (${f.length - 1} separators), '
                  'like the line you pick here. Other lines stay plain.',
                ),
                const SizedBox(height: 12),
                const Text('1. Pick an example line', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  height: 170,
                  decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
                  child: ListView.builder(
                    itemCount: lines.length,
                    itemExtent: 28,
                    itemBuilder: (_, i) => InkWell(
                      onTap: () => _pick(i),
                      child: Container(
                        color: i == selected ? Colors.blue.withValues(alpha: 0.15) : null,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        child: _preview(lines[i]),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('2. Tap a field to choose its colors, or to hide it', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < f.length; i++)
                      ActionChip(
                        onPressed: () => _editField(i),
                        backgroundColor: styles[i].highlight ?? Colors.grey.shade200,
                        label: Text(
                          '${i + 1}: ${f[i].isEmpty ? '(empty)' : f[i]}',
                          style: _mono.copyWith(color: styles[i].text ?? Colors.black, decoration: styles[i].hidden ? TextDecoration.lineThrough : null),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => styles = [for (final _ in styles) const FieldStyle()]);
                      _autosave();
                    },
                    icon: const Icon(Icons.format_color_reset),
                    label: const Text('Clear all colors and hidden fields'),
                  ),
                ),
                const SizedBox(height: 4),
                const Text('Changes are saved as you make them. Turn the colors (and hiding) on and off with the Colors box on the Raw tab.'),
          ],
        ],
      ),
    );
  }
}
