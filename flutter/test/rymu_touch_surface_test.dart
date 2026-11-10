import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/rymu_android/touch_surface.dart';
import 'package:flutter_hbb/rymu_android/monitor_overview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  final mouse = <Map<String, dynamic>>[];
  Future<void>? pendingDown;

  @override
  Future<void> sessionSendMouse(
      {required SessionID sessionId, required String msg, dynamic hint}) async {
    final event = jsonDecode(msg) as Map<String, dynamic>;
    mouse.add(event);
    if (event['type'] == 'down') await pendingDown;
  }
}

class _Desktop extends FfiModel {
  _Desktop(FFI session, this.touchMode) : super(WeakReference(session)) {
    pi.platform = kPeerPlatformWindows;
  }

  @override
  final bool touchMode;

  @override
  final rect = const Rect.fromLTWH(0, 0, 1920, 1080);
}

class _Session extends Fake implements FFI {
  _Session(bool direct) {
    ffiModel = _Desktop(this, direct);
  }

  @override
  final String id = 'fixture-host';
  @override
  final SessionID sessionId = const Uuid().v4obj();
  @override
  final ConnType connType = ConnType.defaultConn;
  @override
  late final FfiModel ffiModel;
  @override
  late final CanvasModel canvasModel = CanvasModel(WeakReference(this));
  @override
  late final CursorModel cursorModel = CursorModel(WeakReference(this));
  @override
  late final InputModel inputModel = InputModel(WeakReference(this));
}

