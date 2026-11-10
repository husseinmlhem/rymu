import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_transport.dart';
import 'account_callback_page.dart';
import 'native_bridge.dart';
import 'windows_logon_start.dart';
import 'windows_package_identity.dart';

const _loopback = 'http://127.0.0.1:49383/callback';
const _localBuild = bool.fromEnvironment('RYMU_LOCAL_BUILD');
const _hostedApi = String.fromEnvironment('RYMU_ACCOUNT_API_BASE');
const _localApi = String.fromEnvironment('RYMU_LOCAL_API_BASE',
    defaultValue: 'http://127.0.0.1:18787/api/v1');
const _localWeb = String.fromEnvironment('RYMU_LOCAL_WEB_ORIGIN',
    defaultValue: 'http://localhost:15173');
const _autoHostDevice = 'autoHostDeviceId';
const _autoHostPreference = 'automaticHostingPreference';
const _refreshPending = 'refreshPending';

String _b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

String _random() {
  final random = Random.secure();
  return _b64(
      Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))));
}

class ControlError implements Exception {
  const ControlError(this.code, [this.status]);
  final String code;
  final int? status;
  @override
  String toString() => code;
}

class WindowsAccount {
  Map<String, dynamic> _vault = {};
  Map<String, dynamic>? _pending;
  AccountTransport? _managedTransport;
  HttpServer? _callback;
  Future<String>? _refresh;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'DIRECT';

  WindowsAccount() {
    _vault = RymuNative.readWindowsVault() ?? {};
    final savedApi = _settings['api'];
    if (!_localBuild &&
        _hostedApi.isNotEmpty &&
        (savedApi is! String ||
            Uri.tryParse(savedApi)?.isScheme('https') != true)) {
      // Start a fresh account session on the compiled HTTPS service.
      _vault
        ..remove('session')
        ..remove('seed')
        ..['settings'] = {..._settings, 'api': _hostedApi};
    }
  }

  Map<String, dynamic> get _session =>
      (_vault['session'] as Map<String, dynamic>?) ?? {};
  Map<String, dynamic> get _settings =>
      (_vault['settings'] as Map<String, dynamic>?) ?? {};
  bool get needsSignIn => _refresh == null && _session[_refreshPending] == true;
  bool get signedIn => !needsSignIn && _session['refreshToken'] is String;
  bool get pending => _pending != null;
  String get deviceId => (_session['device'] as Map?)?['id'] as String? ?? '';
  bool get isHost =>
      ((_session['device'] as Map?)?['roles'] as List? ?? []).contains('host');
  String get apiBase =>
      _settings['api'] as String? ?? (_localBuild ? _localApi : _hostedApi);
  String get rendezvous => _settings['rendezvous'] as String? ?? '';
  String get relay => _settings['relay'] as String? ?? '';
  String get rendezvousKey => _settings['key'] as String? ?? '';
  AccountTransport? get _manualTransport => [rendezvous, relay, rendezvousKey]
          .every((value) => value.trim().isNotEmpty)
      ? AccountTransport.manual(rendezvous, relay, rendezvousKey)
      : null;
  AccountTransport? get transport => _manualTransport ?? _managedTransport;
  bool get hasTransport => transport != null;
  bool get packagedWindows => WindowsPackageIdentity.packaged;
  bool get supportsAutoHost => packagedWindows || WindowsLogonStart.supported;
  bool get autoHost =>
      signedIn &&
      isHost &&
      supportsAutoHost &&
      deviceId.isNotEmpty &&
      _settings[_autoHostDevice] == deviceId;
  bool get arabic => _settings['locale'] == 'ar';
  bool get localeSet => _settings['locale'] is String;
  Map<String, dynamic>? get pendingChallenge =>
      _pending?['challenge'] as Map<String, dynamic>?;
  bool get pendingAccountSignIn => pendingChallenge?['flow'] == 'account';

