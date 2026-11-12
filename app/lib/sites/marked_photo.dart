import 'dart:io';

import 'package:flutter/material.dart';

import 'site_model.dart';

/// A photo with its markers drawn over it, fitted inside the space it's given. Markers are stored as fractions of
/// the photo's width and height, so they stay put at any size. Tapping the photo or a marker, and dragging a marker,
/// are reported (as fractions) when the callbacks are set.
class MarkedPhoto extends StatefulWidget {
  const MarkedPhoto({
    super.key,
    required this.file,
    required this.markers,
    this.onTapPhoto,
    this.onTapMarker,
    this.onDragMarker,
    this.onDragEnd,
    this.cacheWidth,
    this.showLabels = true,
  });

  final File file;
  final List<Marker> markers;
  final void Function(double x, double y)? onTapPhoto;
  final void Function(int index)? onTapMarker;
  final void Function(int index, double x, double y)? onDragMarker;
  final VoidCallback? onDragEnd;
  final int? cacheWidth; // decode smaller, for thumbnails
  final bool showLabels;

  @override
  State<MarkedPhoto> createState() => _MarkedPhotoState();
}

class _MarkedPhotoState extends State<MarkedPhoto> {
  static final _sizes = <String, Size>{}; // photo sizes already found, by path
  late ImageProvider _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _size;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(MarkedPhoto old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path || old.cacheWidth != widget.cacheWidth) _resolve();
  }

  void _resolve() {
    _stopListening();
    final full = FileImage(widget.file);
    _image = widget.cacheWidth == null ? full : ResizeImage(full, width: widget.cacheWidth, policy: ResizeImagePolicy.fit);
    _size = _sizes[widget.file.path];
    if (_size != null || !widget.file.existsSync()) return;
    // The photo's shape, as decoded (turned upright, as it's shown).
    _stream = _image.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, _) {
      final s = Size(info.image.width.toDouble(), info.image.height.toDouble());
      _sizes[widget.file.path] = s;
      if (mounted) setState(() => _size = s);
      _stopListening();
    }, onError: (_, _) {});
    _stream!.addListener(_listener!);
  }

  void _stopListening() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.file.existsSync()) {
      return const ColoredBox(color: Colors.black12, child: Center(child: Icon(Icons.image_not_supported)));
    }
    final size = _size;
    if (size == null) return const ColoredBox(color: Colors.black12, child: Center(child: CircularProgressIndicator()));
    return LayoutBuilder(builder: (context, box) {
      final scale = [box.maxWidth / size.width, box.maxHeight / size.height].reduce((a, b) => a < b ? a : b);
      final w = size.width * scale, h = size.height * scale;
      final left = (box.maxWidth - w) / 2, top = (box.maxHeight - h) / 2;
      final r = (w < h ? w : h) / 30 + 6; // marker ring radius
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: w,
            height: h,
            child: GestureDetector(
              onTapUp: widget.onTapPhoto == null
                  ? null
                  : (d) => widget.onTapPhoto!(d.localPosition.dx / w, d.localPosition.dy / h),
              child: Image(image: _image, fit: BoxFit.fill, gaplessPlayback: true),
            ),
          ),
          for (var i = 0; i < widget.markers.length; i++)
            Positioned(
              // labels go on the left of markers near the right edge, so they aren't cut off
              left: widget.markers[i].x > 0.7 ? null : left + widget.markers[i].x * w - r,
              right: widget.markers[i].x > 0.7 ? box.maxWidth - (left + widget.markers[i].x * w + r) : null,
              top: top + widget.markers[i].y * h - r,
              child: GestureDetector(
                onTap: widget.onTapMarker == null ? null : () => widget.onTapMarker!(i),
                onPanUpdate: widget.onDragMarker == null
                    ? null
                    : (d) => widget.onDragMarker!(
                          i,
                          (widget.markers[i].x + d.delta.dx / w).clamp(0.0, 1.0),
                          (widget.markers[i].y + d.delta.dy / h).clamp(0.0, 1.0),
                        ),
                onPanEnd: widget.onDragEnd == null ? null : (_) => widget.onDragEnd!(),
                child: _MarkerDot(
                  radius: r,
                  label: widget.showLabels ? widget.markers[i].label : null,
                  labelLeft: widget.markers[i].x > 0.7,
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _MarkerDot extends StatelessWidget {
  const _MarkerDot({required this.radius, this.label, this.labelLeft = false});

  final double radius;
  final String? label;
  final bool labelLeft;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: labelLeft ? TextDirection.rtl : TextDirection.ltr, // rtl: the label comes first, on the left
      children: [
        Container(
          width: 2 * radius,
          height: 2 * radius,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.yellow, width: radius / 4),
            color: Colors.black26,
          ),
          child: Center(
            child: Container(
              width: radius / 2,
              height: radius / 2,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.yellow),
            ),
          ),
        ),
        if (label != null && label!.isNotEmpty)
          Container(
            margin: EdgeInsets.only(left: labelLeft ? 0 : 4, right: labelLeft ? 4 : 0),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            color: Colors.black87,
            child: Text(label!, style: const TextStyle(color: Colors.yellow, fontSize: 13)),
          ),
      ],
    );
  }
}