void main() {
  Future<(_Session, _Binding)> open(WidgetTester tester,
      {required bool direct,
      bool Function()? canControl,
      RymuMonitorOverview? overview}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 300);
    addTearDown(tester.view.reset);
    final bridge = _Binding();
    platformFFI.setBindingForTesting(bridge);
    final session = _Session(direct);
    addTearDown(() => session.inputModel.disposeRelativeMouseMode());
    await tester.pumpWidget(MaterialApp(
      home: RymuTouchSurface(
        ffi: session,
        overview: overview,
        canControl: canControl ?? () => true,
        child: overview == null
            ? const SizedBox.expand()
            : RymuMonitorOverviewView(
                overview: overview,
                cursor: session.cursorModel,
                arabic: false,
                showCursor: true,
              ),
      ),
    ));
    await tester.pump();
    expect(session.canvasModel.size, const Size(390, 300));
    return (session, bridge);
  }

  const left = [
    {'type': 'down', 'buttons': 'left'},
    {'type': 'up', 'buttons': 'left'},
  ];
  const right = [
    {'type': 'down', 'buttons': 'right'},
    {'type': 'up', 'buttons': 'right'},
  ];

  testWidgets('relative tap, double tap and hold send exact button pairs',
      (tester) async {
    final (session, bridge) = await open(tester, direct: false);
    const point = Offset(110, 140);
    // A physical mouse hover must not remove the touch surface.
    session.inputModel.isPhysicalMouse.value = true;
    await tester.tapAt(point);
    await tester.pump();
    expect(bridge.mouse, left);

    bridge.mouse.clear();
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(point);
    await tester.pump();
    expect(bridge.mouse, [...left, ...left]);

    bridge.mouse.clear();
    final hold = await tester.startGesture(point);
    await tester.pump(kLongPressTimeout);
    expect(bridge.mouse, right);
    await hold.up();
    await tester.pump();
    expect(bridge.mouse, right);
  });

  testWidgets('relative motion and a pinch never emit a click or stray release',
      (tester) async {
    final (session, bridge) = await open(tester, direct: false);
    final pointer = await tester.startGesture(const Offset(90, 140));
    await pointer.moveBy(const Offset(42, 20));
    await pointer.up();
    await tester.pump();
    expect(bridge.mouse, hasLength(1));
    expect(bridge.mouse.single.keys, unorderedEquals(['x', 'y']));
    bridge.mouse.clear();

    final fit = session.canvasModel.scale;
    final first = await tester.startGesture(const Offset(130, 130));
    final second = await tester.startGesture(const Offset(230, 170));
    await second.moveBy(const Offset(80, 70));
    await first.up();
    await second.moveBy(const Offset(-14, -25));
    await second.up();
    await tester.pump(kLongPressTimeout);
    expect(session.canvasModel.scale, greaterThan(fit));
    expect(bridge.mouse, isEmpty);

    final fingers = [
      await tester.startGesture(const Offset(100, 110)),
      await tester.startGesture(const Offset(170, 110)),
      await tester.startGesture(const Offset(240, 110)),
    ];
    for (final finger in fingers) {
      await finger.moveBy(const Offset(0, 32));
    }
    for (final finger in fingers) {
      await finger.up();
    }
    await tester.pump(kLongPressTimeout);
    expect(bridge.mouse, isNotEmpty);
    expect(bridge.mouse.map((event) => event['type']), everyElement('wheel'));
  });

  testWidgets(
      'trackpad accepts gestures on unused margins; direct touch does not click them',
      (tester) async {
    final (session, bridge) = await open(tester, direct: false);
    const margin = Offset(120, 12);
    expect(session.cursorModel.isInRemoteRect(margin), isFalse);
    await tester.tapAt(margin);
    await tester.pump();
    expect(bridge.mouse, left);
    bridge.mouse.clear();
    final drag = await tester.startGesture(margin);
    await drag.moveBy(const Offset(50, 0));
    await drag.up();
    await tester.pump();
    expect(bridge.mouse.any((event) => event.containsKey('x')), isTrue);
    bridge.mouse.clear();
    final hold = await tester.startGesture(margin);
    await tester.pump(kLongPressTimeout);
    await hold.up();
    await tester.pump();
    expect(bridge.mouse, right);
    final (_, directBridge) = await open(tester, direct: true);
    await tester.tapAt(margin);
    await tester.pump();
    expect(directBridge.mouse, isEmpty);
  });

  testWidgets(
      'overview touch and physical mouse target the actual monitor coordinates',
      (tester) async {
    final overview = RymuMonitorOverview(const [
      Rect.fromLTWH(-1920, 0, 1920, 1080),
      Rect.fromLTWH(0, -420, 1080, 1920),
    ]);
    addTearDown(overview.dispose);
    final (_, bridge) = await open(tester, direct: true, overview: overview);
    final center = overview.tiles[1].center * overview.scale + overview.offset;
    await tester.tapAt(center);
    await tester.pump();
    expect(bridge.mouse, [
      {'x': '540', 'y': '540'},
      ...left
    ]);
    bridge.mouse.clear();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(center);
    await mouse.up();
    await tester.pump();
    expect(bridge.mouse, [
      {'x': '540', 'y': '540'},
      ...left
    ]);
  });

  testWidgets('direct click moves to the image point and drag releases once',
      (tester) async {
    var permitted = true;
    final (_, bridge) =
        await open(tester, direct: true, canControl: () => permitted);
    const point = Offset(97.5, 150);
    await tester.tapAt(point);
    await tester.pump();
    expect(bridge.mouse, [
      {'x': '480', 'y': '540'},
      ...left,
    ]);

    bridge.mouse.clear();
    final hold = await tester.startGesture(point);
    await tester.pump(kLongPressTimeout);
    await hold.up();
    await tester.pump();
    expect(bridge.mouse, [
      {'x': '480', 'y': '540'},
      ...right,
    ]);

    bridge.mouse.clear();
    final drag = await tester.startGesture(point);
    await drag.moveBy(const Offset(40, 10));
    await drag.cancel();
    await tester.pump();
    expect(bridge.mouse.where((event) => event.containsKey('buttons')), left);
    expect(bridge.mouse.where((event) => event.containsKey('x')), hasLength(2));

    bridge.mouse.clear();
    permitted = false;
    await tester.tapAt(point);
    await tester.pump(kLongPressTimeout);
    expect(bridge.mouse, isEmpty);

    permitted = true;
    final pendingDown = Completer<void>();
    bridge.pendingDown = pendingDown.future;
    final replaced = await tester.startGesture(point);
    await replaced.moveBy(const Offset(40, 10));
    await tester.pump();
    expect(bridge.mouse.where((event) => event.containsKey('buttons')),
        [left.first]);
    await tester.pumpWidget(const SizedBox());
    pendingDown.complete();
    await tester.pump();
    await replaced.cancel();
    expect(bridge.mouse.where((event) => event.containsKey('buttons')), left);
  });
}