  static Uri _checkedApi(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (!uri.isScheme('https') &&
            !(_localBuild &&
                uri.isScheme('http') &&
                uri.host == '127.0.0.1')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/api/v1') {
      throw const ControlError('invalid_service_address');
    }
    return uri;
  }

  void saveSettings({
    required String api,
    required String rendezvous,
    required String relay,
    required String key,
    required bool ar,
  }) {
    if (api.isNotEmpty) _checkedApi(api);
    if (api != apiBase && (signedIn || pending)) {
      throw const ControlError('sign_out_before_changing_service');
    }
    final previous = _manualTransport;
    final manual = [rendezvous, relay, key].any((value) => value.isNotEmpty)
        ? AccountTransport.manual(rendezvous, relay, key)
        : null;
    if (manual != null && previous != manual) _configureTransport(manual);
    _save({
      ..._vault,
      'settings': {
        ..._settings,
        'api': api,
        'rendezvous': rendezvous,
        'relay': relay,
        'key': key,
        'locale': ar ? 'ar' : 'en',
      },
    });
    if (previous != null && manual == null) {
      RymuNative.clearTransport();
    }
  }

  void _save(Map<String, dynamic> next) {
    RymuNative.writeWindowsVault(next);
    _vault = next;
  }

  void _configureTransport(AccountTransport route) {
    try {
      RymuNative.configureTransport(route);
    } on RymuNativeException {
      throw const ControlError('invalid_transport');
    }
  }

  void _setManagedTransport(AccountTransport? value) {
    final previous = transport;
    _managedTransport = value;
    if (previous != null && previous != transport) {
      RymuNative.clearTransport();
    }
  }

  void setAutoHost(bool enabled) {
    final settings = {..._settings, _autoHostPreference: enabled};
    if (packagedWindows) {
      // Store startup permission is a separate, explicitly requested OS task.
      // Saving hosting consent must never change Windows startup settings.
      if (enabled) {
        if (!signedIn || !isHost || deviceId.isEmpty) {
          throw const ControlError('host_not_enrolled');
        }
        settings[_autoHostDevice] = deviceId;
      } else {
        settings.remove(_autoHostDevice);
      }
      _save({..._vault, 'settings': settings});
      return;
    }
    if (enabled) {
      if (!signedIn || !isHost || deviceId.isEmpty) {
        throw const ControlError('host_not_enrolled');
      }
      _setWindowsStartup(true);
      try {
        _save({..._vault, 'settings': settings..[_autoHostDevice] = deviceId});
      } catch (_) {
        _setWindowsStartup(false);
        rethrow;
      }
    } else {
      settings.remove(_autoHostDevice);
      _vault = {..._vault, 'settings': settings};
      try {
        _save(_vault);
      } finally {
        _setWindowsStartup(false);
      }
    }
    _clearInstallerStartupPreference();
  }

  void ensureAutomaticHosting() {
    if (packagedWindows) return;
    if (signedIn && isHost && supportsAutoHost && deviceId.isNotEmpty) {
      final choice = installerStartupPreference;
      if (choice != null) {
        setAutoHost(choice);
      } else if (_settings[_autoHostPreference] is! bool) {
        setAutoHost(true);
      }
    }
  }

  bool? get installerStartupPreference {
    if (packagedWindows) return null;
    try {
      return WindowsLogonStart.pendingInstallerPreference;
    } on StateError {
      throw const ControlError('windows_startup_unavailable');
    }
  }

  void configureEnrolledHostStartup() {
    setAutoHost(installerStartupPreference ??
        (_settings[_autoHostPreference] as bool?) ??
        true);
  }

  void _clearInstallerStartupPreference() {
    if (packagedWindows) return;
    try {
      WindowsLogonStart.clearInstallerPreference();
    } on StateError {
      throw const ControlError('windows_startup_unavailable');
    }
  }

  void _setWindowsStartup(bool enabled) {
    if (packagedWindows) return;
    try {
      WindowsLogonStart.setEnabled(enabled);
    } on StateError {
      throw const ControlError('windows_startup_unavailable');
    }
  }

