import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/rymu/native_bridge.dart';
import 'package:flutter_hbb/rymu/windows_account.dart';
import 'package:flutter_hbb/rymu/windows_home.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _PendingAccount extends WindowsAccount {
  Completer<bool>? operation;
  @override
  bool get localeSet => true;
  @override
  bool get supportsAutoHost => false;
  @override
  bool get signingIn => operation != null;
  @override
  Future<bool> beginSignIn(
      {required String alias,
      required bool host,
      required void Function(String?) showBrowser}) {
    operation = Completer<bool>();
    showBrowser(null);
    return operation!.future;
  }

  @override
  void cancelEnrollment() {
    final pending = operation;
    operation = null;
    pending?.completeError(const ControlError('sign_in_cancelled'));
    super.cancelEnrollment();
  }
}

void main() {
  _Binding();
  final profile = Platform.environment['RYMU_WINDOWS_TEST_PROFILE'];
  final isolated = Platform.isWindows &&
      profile != null &&
      profile == Platform.environment['LOCALAPPDATA'] &&
      Directory(profile)
          .uri
          .pathSegments
          .any((p) => p.startsWith('rymu-win-qa-'));
  const browser = MethodChannel('plugins.flutter.io/url_launcher');
  const tray = MethodChannel('rymu/windows_tray');
  final cancelled = throwsA(isA<ControlError>()
      .having((error) => error.code, 'code', 'sign_in_cancelled'));

  setUp(() {
    if (isolated) RymuNative.clearWindowsVault();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (_) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(tray, (_) async => true);
  });
  tearDown(() {
    for (final channel in [browser, tray]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    if (isolated) RymuNative.clearWindowsVault();
  });

  Future<(HttpServer, WindowsAccount)> fixture(
      Future<void> Function(HttpRequest, Map<String, dynamic>) handler,
      {bool credentials = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    RymuNative.writeWindowsVault({
      'settings': {
        'api': 'http://127.0.0.1:${server.port}/api/v1',
        'locale': 'en'
      },
      if (credentials)
        'session': {
          'refreshToken': 'previous-valid-credentials',
          'device': {
            'id': 'previous-device',
            'roles': ['controller']
          },
        },
    });
    final account = WindowsAccount(browserReturnPort: 0);
    unawaited(server.forEach((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      await handler(request, body);
    }));
    addTearDown(() async {
      account.dispose();
      await server.close(force: true);
    });
    return (server, account);
  }

  Future<void> reply(HttpRequest request, Map<String, Object?> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    try {
      await request.response.close();
    } on IOException {
      // Cancellation deliberately disconnects an outstanding HTTP request.
    }
  }

  test('cancel frees browser return and allows retry without adopting old flow',
      () async {
    final requests = <Map<String, dynamic>>[];
    final authorize = Completer<HttpRequest>();
    final (_, account) = await fixture((request, body) async {
      requests.add(body);
      if (!authorize.isCompleted) {
        authorize.complete(request);
      } else {
        await reply(request, {'flow': 'account', 'authorizationUrl': '/login'});
      }
    });
    var browserOpened = 0;
    final first = account.beginSignIn(
        alias: 'Test', host: false, showBrowser: (_) => browserOpened++);
    final held = await authorize.future;
    final firstExpectation = expectLater(first, cancelled);
    account.cancelEnrollment();
    await firstExpectation;
    await reply(held, {'flow': 'account', 'authorizationUrl': '/login'});
    expect(browserOpened, 0);
    final oldPort = Uri.parse(requests.first['redirectUri'] as String).port;
    final reclaimed =
        await HttpServer.bind(InternetAddress.loopbackIPv4, oldPort);
    await reclaimed.close(force: true);
    final opened = Completer<void>();
    final retry = account.beginSignIn(
        alias: 'Test', host: false, showBrowser: (_) => opened.complete());
    await opened.future;
    final retryExpectation = expectLater(retry, cancelled);
    account.cancelEnrollment();
    await retryExpectation;
    expect(account.signingIn, isFalse);
    expect(account.pending, isFalse);
    expect(account.signedIn, isFalse);
  }, skip: !isolated);

  test('cancel during enrollment ignores late result and preserves credentials',
      () async {
    late Map<String, dynamic> authorization;
    final heldFinish = Completer<HttpRequest>();
    final (_, account) = await fixture((request, body) async {
      switch (request.uri.path.split('/').last) {
        case 'start':
          if (request.uri.path.contains('/authorize/')) {
            authorization = body;
            await reply(
                request, {'flow': 'account', 'authorizationUrl': '/login'});
          } else {
            await reply(request, {
              'flow': 'account',
              'deviceId': 'new-device',
              'proof': 'RYMU-ENROLL-V1\ntest-cancellation-only'
            });
          }
        case 'token':
          await reply(
              request, {'flow': 'account', 'enrollmentToken': 'test-token'});
        case 'verify':
          await reply(request, {'approved': true});
        case 'finish':
          heldFinish.complete(request);
      }
    }, credentials: true);
    final before = RymuNative.readWindowsVault();
    final opened = Completer<void>();
    final operation = account.beginSignIn(
        alias: 'Test', host: false, showBrowser: (_) => opened.complete());
    await opened.future;
    final client = HttpClient();
    try {
      final callback = Uri.parse(authorization['redirectUri'] as String)
          .replace(queryParameters: {
        'state': authorization['state'] as String,
        'code': List.filled(43, 'a').join()
      });
      final response = await (await client.getUrl(callback)).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    final finish = await heldFinish.future;
    final expectation = expectLater(operation, cancelled);
    account.cancelEnrollment();
    await expectation;
    await reply(finish, {
      'refreshToken': 'late-result-must-not-be-saved',
      'device': {
        'id': 'new-device',
        'roles': ['controller']
      }
    });
    expect(RymuNative.readWindowsVault(), before);
    expect(account.signedIn, isTrue);
    expect(account.deviceId, 'previous-device');
    expect(account.pending, isFalse);
  }, skip: !isolated);

  testWidgets('busy browser sign-in exposes cancel then an enabled retry',
      (tester) async {
    final account = _PendingAccount();
    await tester.pumpWidget(
        MaterialApp(home: RymuWindowsHome(createAccount: () => account)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue in browser'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final cancel = find.widgetWithText(TextButton, 'Cancel sign-in');
    expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('Sign-in canceled. You can try again.'), findsOneWidget);
    final retry = find.ancestor(
        of: find.text('Try again'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.text('Link this computer'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !isolated);
}
