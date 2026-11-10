import 'dart:math';

import '../lib/rymu/display_geometry.dart';

void check(bool result, String name) {
  if (!result) throw StateError(name);
  print('PASS $name');
}

void main() {
  const left = RymuDisplay('left', 0, -1920, 0, 1920, 1080, 120, 0, false);
  const center = RymuDisplay('center', 1, 0, 0, 2560, 1440, 144, 0, true);
  const right = RymuDisplay('right', 2, 2560, -300, 1080, 1920, 192, 90, false);
  const remoteA = RymuDisplay('remote-a', 0, 0, 0, 1920, 1080, 96, 0, true);
  const remoteB =
      RymuDisplay('remote-b', 1, -1920, 0, 1920, 1080, 120, 0, false);
  const remoteC =
      RymuDisplay('remote-c', 2, 1920, -180, 1080, 1920, 144, 90, false);
  const pair = {'remote-a': 'center', 'remote-b': 'left', 'remote-c': 'right'};

  final result = resolveAssignment(
      pair, [remoteA, remoteB, remoteC], [left, center, right]);
  check(result?[0] == 1 && result?[1] == 0 && result?[2] == 2,
      'Three distinct windows with center-left-right assignment');
  check(
      resolveAssignment(pair, [remoteA, remoteB, remoteC], [left, center]) ==
          null,
      'Removed local monitor invalidates saved mapping');
  check(
      resolveAssignment({'remote-a': 'left', 'remote-b': 'left'},
              [remoteA, remoteB], [left]) ==
          null,
      'Two remote displays cannot occupy one mapped local monitor');
  const renumbered =
      RymuDisplay('left', 9, -1920, 0, 1920, 1080, 120, 0, false);
  check(
      resolveAssignment(pair, [remoteB, remoteC, remoteA],
              [center, right, renumbered])?[1] ==
          9,
      'Current numbering is resolved after reordering');
  check(
      topologyFingerprintInput([left, center, right]) ==
          topologyFingerprintInput([right, center, renumbered]),
      'Topology identity ignores enumeration order');
  const dpiChange = RymuDisplay('left', 0, -1920, 0, 1920, 1080, 144, 0, false);
  check(
      topologyFingerprintInput([left, center, right]) !=
          topologyFingerprintInput([dpiChange, center, right]),
      'DPI change invalidates stored topology');
  check(topologyFingerprintInput([left, renumbered]) == null,
      'Ambiguous physical IDs cannot be saved');

  const desktop = Rectangle(-1920, -300, 5560, 1920);
  final viewport = fitTopology(desktop, 556, 250);
  final a = fitDisplayInOverview(left.bounds, desktop, viewport);
  final b = fitDisplayInOverview(center.bounds, desktop, viewport);
  final c = fitDisplayInOverview(right.bounds, desktop, viewport);
  check(
      a.left < b.left && b.left < c.left && c.top < b.top && c.height > c.width,
      'Overview preserves negative origins and portrait orientation');
  const image = Rectangle(20.0, 40.0, 960.0, 540.0);
  check(capturePoint(left.bounds, image, const Point(10.0, 40.0)) == null,
      'A click in the letterbox is rejected');
  check(
      capturePoint(left.bounds, image, const Point(500.0, 310.0)) ==
          const Point(-960, 540),
      'An image midpoint maps to the selected negative-origin capture');
  for (final dpi in [1.25, 1.5, 2.0]) {
    check(
        capturePoint(left.bounds, image, Point(500 * dpi, 310 * dpi),
                viewerDpiScale: dpi, pointIsPhysical: true) ==
            const Point(-960, 540),
        'Physical input at scale $dpi resolves the same capture pixel');
  }
  check(
      capturePoint(right.bounds, const Rectangle(50.0, 10.0, 540.0, 960.0),
              const Point(589.9, 969.9)) ==
          const Point(3639, 1619),
      'Portrait capture bottom-right lands on the final visible pixel');
}