  Future<Map<String, dynamic>> _send(String method, String route,
      {String? bearer,
      Map<String, Object?>? body,
      void Function()? beforeSend}) async {
    final base = _checkedApi(apiBase);
    final uri = base.replace(path: '${base.path}$route');
    try {
      final request =
          await _http.openUrl(method, uri).timeout(const Duration(seconds: 6));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      try {
        beforeSend?.call();
      } catch (_) {
        unawaited(request.done
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
        request.abort();
        rethrow;
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response =
          await request.close().timeout(const Duration(seconds: 6));
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 6))) {
        if (bytes.length + chunk.length > 262144) {
          throw const ControlError('unexpected_response');
        }
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const ControlError('unexpected_response');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ControlError(
            value['error'] as String? ?? 'request_denied', response.statusCode);
      }
      return value;
    } on IOException {
      throw const ControlError('service_unavailable');
    } on TimeoutException {
      throw const ControlError('service_unavailable');
    } on FormatException {
      throw const ControlError('unexpected_response');
    }
  }

  Future<bool> beginSignIn({
    required String alias,
    required bool host,
    required void Function(String? code) showBrowser,
  }) async {
    final base = _checkedApi(apiBase);
    final verifier = _random();
    final state = _random();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 49383);
    _callback = server;
    final response = Completer<String>();
    unawaited(server.forEach((request) async {
      final q = request.uri.queryParametersAll;
      final code = q['code'];
      final valid = request.method == 'GET' &&
          request.uri.path == '/callback' &&
          request.headers.value('host') == '127.0.0.1:49383' &&
          q['state']?.length == 1 &&
          q['state']?.single == state &&
          code?.length == 1 &&
          RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code!.single) &&
          !response.isCompleted;
      final page = AccountCallbackPage(
          valid: valid,
          arabic: localeSet
              ? arabic
              : Platform.localeName.toLowerCase().startsWith('ar'));
      request.response
        ..statusCode = valid ? 200 : 400
        ..headers.contentType = ContentType.html
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.set('Content-Security-Policy', page.contentSecurityPolicy)
        ..headers.set('Referrer-Policy', 'no-referrer')
        ..headers.set('X-Content-Type-Options', 'nosniff')
        ..headers.set('X-Frame-Options', 'DENY')
        ..write(page.html);
      await request.response.close();
      if (valid && !response.isCompleted) response.complete(code.single);
    }));
    try {
      final authorization =
          await _send('POST', '/native/authorize/start', body: {
        'codeChallenge': _b64(sha256.convert(utf8.encode(verifier)).bytes),
        'state': state,
        'redirectUri': _loopback,
        'flow': 'account',
      });
      final url = _browserUri(base, authorization['authorizationUrl']);
      final accountFlow = authorization['flow'] == 'account';
      if (!accountFlow && authorization['verificationCode'] is! String) {
        throw const ControlError('unexpected_response');
      }
      showBrowser(
          accountFlow ? null : authorization['verificationCode'] as String);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const ControlError('browser_unavailable');
      }
      final code = await response.future.timeout(const Duration(minutes: 4));
      final token = await _send('POST', '/native/token', body: {
        'code': code,
        'codeVerifier': verifier,
        'redirectUri': _loopback,
      });
      if (accountFlow != (token['flow'] == 'account')) {
        throw const ControlError('unexpected_response');
      }
      final bearer =
          (token['enrollmentToken'] ?? token['accessToken']) as String;
      final seed = _random();
      final challenge =
          await _send('POST', '/native/enroll/start', bearer: bearer, body: {
        'alias': alias,
        'platform': 'windows',
        'roles': host ? ['host', 'controller'] : ['controller'],
        'devicePublicKey': RymuNative.devicePublicKey(seed),
        if (host) ...RymuNative.identity(),
        if (host) 'hostConfirmed': true,
      });
      if (accountFlow != (challenge['flow'] == 'account')) {
        throw const ControlError('unexpected_response');
      }
      if (!accountFlow) {
        await _verifyEnrollment(bearer, challenge, seed);
      }
      _pending = {
        'bearer': bearer,
        'challenge': challenge,
        'seed': seed,
        'host': host,
      };
      if (accountFlow) return await finishSignIn();
      return false;
    } finally {
      _callback = null;
      await server.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _verifyEnrollment(
          String bearer, Map<String, dynamic> challenge, String seed) =>
      _send('POST', '/native/enroll/verify', bearer: bearer, body: {
        'deviceId': challenge['deviceId'],
        'signature':
            RymuNative.signEnrollment(seed, challenge['proof'] as String),
      });

  static Uri _browserUri(Uri base, Object? value) {
    final url = base.resolve(value as String);
    final localBrowser =
        _localBuild && base.host == '127.0.0.1' && url.origin == _localWeb;
    if ((!localBrowser && url.origin != base.origin) ||
        url.userInfo.isNotEmpty) {
      throw const ControlError('unexpected_browser_origin');
    }
    return url;
  }

  Future<void> openApproval() async {
    final challenge = pendingChallenge;
    if (challenge == null || pendingAccountSignIn) {
      throw const ControlError('enrollment_not_started');
    }
    if (!await launchUrl(
        _browserUri(_checkedApi(apiBase), challenge['approvalUrl']),
        mode: LaunchMode.externalApplication)) {
      throw const ControlError('browser_unavailable');
    }
  }

  Future<bool> finishSignIn() async {
    final pending = _pending;
    if (pending == null) throw const ControlError('enrollment_not_started');
    final challenge = pendingChallenge!;
    final bearer = pending['bearer'] as String;
    if (pendingAccountSignIn && pending['verified'] != true) {
      try {
        final result = await _verifyEnrollment(
            bearer, challenge, pending['seed'] as String);
        if (result['approved'] != true) {
          throw const ControlError('unexpected_response');
        }
        pending['verified'] = true;
      } on ControlError catch (error) {
        if (error.code != 'invalid_device_proof') rethrow;
        // Finish can recover a verification response lost after proof consumption.
      }
    }
    final value = await _send('POST', '/native/enroll/finish',
        bearer: bearer, body: {'deviceId': challenge['deviceId']});
    final settings = {..._settings, 'api': apiBase};
    final wasAutomatic = settings.remove(_autoHostDevice) != null;
    _save({
      ..._vault,
      'settings': settings,
      'session': value,
      'seed': pending['seed'],
    });
    _pending = null;
    if (wasAutomatic) _setWindowsStartup(false);
    return pending['host'] == true && isHost;
  }

  void cancelEnrollment() => _pending = null;

  Future<String> accessToken() async {
    final inFlight = _refresh;
    if (inFlight != null) return inFlight;
    if (needsSignIn) throw const ControlError('refresh_interrupted');
    if (!signedIn) throw const ControlError('sign_in_required');
    final current = _session;
    if ((current['expiresAt'] as num? ?? 0) >
        DateTime.now().millisecondsSinceEpoch + 120000) {
      return current['accessToken'] as String;
    }
    _refresh = _rotateTokens(current);
    try {
      return await _refresh!;
    } finally {
      _refresh = null;
    }
  }

  Future<String> _rotateTokens(Map<String, dynamic> current) async {
    try {
      final value = await _send('POST', '/native/refresh',
          body: {'refreshToken': current['refreshToken']}, beforeSend: () {
        // Do not replay a token if the server may have consumed it. A failed
        // connection before this point leaves the original token retryable.
        _save({
          ..._vault,
          'session': {...current, _refreshPending: true}
        });
      });
      final access = value['accessToken'];
      final refresh = value['refreshToken'];
      final expires = value['expiresAt'];
      final refreshExpires = value['refreshExpiresAt'];
      if (access is! String ||
          access.isEmpty ||
          refresh is! String ||
          refresh.isEmpty ||
          refresh == current['refreshToken'] ||
          expires is! num ||
          refreshExpires is! num) {
        throw const ControlError('refresh_interrupted');
      }
      _save({
        ..._vault,
        'session': {
          ...current,
          'accessToken': access,
          'refreshToken': refresh,
          'expiresAt': expires,
          'refreshExpiresAt': refreshExpires,
        }
      });
      return access;
    } on ControlError catch (error) {
      if (_session[_refreshPending] != true) rethrow;
      if ((error.status == 409 && error.code == 'account_suspended') ||
          (error.status == 429 && error.code == 'rate_limited')) {
        _save({..._vault, 'session': current});
        rethrow;
      }
      if (error.status == 401 || error.status == 403) {
        forgetSignIn();
        rethrow;
      }
      throw const ControlError('refresh_interrupted');
    } catch (_) {
      if (_session[_refreshPending] != true) rethrow;
      throw const ControlError('refresh_interrupted');
    }
  }

  Future<List<Map<String, dynamic>>> devices() async {
    try {
      final value = await _send('GET', '/devices', bearer: await accessToken());
      final devices = (value['devices'] as List).cast<Map<String, dynamic>>();
      _setManagedTransport(readAccountTransport(value['transport']));
      return devices;
    } on ControlError catch (error) {
      if (signedIn && error.status == 401) forgetSignIn();
      _setManagedTransport(null);
      rethrow;
    } catch (_) {
      _setManagedTransport(null);
      rethrow;
    }
  }

  Future<bool> startHost(bool Function() stillRequested) async {
    if (!isHost) throw const ControlError('host_not_enrolled');
    final route = transport;
    if (route == null) throw const ControlError('transport_unconfigured');
    final token = await accessToken();
    if (!stillRequested() || route != transport) return false;
    _configureTransport(route);
    RymuNative.enableHost(deviceId, apiBase, token);
    return true;
  }

  Future<bool> heartbeat(int displayCount, bool Function() stillHosting) async {
    final token = await accessToken();
    if (!stillHosting()) return false;
    RymuNative.updateHostBearer(deviceId, apiBase, token);
    if (!RymuNative.hostOnline() || displayCount < 1) return false;
    try {
      await _send('POST', '/native/heartbeat', bearer: token, body: {
        'displayCount': displayCount.clamp(1, 32),
      });
    } on ControlError catch (error) {
      if (signedIn && error.status == 401) forgetSignIn();
      rethrow;
    }
    return true;
  }

  Future<void> stage(Map<String, dynamic> device,
      {required bool viewOnly, required bool files}) async {
    final token = await accessToken();
    final route = transport;
    if (route == null) throw const ControlError('transport_unconfigured');
    RymuNative.stageSession(
      peerId: device['peerId'] as String,
      hostId: device['id'] as String,
      peerPublicKey: device['peerPublicKey'] as String,
      accessToken: token,
      signingSeed: _vault['seed'] as String,
      apiBase: apiBase,
      transport: route,
      viewOnly: viewOnly,
      files: files,
      controllerId: deviceId,
    );
  }

  Future<void> signOut() async {
    await _send('POST', '/native/logout',
        bearer: await accessToken(), body: {});
    forgetSignIn();
  }

  void forgetSignIn() {
    RymuNative.clearTransport();
    _managedTransport = null;
    final settings = {..._settings, _autoHostPreference: false};
    final wasAutomatic = settings.remove(_autoHostDevice) != null;
    RymuNative.clearWindowsVault();
    _pending = null;
    _vault = {'settings': settings};
    try {
      _save(_vault);
    } finally {
      if (wasAutomatic) _setWindowsStartup(false);
    }
    _clearInstallerStartupPreference();
  }

  void dispose() {
    try {
      RymuNative.disableHost();
    } finally {
      unawaited(_callback?.close(force: true));
      _http.close(force: true);
    }
  }
}
