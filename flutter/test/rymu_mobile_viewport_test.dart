import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/rymu_android/remote_keyboard.dart';
import 'package:flutter_hbb/rymu_android/session_bar.dart';
import 'package:flutter_hbb/rymu_android/touch_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Display extends Fake implements FfiModel {
  @override
  Rect rect = const Rect.fromLTWH(0, 0, 1920, 1080);
}

class _Session extends Fake implements FFI {
  @override
  final sessionId = const Uuid().v4obj();
  @override
  final _Display ffiModel = _Display();
  @override
  late final canvasModel = CanvasModel(WeakReference<FFI>(this));
}

void main() {
  testWidgets('fit is the zoom floor and pan stays inside the remote image',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 540);
    addTearDown(tester.view.reset);
    final session = _Session();
    final canvas = session.canvasModel;
    canvas.rymuMobileViewport = const Size(960, 464);
    canvas.fitRymuMobileViewport();
    final minimum = canvas.scale;
    expect(1080 * minimum, closeTo(464, .001));
    expect(1920 * minimum, lessThanOrEqualTo(960));

    const center = Offset(480, 232);
    canvas.transformRymuMobileViewport(3, center, center);
    expect(canvas.scale, greaterThan(minimum));
    canvas.transformRymuMobileViewport(1, center, const Offset(9999, 9999));
    expect(canvas.x, closeTo(0, .001));
    expect(canvas.y, closeTo(0, .001));
    canvas.transformRymuMobileViewport(1, center, const Offset(-9999, -9999));
    expect(canvas.x, closeTo(960 - 1920 * canvas.scale, .001));
    expect(canvas.y, closeTo(464 - 1080 * canvas.scale, .001));

    for (var i = 0; i < 3; i++) {
      canvas.transformRymuMobileViewport(.1, center, const Offset(9999, -9999));
      expect(canvas.scale, minimum);
      expect(canvas.x, closeTo((960 - 1920 * minimum) / 2, .001));
      expect(canvas.y, closeTo(0, .001));
    }

    session.ffiModel.rect = const Rect.fromLTWH(-1080, 0, 1080, 1920);
    canvas.fitRymuMobileViewport();
    expect(canvas.scale, closeTo(464 / 1920, .001));
    expect(canvas.x, closeTo((960 - 1080 * canvas.scale) / 2, .001));
  });

  testWidgets('real session controls and canvas stay above IME while unfolding',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 660);
    addTearDown(tester.view.reset);
    final session = _Session();
    final canvas = session.canvasModel;
    final legacySize = canvas.getSize();
    final keys = RymuRemoteKeys();
    var keyboard = false;
    var display = 1;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, update) {
        final screens = RymuSessionDisplayControl(
          arabic: true,
          current: display,
          count: 2,
          cycleCount: 2,
          onNext: () => update(() => display = display == 1 ? 2 : 1),
          onChoose: () {},
        );
        return Scaffold(
          bottomNavigationBar: keyboard
              ? null
              : RymuAndroidSessionBar(
                  name: 'Fixture PC',
                  status: 'متصل',
                  arabic: true,
                  displayControl: screens,
                  onText: () => update(() => keyboard = true),
                  onSettings: () {},
                  onDisconnect: () {},
                ),
          body: Column(children: [
            Expanded(
              child: RymuTouchSurface(
                ffi: session,
                canControl: () => false,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            if (keyboard)
              RymuRemoteKeyboard(
                arabic: true,
                expanded: false,
                keys: keys,
                displayControl: screens,
                onModifier: keys.toggle,
                onKey: keys.stroke,
                onExpand: () {},
                onHide: () => update(() => keyboard = false),
              ),
          ]),
        );
      }),
    ));
    await tester.pumpAndSettle();
    final surface = find.byType(RymuTouchSurface);
    final dock = find.byType(RymuRemoteKeyboard);
    final displays = find.byType(RymuSessionDisplayControl);
    final closed = canvas.size.height;
    await tester.tap(find.byTooltip('إظهار لوحة المفاتيح'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pumpAndSettle();
    expect(canvas.size.height, lessThan(closed));

    for (final size in [
      const Size(320, 660),
      const Size(720, 780),
      const Size(960, 540)
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(canvas.size, tester.getSize(surface));
      expect(1080 * canvas.scale, lessThanOrEqualTo(canvas.size.height + .001));
      expect(tester.getBottomLeft(surface).dy,
          lessThanOrEqualTo(tester.getTopLeft(dock).dy));
      expect(
          tester.getBottomLeft(dock).dy, lessThanOrEqualTo(size.height - 230));
      expect(displays.hitTestable(), findsOneWidget);
    }
    await tester.tap(displays);
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(dock, findsOneWidget);
    await tester.tap(find.byTooltip('إخفاء لوحة المفاتيح'));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(canvas.size.height, greaterThan(310));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    canvas.clear();
    expect(canvas.rymuMobileViewport, isNull);
    tester.view.physicalSize = const Size(320, 660);
    expect(canvas.getSize(), legacySize);
  });
}
