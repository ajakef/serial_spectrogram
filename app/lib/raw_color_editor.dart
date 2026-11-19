import 'package:flutter/material.dart';

import 'raw_colors.dart';

/// Where the Raw tab's color scheme is made: pick one of the recent lines as the example (its commas show which
/// field is which), then tap a field to choose its colors. The result applies only to lines with the same number of fields.
class RawColorEditor extends StatefulWidget {
  const RawColorEditor({super.key, required this.recentLines, this.current});

  /// Recent lines from the Raw tab, newest first.
  final List<String> recentLines;
  final RawColorScheme? current;

  @override
  State<RawColorEditor> createState() => _RawColorEditorState();
}

class _RawColorEditorState extends State<RawColorEditor> {
  static const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

  late final List<String> lines; // lines with at least one delimiter
  late List<FieldStyle> styles;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    lines = [for (final l in widget.recentLines) if (l.contains(RawColorScheme.delimiter)) l];
    styles = [...?widget.current?.styles];
    // Start from a recent line that fits the saved scheme; otherwise the newest line.
    final fit = widget.current == null ? -1 : lines.indexWhere((l) => widget.current!.split(l) != null);
    selected = fit < 0 ? 0 : fit;
    if (lines.isNotEmpty) _resize();
  }

  List<String> get fields => lines.isEmpty ? const [] : lines[selected].split(RawColorScheme.delimiter);

  /// One style per field of the chosen example line: kept for fields that were already styled, plain for new ones.
  void _resize() {
    final n = fields.length;
    styles = [for (var i = 0; i < n; i++) i < styles.length ? styles[i] : const FieldStyle()];
  }

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
                const SizedBox(height: 8),
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
    final span = RawColorScheme(styles: styles).span(line, _mono.copyWith(color: Colors.black));
    return Text.rich(span ?? TextSpan(text: line, style: _mono), softWrap: false, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    final f = fields;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Colors for lines'),
        actions: [
          TextButton(
            onPressed: lines.isEmpty ? null : () => Navigator.pop(context, RawColorScheme(styles: [...styles])),
            child: const Text('Save'),
          ),
        ],
      ),
      body: lines.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No recent lines with commas yet. Plug in the logger, let some data arrive on the Raw tab, '
                    'then open this again.'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(
                  'Colors are used only for lines with exactly ${f.length} fields (${f.length - 1} commas), '
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
                const Text('2. Tap a field to choose its colors', style: TextStyle(fontWeight: FontWeight.bold)),
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
                          style: _mono.copyWith(color: styles[i].text ?? Colors.black),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => styles = [for (final _ in styles) const FieldStyle()]),
                    icon: const Icon(Icons.format_color_reset),
                    label: const Text('Clear all colors'),
                  ),
                ),
                const SizedBox(height: 4),
                const Text('3. Tap Save (top right). Turn the colors on and off with the Colors box on the Raw tab.'),
              ],
            ),
    );
  }
}
