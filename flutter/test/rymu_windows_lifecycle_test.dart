import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/rymu/account_transport.dart';
import 'package:flutter_hbb/rymu/native_bridge.dart';
import 'package:flutter_hbb/rymu/windows_account.dart';
import 'package:flutter_hbb/rymu/windows_home.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('window_manager');
const _trayChannel = MethodChannel('rymu/windows_tray');
const _startupChannel = MethodChannel('rymu/windows_packaged_startup');
const _oldToken = 'test-refresh-before-rotation';
const _newToken = 'test-refresh-after-rotation';

class _LifecycleBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _HostingFixture extends WindowsAccount {
  _HostingFixture(
      {required this.optedIn,
      this.arabic = false,
      this.failures = 0,
      this.packagedWindows = false});

  @override
  final bool packagedWindows;

  final bool optedIn;
  @override
  final bool arabic;
  final int failures;
  int deviceReads = 0;
  int hostStarts = 0;
  int settingsSaves = 0;
  int disposals = 0;
  Completer<void>? holdNextRead;

  @override
  bool get localeSet => true;
  @override
  bool get signedIn => true;
  @override
  bool get isHost => true;
  @override
  bool get supportsAutoHost => true;
  @override
  bool get autoHost => optedIn;
  @override
  AccountTransport get transport => const AccountTransport.managed();

  @override
  Future<List<Map<String, dynamic>>> devices() async {
    final hold = holdNextRead;
    holdNextRead = null;
    deviceReads++;
    if (hold != null) await hold.future;
    if (deviceReads <= failures) {
      throw const ControlError('service_unavailable');
    }
    return [];
  }

  @override
  Future<bool> startHost(bool Function() stillRequested) async {
    if (!stillRequested()) return false;
    hostStarts++;
    return true;
  }

