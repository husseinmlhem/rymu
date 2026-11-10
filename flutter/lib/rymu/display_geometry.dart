import 'dart:convert';
import 'dart:math';

/// Physical capture coordinates. The stable ID is supplied by Windows; ambiguous
/// clones or temporary outputs may omit it and therefore cannot be restored.
class RymuDisplay {
  const RymuDisplay(this.id, this.index, this.x, this.y, this.width,
      this.height, this.dpi, this.rotation, this.primary);
  final String? id;
  final int index, x, y, width, height;
  final int? dpi, rotation;
  final bool primary;

  Rectangle<int> get bounds => Rectangle(x, y, width, height);

  static RymuDisplay? parse(Object? data) {
    if (data is! Map) return null;
    final index = data['index'];
    final x = data['x'], y = data['y'], w = data['width'], h = data['height'];
    if (index is! int ||
        index < 0 ||
        index >= 64 ||
        x is! int ||
        y is! int ||
        w is! int ||
        h is! int ||
        w < 1 ||
        h < 1) {
      return null;
    }
    final id = data['id'];
    final dpi = data['dpi'];
    final rotation = data['rotation'];
    return RymuDisplay(
      id is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id) ? id : null,
      index,
      x,
      y,
      w,
      h,
      dpi is int && dpi > 0 && dpi < 1200 ? dpi : null,
      rotation is int && [0, 90, 180, 270].contains(rotation) ? rotation : null,
      data['primary'] == true,
    );
  }
}

String? topologyFingerprintInput(List<RymuDisplay> displays) {
  if (displays.isEmpty ||
      displays
          .any((d) => d.id == null || d.dpi == null || d.rotation == null)) {
    return null;
  }
  final ids = displays.map((d) => d.id!).toSet();
  if (ids.length != displays.length) return null;
  final sorted = [...displays]..sort((a, b) => a.id!.compareTo(b.id!));
  return jsonEncode(sorted
      .map((d) => [
            d.id,
            d.x,
            d.y,
            d.width,
            d.height,
            d.dpi,
            d.rotation,
            d.primary,
          ])
      .toList());
}

Rectangle<double> fitTopology(
    Rectangle<num> desktop, double width, double height) {
  final scale = min(width / desktop.width, height / desktop.height);
  return Rectangle(
      (width - desktop.width * scale) / 2,
      (height - desktop.height * scale) / 2,
      desktop.width * scale,
      desktop.height * scale);
}

Rectangle<double> fitDisplayInOverview(Rectangle<num> display,
    Rectangle<num> desktop, Rectangle<double> viewport) {
  final scale = viewport.width / desktop.width;
  return Rectangle(
    viewport.left + (display.left - desktop.left) * scale,
    viewport.top + (display.top - desktop.top) * scale,
    display.width * scale,
    display.height * scale,
  );
}

/// Reference transform for an already-oriented capture surface. Input outside
/// the painted viewport is ignored. Display origin is applied in physical pixels.
Point<int>? capturePoint(
    Rectangle<num> display, Rectangle<double> image, Point<double> logicalPoint,
    {double viewerDpiScale = 1, bool pointIsPhysical = false}) {
  if (viewerDpiScale <= 0 || image.width <= 0 || image.height <= 0) return null;
  final point = pointIsPhysical
      ? Point(logicalPoint.x / viewerDpiScale, logicalPoint.y / viewerDpiScale)
      : logicalPoint;
  if (point.x < image.left ||
      point.y < image.top ||
      point.x >= image.right ||
      point.y >= image.bottom) {
    return null;
  }
  return Point(
      display.left.toInt() +
          ((point.x - image.left) * display.width / image.width).floor(),
      display.top.toInt() +
          ((point.y - image.top) * display.height / image.height).floor());
}

/// Remap by IDs instead of enumerator indices and reject ambiguity or overlap.
Map<int, int>? resolveAssignment(Map<String, String> assignment,
    List<RymuDisplay> remote, List<RymuDisplay> local) {
  if (assignment.isEmpty ||
      assignment.values.toSet().length != assignment.length) return null;
  final remoteIndex = {for (final display in remote) display.id: display.index};
  final localIndex = {for (final display in local) display.id: display.index};
  if (remoteIndex.length != remote.length || localIndex.length != local.length)
    return null;
  if (assignment.keys.any((id) => !remoteIndex.containsKey(id)) ||
      assignment.values.any((id) => !localIndex.containsKey(id))) return null;
  return {
    for (final entry in assignment.entries)
      remoteIndex[entry.key]!: localIndex[entry.value]!
  };
}
