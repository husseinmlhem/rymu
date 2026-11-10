import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/rymu_android/monitor_overview.dart';
import 'package:flutter_hbb/rymu_android/session_bar.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Displays extends Fake implements FfiModel {
  @override
  final pi = PeerInfo();
}

class _CaptureSession extends Fake implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  final id = 'overview-capture-fixture';
  @override
  final ffiModel = _Displays();
}

void main() {
  test(
      'horizontal live layout maps unequal monitors with negative host origins',
      () {
    final overview = RymuMonitorOverview(const [
      Rect.fromLTWH(-1920, 0, 1920, 1080),
      Rect.fromLTWH(0, -500, 1080, 1920),
      Rect.fromLTWH(1080, 120, 2560, 1440),
    ]);
    addTearDown(overview.dispose);
    overview.resize(const Size(960, 464));
    expect(overview.content, const Size(5560, 1920));
    for (var i = 0; i < overview.displays.length; i++) {
      final remote = overview.displays[i].center;
      final packed = overview.packedPoint(remote)!;
      final local = packed * overview.scale + overview.offset;
      expect((overview.remoteAt(local)! - remote).distance, lessThan(.001));
    }
    expect(overview.remoteAt(const Offset(20, 0)), isNull);
    final firstRight = overview.displays.first.centerRight - const Offset(1, 0);
    final next =
        overview.movePointer(firstRight, Offset(60 * overview.scale, 0));
    expect(overview.displays[1].contains(next), isTrue);
    expect(next.dx, closeTo(59, .001));
    final fit = overview.scale;
    const center = Offset(480, 232);
    overview.transform(3, center, center);
    overview.transform(1, center, const Offset(-99999, 99999));
    expect(overview.offset.dx,
        closeTo(960 - overview.content.width * overview.scale, .001));
    expect(overview.offset.dy, 0);
    overview.transform(.001, center, center);
    expect(overview.scale, fit);
    overview.resize(const Size(320, 260));
    expect(overview.content.width * overview.scale, closeTo(320, .001));
  });

  testWidgets(
      'live frames retain each display and release replaced and closed images',
      (tester) async {
    ui.Image image(int width, int height) {
      final recording = ui.PictureRecorder();
      Canvas(recording).drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..color = Colors.white);
      final picture = recording.endRecording();
      final frame = picture.toImageSync(width, height);
      picture.dispose();
      return frame;
    }

    final overview = RymuMonitorOverview(
        const [Rect.fromLTWH(-4, 0, 4, 2), Rect.fromLTWH(0, 0, 2, 4)]);
    final first = image(4, 2), second = image(2, 4), replacement = image(4, 2);
    overview.updateFrame(0, first);
    overview.updateFrame(1, second);
    overview.updateFrame(0, replacement);
    expect(first.debugDisposed, isTrue);
    expect(overview.frame(0), same(replacement));
    expect(overview.frame(1), same(second));
    overview.dispose();
    expect(replacement.debugDisposed, isTrue);
    expect(second.debugDisposed, isTrue);
    final lateFrame = image(4, 2);
    overview.updateFrame(0, lateFrame);
    expect(lateFrame.debugDisposed, isTrue);

    final session = _CaptureSession();
    session.ffiModel.pi.displays.addAll([
      Display()
        ..x = -4
        ..width = 4
        ..height = 2,
      Display()
        ..width = 2
        ..height = 4,
    ]);
    final live = RymuMonitorOverview(
        const [Rect.fromLTWH(-4, 0, 4, 2), Rect.fromLTWH(0, 0, 2, 4)]);
    final model = ImageModel(WeakReference(session))..rymuOverview = live;
    await tester.runAsync(() async {
      await model.decodeAndUpdate(0, Uint8List(4 * 2 * 4));
      await model.decodeAndUpdate(1, Uint8List(2 * 4 * 4));
    });
    expect(live.frame(0)?.width, 4);
    expect(live.frame(1)?.width, 2);
    expect(model.image, isNull);
    model.disposeImage();
    expect(live.frame(0), isNull);
    expect(live.frame(1), isNull);
    live.dispose();
  });

  testWidgets(
      'display overview action is capability gated and modes are explicit',
      (tester) async {
    var overviewCalls = 0;
    bool? direct;
    Widget page({VoidCallback? onOverview}) => MaterialApp(
            home: Scaffold(
                body: RymuSessionScreensSheet(
          arabic: false,
          sizes: const [Size(1920, 1080), Size(1080, 1920)],
          current: 0,
          selected: const {0, 1},
          onOverview: onOverview,
        )));
    await tester.pumpWidget(page());
    expect(find.text('All displays side by side'), findsNothing);
    await tester.pumpWidget(page(onOverview: () => overviewCalls++));
    await tester.tap(find.text('All displays side by side'));
    expect(overviewCalls, 1);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RymuInputModeSelector(
      arabic: false,
      direct: true,
      onChanged: (value) => direct = value,
    ))));
    await tester.tap(find.text('Mouse / trackpad'));
    expect(direct, isFalse);
    expect(find.textContaining('including the margins'), findsOneWidget);
  });
}