  @override
  void saveSettings({
    required String api,
    required String rendezvous,
    required String relay,
    required String key,
    required bool ar,
  }) {
    settingsSaves++;
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

class _StartupFixture extends WindowsAccount {
  _StartupFixture({this.installerChoice});
  final bool? installerChoice;
  final changes = <bool>[];
  @override
  bool get supportsAutoHost => true;
  @override
  bool? get installerStartupPreference => installerChoice;
  @override
  void setAutoHost(bool enabled) => changes.add(enabled);
}

class _PackagedAccount extends WindowsAccount {
  @override
  bool get packagedWindows => true;
}

void main() {
  _LifecycleBinding();
  final profile = Platform.environment['RYMU_WINDOWS_TEST_PROFILE'];
  final isolated = Platform.isWindows &&
      profile != null &&
      profile == Platform.environment['LOCALAPPDATA'] &&
      Directory(profile)
          .uri
          .pathSegments
          .any((part) => part.startsWith('rymu-win-qa-'));

  setUp(() {
    if (isolated) RymuNative.clearWindowsVault();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_trayChannel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_startupChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_trayChannel, null);
  });

  void emitClose(WidgetTester tester) {
    unawaited(tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onEvent', {'eventName': 'close'}),
      ),
      (_) {},
    ));
  }

  void emitQuit(WidgetTester tester) {
    unawaited(tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _trayChannel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('quit')),
      (_) {},
    ));
  }

  testWidgets('close hides to tray and hosting continues until explicit quit',
      (tester) async {
    final calls = <MethodCall>[];
    final trayCalls = <String>[];
    final account = _HostingFixture(optedIn: true);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_trayChannel, (call) async {
      trayCalls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await tester.pumpWidget(
        MaterialApp(home: RymuWindowsHome(createAccount: () => account)));
    await tester.pump();
    emitClose(tester);
    emitClose(tester);
    await tester.pump();
    expect(trayCalls.where((method) => method == 'hide'), hasLength(2));
    expect(calls, isEmpty);
    expect(account.disposals, 0);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(account.deviceReads, 2);
    emitQuit(tester);
    emitQuit(tester);
    await tester.pump();
    expect(account.disposals, 1);
    expect(trayCalls, contains('remove'));
    expect(calls.map((call) => call.method), ['setPreventClose', 'close']);
    expect(calls.first.arguments, {'isPreventClose': false});
    await tester.pumpWidget(const SizedBox.shrink());
    emitClose(tester);
    await tester.pump();
    expect(calls, hasLength(2));
  }, skip: !isolated);

  test('packaged hosting requires consent and preserves it after relaunch', () {
    RymuNative.writeWindowsVault({
      'session': {
        'refreshToken': _oldToken,
        'device': {
          'id': 'store-host',
          'roles': ['host']
        },
      },
    });
    final account = _PackagedAccount();
    addTearDown(account.dispose);
    account.ensureAutomaticHosting();
    expect(account.autoHost, isFalse);
    account.configureEnrolledHostStartup();
    expect(account.autoHost, isTrue);
    final resumed = _PackagedAccount();
    addTearDown(resumed.dispose);
    expect(resumed.autoHost, isTrue);
    resumed.setAutoHost(false);
    final stopped = _PackagedAccount();
    addTearDown(stopped.dispose);
    stopped.ensureAutomaticHosting();
    expect(stopped.autoHost, isFalse);
    expect(stopped.signedIn, isTrue);
  }, skip: !isolated);

  testWidgets(
      'Store startup needs explicit consent and respects Windows disable',
      (tester) async {
    final calls = <String>[];
    final account = _HostingFixture(optedIn: false, packagedWindows: true);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_startupChannel, (call) async {
      calls.add(call.method);
      return call.method == 'query' ? 'disabled' : 'disabledByUser';
    });
    await tester.pumpWidget(
        MaterialApp(home: RymuWindowsHome(createAccount: () => account)));
    await tester.pumpAndSettle();
    expect(calls, ['query']);
    expect(account.hostStarts, 0);
    await tester.tap(find.widgetWithText(TextButton, 'Settings'));
    await tester.pumpAndSettle();
    final toggle =
        find.widgetWithText(SwitchListTile, 'Start Rymu with Windows');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(calls, ['query', 'enable']);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(find.textContaining('Windows disabled startup for Rymu.'),
        findsOneWidget);
    expect(account.hostStarts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !isolated);

  testWidgets(
      'Store startup error offers retry and policy state stays read-only',
      (tester) async {
    var fail = true;
    final account = _HostingFixture(optedIn: false, packagedWindows: true);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_startupChannel, (_) async {
      if (fail) throw PlatformException(code: 'startup_unavailable');
      return 'enabledByPolicy';
    });
    await tester.pumpWidget(
        MaterialApp(home: RymuWindowsHome(createAccount: () => account)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Settings'));
    await tester.pumpAndSettle();
    final retry = find.text('Retry');
    await tester.ensureVisible(retry);
    fail = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Start Rymu with Windows'));
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    expect(find.textContaining('Your administrator manages'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !isolated);

  testWidgets('tray quit falls back to exit if interception cannot clear',
      (tester) async {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'setPreventClose') {
        throw PlatformException(code: 'close_interception_failed');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await tester.pumpWidget(const MaterialApp(home: RymuWindowsHome()));
    emitQuit(tester);
    await tester.pump();
    expect(calls, ['setPreventClose', 'destroy']);
  }, skip: !isolated);

  testWidgets('failed tray registration keeps the window accessible',
      (tester) async {
    final calls = <String>[];
    final account = _HostingFixture(optedIn: false);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isMinimized') return false;
      return null;
    });
    messenger.setMockMethodCallHandler(_trayChannel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await tester.pumpWidget(
        MaterialApp(home: RymuWindowsHome(createAccount: () => account)));
    await tester.pump();
    emitClose(tester);
    await tester.pump();
    expect(calls, ['isMinimized', 'show']);
    expect(account.disposals, 0);
    expect(
        find.textContaining('background icon is unavailable'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Quit Rymu'));
    await tester.pump();
    expect(calls, ['isMinimized', 'show', 'setPreventClose', 'close']);
    expect(account.disposals, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !isolated);

  test('old host defaults on; explicit stop and saved login survive relaunch',
      () async {
    RymuNative.writeWindowsVault({
      'settings': {'api': 'http://127.0.0.1:18787/api/v1'},
      'session': {
        'refreshToken': _oldToken,
        'accessToken': 'saved-access-token',
        'expiresAt': 2100000000000,
        'device': {
          'id': 'isolated-host',
          'roles': ['host', 'controller'],
        },
      },
    });
    final oldHost = _StartupFixture();
    oldHost.ensureAutomaticHosting();
    expect(oldHost.changes, [true]);
    oldHost.dispose();
    final installerOff = _StartupFixture(installerChoice: false);
    installerOff.ensureAutomaticHosting();
    installerOff.configureEnrolledHostStartup();
    expect(installerOff.changes, [false, false]);
    installerOff.dispose();
    final stopped = WindowsAccount();
    stopped.setAutoHost(false);
    stopped.dispose();
    final resumed = _StartupFixture();
    addTearDown(resumed.dispose);
    resumed.ensureAutomaticHosting();
    expect(resumed.changes, isEmpty);
    resumed.configureEnrolledHostStartup();
    expect(resumed.changes, [false]);
    expect(resumed.signedIn, isTrue);
    expect(await resumed.accessToken(), 'saved-access-token');
    expect(
        (RymuNative.readWindowsVault()!['settings']
            as Map)['automaticHostingPreference'],
        isFalse);
  }, skip: !isolated);

  testWidgets(
      'saved host starts without interaction and retries within a budget',
      (tester) async {
    final account = _HostingFixture(optedIn: true, failures: 1);
    await tester.pumpWidget(MaterialApp(
      home: RymuWindowsHome(createAccount: () => account),
    ));
    await tester.pump();
    expect(account.deviceReads, 1);
    expect(account.hostStarts, 0);
    expect(find.text('Start hosting'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        find.text('Waiting for a connection to Rymu. Retrying automatically.'),
        findsOneWidget);

    var reads = 1;
    for (final seconds in [2, 4, 8, 16, 20]) {
      final delay = Duration(seconds: seconds);
      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(account.deviceReads, reads);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(account.deviceReads, ++reads);
      expect(account.hostStarts, 1);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(account.deviceReads, reads);
  }, skip: !isolated);

  testWidgets('narrow Arabic settings stay usable during account refresh',
      (tester) async {
    final account = _HostingFixture(optedIn: false, arabic: true);
    await tester.binding.setSurfaceSize(const Size(340, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data:
            MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.7)),
        child: child!,
      ),
      home: RymuWindowsHome(createAccount: () => account),
    ));
    await tester.pumpAndSettle();
    expect(account.hostStarts, 0);
    await tester.tap(find.widgetWithText(TextButton, 'الإعدادات'));
    await tester.pumpAndSettle();
    final advanced = find.widgetWithText(OutlinedButton, 'متقدم');
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(4));
    expect(tester.takeException(), isNull);

    final held = Completer<void>();
    account.holdNextRead = held;
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(account.deviceReads, 2);
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(account.settingsSaves, 0);
    held.complete();
    await tester.pumpAndSettle();
    expect(account.settingsSaves, 1);
    expect(account.hostStarts, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !isolated);

  group('Windows refresh token rotation', () {
    const rotated = {
      'accessToken': 'fresh-access-token',
      'refreshToken': _newToken,
      'expiresAt': 2000000000000,
      'refreshExpiresAt': 2100000000000,
    };

    WindowsAccount accountAt(int port) {
      RymuNative.writeWindowsVault({
        'settings': {'api': 'http://127.0.0.1:$port/api/v1'},
        'session': {
          'refreshToken': _oldToken,
          'accessToken': 'expired-access-token',
          'expiresAt': 0,
          'device': {
            'id': 'isolated-controller',
            'roles': ['controller'],
          },
        },
      });
      final account = WindowsAccount();
      addTearDown(account.dispose);
      return account;
    }

    Future<WindowsAccount> accountWith(
        List<(int, Map<String, Object?>)> replies,
        List<(Object?, bool)> requests,
        {void Function()? onRequest}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final persisted = RymuNative.readWindowsVault()!['session'] as Map;
        requests
            .add((body['refreshToken'], persisted['refreshPending'] == true));
        onRequest?.call();
        final (status, payload) = replies[requests.length - 1];
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload));
        await request.response.close();
      });
      return accountAt(server.port);
    }

    Matcher code(String value) => throwsA(
        isA<ControlError>().having((error) => error.code, 'code', value));

    test('concurrent callers share a persisted rotation and commit its result',
        () async {
      final requests = <(Object?, bool)>[];
      final visibleState = <(bool, bool)>[];
      late final WindowsAccount account;
      account = await accountWith([(200, rotated)], requests, onRequest: () {
        visibleState.add((account.signedIn, account.needsSignIn));
      });
      expect(await Future.wait([account.accessToken(), account.accessToken()]),
          ['fresh-access-token', 'fresh-access-token']);
      expect(requests, [(_oldToken, true)]);
      expect(visibleState, [(true, false)]);
      final session = RymuNative.readWindowsVault()!['session'] as Map;
      expect(session['refreshToken'], _newToken);
      expect(session.containsKey('refreshPending'), isFalse);
      expect(account.signedIn, isTrue);
    });

    test('refusal before sending leaves the original token retryable',
        () async {
      final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close(force: true);
      final account = accountAt(port);
      await expectLater(account.accessToken(), code('service_unavailable'));
      expect(account.signedIn, isTrue);
      final session = RymuNative.readWindowsVault()!['session'] as Map;
      expect(session['refreshToken'], _oldToken);
      expect(session.containsKey('refreshPending'), isFalse);
    });

    test('ambiguous response requires sign-in after restart and cannot replay',
        () async {
      final requests = <(Object?, bool)>[];
      final account = await accountWith([
        (500, {'error': 'internal_error'}),
      ], requests);
      await expectLater(account.accessToken(), code('refresh_interrupted'));
      expect(account.signedIn, isFalse);
      final resumed = WindowsAccount();
      addTearDown(resumed.dispose);
      expect(resumed.needsSignIn, isTrue);
      await expectLater(resumed.accessToken(), code('refresh_interrupted'));
      expect(requests, [(_oldToken, true)]);
    });

    test('known unconsumed responses preserve the old token until retry',
        () async {
      final requests = <(Object?, bool)>[];
      final account = await accountWith([
        (409, {'error': 'account_suspended'}),
        (429, {'error': 'rate_limited'}),
        (200, rotated),
      ], requests);
      await expectLater(account.accessToken(), code('account_suspended'));
      expect(account.signedIn, isTrue);
      await expectLater(account.accessToken(), code('rate_limited'));
      expect(account.signedIn, isTrue);
      expect(await account.accessToken(), 'fresh-access-token');
      expect(requests, List.filled(3, (_oldToken, true)));
    });
  }, skip: !isolated);
}
