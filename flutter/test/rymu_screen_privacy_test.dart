import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart'
    show SessionID, OverlayDialogManager;
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/rymu_android/appearance.dart';
import 'package:flutter_hbb/rymu_android/screen_privacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _PrivacyBridge extends Fake implements RustdeskImpl {
  bool confirmed = false;

  @override
  bool sessionGetToggleOptionSync(
          {required SessionID sessionId, required String arg, dynamic hint}) =>
      confirmed;
}

class _PrivacySession extends Fake implements FFI {
  @override
  final id = 'privacy-test-peer';
  @override
  final sessionId = const Uuid().v4obj();
  @override
  ConnType get connType => ConnType.defaultConn;
  @override
  late final ffiModel = FfiModel(WeakReference(this));
}

class _PrivacyDialogs extends Fake implements OverlayDialogManager {}

void main() {
  testWidgets(
      'privacy acknowledges rejection and stops pending and subsequent reconnects',
      (tester) async {
    final bridge = _PrivacyBridge();
    platformFFI.setBindingForTesting(bridge);
    final session = _PrivacySession();
    PrivacyModeState.init(session.id);
    final replies = <String>[];
    session.ffiModel.onRymuPrivacyUpdate =
        () => replies.add(PrivacyModeState.find(session.id).value);
    final restage = Completer<bool>();
    var reconnects = 0;
    session.ffiModel.setRymuReconnectHandler(() {
      reconnects++;
      return restage.future;
    });
    final pendingReconnect =
        session.ffiModel.reconnect(_PrivacyDialogs(), session.sessionId, false);
    for (final confirmed in [false, false, true, false]) {
      bridge.confirmed = confirmed;
      await session.ffiModel
          .updatePrivacyMode(const {}, session.sessionId, session.id);
    }
    expect(replies, ['', '', rymuPrivacyOverlay, '']);
    restage.complete(true);
    await pendingReconnect;
    await session.ffiModel
        .reconnect(_PrivacyDialogs(), session.sessionId, false);
    expect(reconnects, 1);
    session.ffiModel.onRymuPrivacyUpdate = null;
    session.ffiModel.dispose();
    PrivacyModeState.delete(session.id);
  });

  testWidgets('privacy waits for the host and never claims a rejected request',
      (tester) async {
    var active = false;
    var reply = Completer<bool>();
    late StateSetter redraw;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, update) {
          redraw = update;
          return RymuScreenPrivacyTile(
            arabic: false,
            active: active,
            available: true,
            onChanged: (_) => reply.future,
          );
        }),
      ),
    ));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.text('Waiting for the computer to confirm…'), findsOneWidget);
    reply.complete(false);
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Screen hiding was not confirmed. Do not start private work.'),
        findsOneWidget);

    reply = Completer<bool>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    redraw(() => active = true);
    reply.complete(true);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
        find.text(
            'All office screens are hidden. They return when you disconnect. If the private session ends, connect again and enable privacy before continuing.'),
        findsOneWidget);

    reply = Completer<bool>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    redraw(() => active = false);
    reply.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported hosts cannot enable but an active session can stop',
      (tester) async {
    var requested = false;
    Widget page(bool active) => MaterialApp(
          home: Scaffold(
            body: RymuScreenPrivacyTile(
              arabic: true,
              active: active,
              available: false,
              onChanged: (value) async {
                requested = true;
                return value;
              },
            ),
          ),
        );
    await tester.pumpWidget(page(false));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.text('تتطلب مضيف ويندوز مدعومًا وصلاحية التحكم به.'),
        findsOneWidget);
    await tester.pumpWidget(page(true));
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
  });

  testWidgets(
      'privacy status keeps disconnect visible at phone and wide widths',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var disconnected = 0;
    for (final width in [320.0, 780.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 720);
      await tester.pumpWidget(MaterialApp(
        theme: rymuAndroidTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
              size: Size(width, 720), textScaler: const TextScaler.linear(2)),
          child: Scaffold(
            body: Column(children: [
              RymuScreenPrivacyStatus(
                arabic: true,
                pending: width == 320,
                onDisconnect: () => disconnected++,
              ),
              Expanded(
                child: ListView(children: [
                  RymuScreenPrivacyTile(
                    arabic: true,
                    active: false,
                    available: true,
                    onChanged: (value) async => value,
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('قطع الاتصال'));
      expect(tester.takeException(), isNull);
    }
    expect(disconnected, 3);
  });
}
