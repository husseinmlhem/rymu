import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/rymu/account_transport.dart';
import 'package:flutter_hbb/rymu_android/account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final state = List.filled(43, 's').join();
  final code = List.filled(43, 'c').join();
  final expected = 'app.rymu://oauth/callback?code=$code&state=$state';

  test('extracts the authorization code only for the correct state', () {
    expect(verifiedOAuthCode(expected, state), code);
    expect(() => verifiedOAuthCode(expected, List.filled(43, 'x').join()),
        throwsA(isA<AccountProblem>()));
  });

  test('rejects ambiguous and foreign browser callbacks', () {
    for (final url in [
      '$expected&state=$state',
      '$expected&code=$code',
      '$expected#x',
      expected.replaceFirst('oauth/', 'other/'),
      expected.replaceFirst('/callback', '/%63allback'),
      expected.replaceFirst('oauth/', 'oauth:123/'),
      expected.replaceFirst('oauth/', 'attacker@oauth/'),
      expected.replaceFirst('app.rymu:', 'https:'),
      expected.replaceFirst('code=$code', 'code=short'),
    ]) {
      expect(
          () => verifiedOAuthCode(url, state), throwsA(isA<AccountProblem>()),
          reason: url);
    }
  });

  test('browser destinations stay on the configured account origin', () {
    final config = AndroidAccountConfig();
    expect(
        config
            .checkedBrowserUrl('http://localhost:15173/account?request=1')
            .host,
        'localhost');
    for (final target in [
      'https://foreign.example/account',
      'http://127.0.0.1:15173/account',
      'http://localhost:8787/account',
      'http://local@localhost:15173/account',
      'http://localhost:15173/account#secret',
      '//localhost:15173/account',
    ]) {
      expect(() => config.checkedBrowserUrl(target),
          throwsA(isA<AccountProblem>()));
    }
  });

  group('Android account enrollment', () {
    for (final scenario in [
      'account',
      'resume after lost proof response',
      'legacy'
    ]) {
      test(scenario, () async {
        final accountFlow = scenario != 'legacy';
        final interrupted = scenario == 'resume after lost proof response';
        final config = AndroidAccountConfig();
        final expires = DateTime.now().millisecondsSinceEpoch + 120000;
        final seed = List.filled(43, 'e').join();
        final publicKey = List.filled(43, 'p').join();
        final signature = List.filled(86, 'q').join();
        final browserUrl = config.site.resolve('/account').toString();
        final calls = <String>[];
        String? stored;
        var verified = false;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(rymuAndroidChannel, (call) async {
          switch (call.method) {
            case 'createPkce':
              return {
                'challenge': 'challenge',
                'verifier': 'verifier',
                'state': state
              };
            case 'readAccount':
              return stored;
            case 'writeAccount':
              stored = call.arguments as String;
              return null;
            case 'signingSeed':
              return seed;
            default:
              fail('Unexpected channel method ${call.method}');
          }
        });
        addTearDown(
            () => messenger.setMockMethodCallHandler(rymuAndroidChannel, null));

        AndroidAccount createAccount() {
          final account = AndroidAccount(
            config,
            deviceKey: (value) {
              expect(value, seed);
              return publicKey;
            },
            signProof: (value, proof) {
              expect(value, seed);
              expect(proof, 'enrollment proof');
              return signature;
            },
            client: MockClient((request) async {
              final path = request.url.path;
              calls.add(path);
              expect(request.followRedirects, isFalse);
              final body =
                  request.body.isEmpty ? null : jsonDecode(request.body);
              http.Response response(Map<String, Object> data) =>
                  http.Response(jsonEncode(data), 200);
              switch (path) {
                case '/api/v1/native/authorize/start':
                  expect(body, {
                    'codeChallenge': 'challenge',
                    'state': state,
                    'redirectUri': 'app.rymu://oauth/callback',
                    'flow': 'account',
                  });
                  return response({
                    'authorizationUrl': browserUrl,
                    'expiresAt': expires,
                    if (accountFlow)
                      'flow': 'account'
                    else
                      'verificationCode': '12345678',
                  });
                case '/api/v1/native/token':
                  expect(body, {
                    'code': code,
                    'codeVerifier': 'verifier',
                    'redirectUri': 'app.rymu://oauth/callback',
                  });
                  return response({
                    'enrollmentToken': 'test-enrollment-token',
                    'expiresAt': expires,
                    if (accountFlow) 'flow': 'account',
                  });
                case '/api/v1/native/enroll/start':
                  expect(request.headers['authorization'],
                      'Bearer test-enrollment-token');
                  expect(body, {
                    'alias': 'Android phone',
                    'platform': 'android',
                    'roles': ['controller'],
                    'devicePublicKey': publicKey,
                  });
                  return response({
                    'deviceId': 'test-phone',
                    'proof': 'enrollment proof',
                    'expiresAt': expires,
                    if (accountFlow)
                      'flow': 'account'
                    else ...{
                      'verificationCode': '12345678',
                      'approvalUrl': browserUrl,
                    },
                  });
                case '/api/v1/native/enroll/verify':
                  expect(request.headers['authorization'],
                      'Bearer test-enrollment-token');
                  expect(
                      body, {'deviceId': 'test-phone', 'signature': signature});
                  verified = true;
                  if (interrupted) {
                    throw http.ClientException('proof response lost');
                  }
                  return response(
                      {'ok': true, if (accountFlow) 'approved': true});
                case '/api/v1/native/enroll/finish':
                  expect(verified, isTrue);
                  expect(request.headers['authorization'],
                      'Bearer test-enrollment-token');
                  expect(body, {'deviceId': 'test-phone'});
                  return response({
                    'accessToken': 'test-access',
                    'refreshToken': 'test-refresh',
                    'expiresAt': expires,
                    'refreshExpiresAt': expires,
                  });
                case '/api/v1/devices':
                  expect(request.method, 'GET');
                  expect(
                      request.headers['authorization'], 'Bearer test-access');
                  return response({
                    'devices': [],
                    if (accountFlow) 'transport': {'mode': 'managed'},
                  });
                default:
                  fail('Unexpected request $path');
              }
            }),
          );
          addTearDown(account.dispose);
          return account;
        }

        var account = createAccount();
        await account.beginLogin();
        expect(account.pendingLogin?['verificationCode'],
            accountFlow ? null : '12345678');
        await account.finishLogin(expected);
        expect(account.accountEnrollment, accountFlow);
        if (interrupted) {
          await expectLater(
              account.beginEnrollment('Android phone'),
              throwsA(isA<AccountProblem>().having(
                  (problem) => problem.code, 'code', 'network_unavailable')));
          expect(account.session, isNull);
          account = createAccount();
          await account.restore();
          expect(account.enrollment?['deviceId'], 'test-phone');
        }
        await account.beginEnrollment('Android phone');
        if (!accountFlow) {
          expect(account.session, isNull);
          expect(account.enrollment?['verificationCode'], '12345678');
          expect(account.enrollment?['url'], browserUrl);
          await account.finishEnrollment();
        }
        expect(account.enrollment, isNull);
        expect(account.session?['deviceId'], 'test-phone');
        expect(account.managedTransport, isNull);
        expect(await account.hosts(), isEmpty);
        expect(
            account.managedTransport?.isManaged, accountFlow ? isTrue : isNull);
        expect(calls, [
          '/api/v1/native/authorize/start',
          '/api/v1/native/token',
          '/api/v1/native/enroll/start',
          '/api/v1/native/enroll/verify',
          '/api/v1/native/enroll/finish',
          '/api/v1/devices',
        ]);
      });
    }
  });

  group('Android refresh rotation', () {
    final config = AndroidAccountConfig();
    late String? stored;
    late bool failWrite;
    late int requests;

    Matcher problem(String code) =>
        isA<AccountProblem>().having((problem) => problem.code, 'code', code);

    http.Response rotated() {
      final expires = DateTime.now().millisecondsSinceEpoch + 120000;
      return http.Response(
        jsonEncode({
          'accessToken': 'new-access',
          'refreshToken': 'new-refresh',
          'expiresAt': expires,
          'refreshExpiresAt': expires,
        }),
        200,
      );
    }

    setUp(() {
      requests = 0;
      failWrite = false;
      final expires = DateTime.now().millisecondsSinceEpoch + 120000;
      stored = jsonEncode({
        'api': config.api.toString(),
        'session': {
          'deviceId': 'test-phone',
          'accessToken': 'old-access',
          'refreshToken': 'old-refresh',
          'expiresAt': expires,
          'refreshExpiresAt': expires,
        },
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(rymuAndroidChannel, (call) async {
        switch (call.method) {
          case 'readAccount':
            return stored;
          case 'writeAccount':
            if (failWrite) throw PlatformException(code: 'write_failed');
            stored = call.arguments as String;
          case 'clearAccount':
            stored = null;
          default:
            fail('Unexpected channel method ${call.method}');
        }
        return null;
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(rymuAndroidChannel, null));
    });

    AndroidAccount make(Future<http.Response> Function() respond) {
      final account = AndroidAccount(config, client: MockClient((request) {
        requests++;
        expect(request.url.path, '/api/v1/native/refresh');
        expect(jsonDecode(request.body), {'refreshToken': 'old-refresh'});
        expect(jsonDecode(stored!)['session']['refreshPending'], isTrue);
        return respond();
      }));
      addTearDown(account.dispose);
      return account;
    }

    test('writes a marker and shares exactly one in-flight rotation', () async {
      final response = Completer<http.Response>();
      final account = make(() => response.future);
      await account.restore();
      final first = account.accessToken(forceRefresh: true);
      final second = account.accessToken();
      response.complete(rotated());
      expect(await Future.wait([first, second]), ['new-access', 'new-access']);
      expect(requests, 1);
      expect(jsonDecode(stored!)['session']['refreshPending'], isNull);
      expect(jsonDecode(stored!)['session']['refreshToken'], 'new-refresh');
    });

    test('lost response cannot replay the token in memory or after restart',
        () async {
      final account = make(() async => throw http.ClientException('lost'));
      await account.restore();
      await expectLater(account.accessToken(forceRefresh: true),
          throwsA(problem('refresh_interrupted')));
      await expectLater(
          account.accessToken(), throwsA(problem('refresh_interrupted')));
      final restarted = make(() async => fail('Refresh must not be replayed'));
      await expectLater(
          restarted.restore(), throwsA(problem('refresh_interrupted')));
      expect(requests, 1);
      expect(restarted.session, isNull);
      expect(stored, isNull);
    });

    test('a failed final write leaves the marker and blocks replay', () async {
      final account = make(() async {
        failWrite = true;
        return rotated();
      });
      await account.restore();
      await expectLater(account.accessToken(forceRefresh: true),
          throwsA(problem('refresh_interrupted')));
      expect(jsonDecode(stored!)['session']['refreshPending'], isTrue);
      await expectLater(account.accessToken(forceRefresh: true),
          throwsA(problem('refresh_interrupted')));
      expect(requests, 1);
    });

    for (final (status, code) in [
      (409, 'account_suspended'),
      (429, 'rate_limited')
    ]) {
      test('$code preserves the known-unconsumed token', () async {
        final account = make(() async => requests == 1
            ? http.Response(jsonEncode({'error': code}), status)
            : rotated());
        await account.restore();
        await expectLater(
            account.accessToken(forceRefresh: true), throwsA(problem(code)));
        expect(jsonDecode(stored!)['session']['refreshPending'], isNull);
        expect(await account.accessToken(forceRefresh: true), 'new-access');
        expect(requests, 2);
      });
    }

    test('clearing during a delayed response cannot revive the session',
        () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final account = make(() {
        started.complete();
        return response.future;
      });
      await account.restore();
      final rejected = expectLater(account.accessToken(forceRefresh: true),
          throwsA(problem('refresh_interrupted')));
      await started.future;
      await account.clearLocal();
      response.complete(rotated());
      await rejected;
      expect(account.session, isNull);
      expect(stored, isNull);
    });

    test('a malformed stored session clears without crashing widgets',
        () async {
      stored = jsonEncode({'api': config.api.toString(), 'session': []});
      final account = make(() async => fail('Corrupt account cannot refresh'));
      await expectLater(
          account.restore(), throwsA(problem('saved_account_invalid')));
      expect(account.session, isNull);
      expect(stored, isNull);
      expect(requests, 0);
    });
  });

  test('managed transport uses only the account relay mode', () {
    final manual = AccountTransport.manual(
        'r.example:21116', 'r.example:21117', 'pinned-test-key');
    final raw = manual.toNativeOptions();
    expect(raw, {
      'rendezvousServer': 'r.example:21116',
      'relayServer': 'r.example:21117',
      'rendezvousKey': 'pinned-test-key',
    });
    expect(readAccountTransport(raw), isNull);
    expect(readAccountTransport({'mode': 'future'}), isNull);
    final managed = readAccountTransport({...raw, 'mode': 'managed'});
    expect(managed, readAccountTransport({'mode': 'managed'}));
    expect(managed, isNot(manual));
    expect(managed?.toNativeOptions(), {'transportMode': 'managed'});
  });

  test('an online host requires a peer identity before Connect can be enabled',
      () {
    final host = {
      'id': 'test-host',
      'alias': 'Windows QA host',
      'state': 'online',
      'peerId': 'test-peer',
      'peerPublicKey': 'test-key',
    };
    expect(AndroidHost.fromJson(host).connectable, isTrue);
    expect(AndroidHost.fromJson({...host, 'peerPublicKey': null}).connectable,
        isFalse);
    expect(AndroidHost.fromJson({...host, 'state': 'offline'}).connectable,
        isFalse);
  });

  test(
      'private server settings persist together and leave missing values disabled',
      () {
    const route = AndroidTransportSettings(
        '192.168.1.100:21116', '192.168.1.100:21117', 'test-public-key');
    final restored =
        AndroidTransportSettings.fromLocalOption(route.toLocalOption());
    expect(restored.configured, isTrue);
    expect(restored.rendezvous, route.rendezvous);
    expect(restored.relay, route.relay);
    expect(restored.serverKey, route.serverKey);
    expect(AndroidTransportSettings.fromLocalOption(''),
        same(AndroidTransportSettings.defaults));
    for (final value in [
      '{',
      '[]',
      '{"rendezvous":"localhost"}',
      '{"rendezvous":"localhost","relay":"localhost","serverKey":""}'
    ]) {
      expect(
          AndroidTransportSettings.fromLocalOption(value).configured, isFalse);
    }
  });
}
