import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/model.dart';

/// A horizontal presentation of live captures; host display coordinates stay
/// unchanged. One decoded frame is retained for each advertised display.
class RymuMonitorOverview extends ChangeNotifier {
  RymuMonitorOverview(List<Rect> displays)
      : displays = List.unmodifiable(displays) {
    final height = displays.fold<double>(0, (h, r) => math.max(h, r.height));
    var left = 0.0;
    tiles = List.unmodifiable(displays.map((display) {
      final tile = Rect.fromLTWH(
          left, (height - display.height) / 2, display.width, display.height);
      left += display.width;
      return tile;
    }));
    content = Size(left, height);
  }

  final List<Rect> displays;
  late final List<Rect> tiles;
  late final Size content;
  final _frames = <int, ui.Image>{};
  var _closed = false;
  Size viewport = Size.zero;
  double scale = 1;
  Offset offset = Offset.zero;

  ui.Image? frame(int display) => _frames[display];
  double get minimumScale => viewport.isEmpty || content.isEmpty
      ? 1
      : math.min(
          viewport.width / content.width, viewport.height / content.height);

  void updateFrame(int display, ui.Image image) {
    if (_closed ||
        display < 0 ||
        display >= displays.length ||
        image.width != displays[display].width ||
        image.height != displays[display].height) {
      image.dispose();
      return;
    }
    _frames.remove(display)?.dispose();
    _frames[display] = image;
    notifyListeners();
  }

  void clearFrames() {
    for (final frame in _frames.values) {
      frame.dispose();
    }
    _frames.clear();
  }

  void resize(Size size) {
    if (size == viewport || _closed) return;
    viewport = size;
    fit();
  }

  void fit() {
    if (_closed || viewport.isEmpty || content.isEmpty) return;
    scale = minimumScale;
    offset = _bounded(Offset.zero);
    notifyListeners();
  }

  Offset _bounded(Offset value) {
    double axis(double position, double available, double length) {
      final space = available - length * scale;
      return space >= 0 ? space / 2 : position.clamp(space, 0).toDouble();
    }

    return Offset(axis(value.dx, viewport.width, content.width),
        axis(value.dy, viewport.height, content.height));
  }

  void transform(double factor, Offset previous, Offset current) {
    if (_closed || viewport.isEmpty || !factor.isFinite || factor <= 0) return;
    final next = (scale * factor)
        .clamp(minimumScale, math.max(1.5, minimumScale * 4))
        .toDouble();
    final nextOffset = current - (previous - offset) * (next / scale);
    scale = next;
    offset = _bounded(nextOffset);
    notifyListeners();
  }

  Offset? remoteAt(Offset local) => _remotePoint((local - offset) / scale);

  Offset? _remotePoint(Offset point) {
    for (var i = 0; i < tiles.length; i++) {
      if (tiles[i].contains(point)) {
        return point - tiles[i].topLeft + displays[i].topLeft;
      }
    }
    return null;
  }

  Offset? packedPoint(Offset remote) {
    for (var i = 0; i < displays.length; i++) {
      if (displays[i].contains(remote)) {
        return remote - displays[i].topLeft + tiles[i].topLeft;
      }
    }
    return null;
  }

  Offset movePointer(Offset remote, Offset delta) {
    var point = (packedPoint(remote) ?? tiles.first.center) + delta / scale;
    point = Offset(point.dx.clamp(0, content.width - 1).toDouble(), point.dy);
    final index = tiles.indexWhere((tile) => point.dx < tile.right);
    final tile = tiles[index];
    point =
        Offset(point.dx, point.dy.clamp(tile.top, tile.bottom - 1).toDouble());
    final local = point * scale + offset;
    final correction = Offset(
      local.dx < 0
          ? -local.dx
          : (local.dx > viewport.width ? viewport.width - local.dx : 0),
      local.dy < 0
          ? -local.dy
          : (local.dy > viewport.height ? viewport.height - local.dy : 0),
    );
    if (correction != Offset.zero) {
      offset = _bounded(offset + correction);
      notifyListeners();
    }
    return point - tile.topLeft + displays[index].topLeft;
  }

  @override
  void dispose() {
    _closed = true;
    clearFrames();
    super.dispose();
  }
}

class RymuMonitorOverviewView extends StatelessWidget {
  const RymuMonitorOverviewView(
      {super.key,
      required this.overview,
      required this.cursor,
      required this.arabic,
      required this.showCursor});
  final RymuMonitorOverview overview;
  final CursorModel cursor;
  final bool arabic;
  final bool showCursor;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _OverviewPainter(overview, cursor, arabic, showCursor),
      );
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.overview, this.cursor, this.arabic, this.showCursor)
      : super(repaint: Listenable.merge([overview, cursor]));
  final RymuMonitorOverview overview;
  final CursorModel cursor;
  final bool arabic;
  final bool showCursor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (var i = 0; i < overview.tiles.length; i++) {
      final tile = overview.tiles[i];
      final target = Rect.fromLTWH(
          overview.offset.dx + tile.left * overview.scale,
          overview.offset.dy + tile.top * overview.scale,
          tile.width * overview.scale,
          tile.height * overview.scale);
      final image = overview.frame(i);
      if (image == null) {
        canvas.drawRect(target, Paint()..color = const Color(0xff202020));
        final text = TextPainter(
          text: TextSpan(
              text: arabic
                  ? 'بانتظار الشاشة ${i + 1}'
                  : 'Waiting for display ${i + 1}',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
          textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
        )..layout(maxWidth: math.max(1, target.width - 12));
        canvas.save();
        canvas.clipRect(target);
        text.paint(
            canvas, target.center - Offset(text.width / 2, text.height / 2));
        canvas.restore();
        text.dispose();
      } else {
        canvas.drawImageRect(
            image,
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            target,
            paint);
      }
      canvas.drawRect(
          target,
          Paint()
            ..color = const Color(0xff808080)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
    final point = overview.packedPoint(cursor.offset);
    if (!showCursor || point == null) return;
    final local = point * overview.scale + overview.offset;
    final image = cursor.image;
    if (image != null) {
      final scale =
          math.max(overview.scale, 16 / math.max(image.width, image.height));
      canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(
              local.dx - cursor.hotx * scale,
              local.dy - cursor.hoty * scale,
              image.width * scale,
              image.height * scale),
          paint);
    } else {
      canvas.drawCircle(local, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
          local,
          5,
          Paint()
            ..color = Colors.black
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _OverviewPainter oldDelegate) =>
      oldDelegate.overview != overview ||
      oldDelegate.cursor != cursor ||
      oldDelegate.arabic != arabic ||
      oldDelegate.showCursor != showCursor;
}
