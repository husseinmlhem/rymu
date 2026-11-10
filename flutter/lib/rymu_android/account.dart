import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../rymu/account_transport.dart';
import '../rymu/native_bridge.dart';

const rymuAndroidChannel = MethodChannel('app.rymu/account');
const _redirect = 'app.rymu://oauth/callback';
final _oauthToken = RegExp(r'^[A-Za-z0-9_-]{43,128}$');

class AndroidAccountConfig {
  AndroidAccountConfig()
      : api = Uri.parse(const String.fromEnvironment('RYMU_API_BASE',
            defaultValue: kDebugMode ? 'http://127.0.0.1:18787/api/v1' : '')),
        site = Uri.parse(const String.fromEnvironment('RYMU_WEB_ORIGIN',
            defaultValue: kDebugMode ? 'http://localhost:15173' : ''));

  final Uri api;
  final Uri site;

  bool get valid =>
      _permittedScheme(api) &&
      _permittedScheme(site) &&
      api.path == '/api/v1' &&
      (site.path.isEmpty || site.path == '/');

  bool _permittedScheme(Uri uri) =>
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.host.isNotEmpty &&
      (uri.scheme == 'https' ||
          (kDebugMode &&
              uri.scheme == 'http' &&
              (uri.host == '127.0.0.1' || uri.host == 'localhost')));

  Uri checkedBrowserUrl(Object? value) {
    final target = Uri.tryParse(value is String ? value : '');
    if (!valid ||
        target == null ||
        target.userInfo.isNotEmpty ||
        target.hasFragment ||
        target.scheme != site.scheme ||
        target.host != site.host ||
        target.port != site.port) {
      throw const AccountProblem('invalid_browser_url');
    }
    return target;
  }
}

class AndroidTransportSettings {
  const AndroidTransportSettings(this.rendezvous, this.relay, this.serverKey);

  factory AndroidTransportSettings.fromLocalOption(String value) {
    if (value.isEmpty) return defaults;
    try {
      if (jsonDecode(value)
          case {
            'rendezvous': final String rendezvous,
            'relay': final String relay,
            'serverKey': final String serverKey,
          }) {
        return AndroidTransportSettings(rendezvous, relay, serverKey);
      }
    } on FormatException {
      // A damaged local setting must not enable a transport.
    }
    return const AndroidTransportSettings('', '', '');
  }

  static const localOption = 'rymu-mobile-private-transport';
  static const defaults = AndroidTransportSettings(
    String.fromEnvironment('RYMU_RENDEZVOUS_ENDPOINT'),
    String.fromEnvironment('RYMU_RELAY_ENDPOINT'),
    String.fromEnvironment('RYMU_SERVER_PUBLIC_KEY'),
  );

  final String rendezvous;
  final String relay;
  final String serverKey;

  bool get configured =>
      rendezvous.isNotEmpty && relay.isNotEmpty && serverKey.isNotEmpty;

  String toLocalOption() => jsonEncode({
        'rendezvous': rendezvous,
        'relay': relay,
        'serverKey': serverKey,
      });
}

class AccountProblem implements Exception {
  const AccountProblem(this.code, {this.statusCode});
  final String code;
  final int? statusCode;
}

typedef JsonMap = Map<String, dynamic>;

JsonMap _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const AccountProblem('invalid_response');
  }
  return value;
}

String _string(JsonMap value, String field) {
  final data = value[field];
  if (data is! String || data.isEmpty) {
    throw const AccountProblem('invalid_response');
  }
  return data;
}

int _number(JsonMap value, String field) {
  final data = value[field];
  if (data is! int) throw const AccountProblem('invalid_response');
  return data;
}

int get _now => DateTime.now().millisecondsSinceEpoch;

/// Parse only the exact native redirect. Multiple values and encoded paths are
/// rejected before the authorization code can leave the phone.
String verifiedOAuthCode(String callback, String expectedState) {
  final uri = Uri.tryParse(callback);
  if (uri == null ||
      !callback.startsWith('$_redirect?') ||
      callback.length > 512 ||
      uri.scheme != 'app.rymu' ||
      uri.authority != 'oauth' ||
      uri.path != '/callback' ||
      uri.hasFragment ||
      uri.queryParametersAll.length != 2) {
    throw const AccountProblem('invalid_oauth_callback');
  }
  final code = uri.queryParametersAll['code'];
  final state = uri.queryParametersAll['state'];
  if (code == null ||
      code.length != 1 ||
      !_oauthToken.hasMatch(code.single) ||
      state == null ||
      state.length != 1 ||
      state.single != expectedState) {
    throw const AccountProblem('invalid_oauth_callback');
  }
  return code.single;
}

class AndroidHost {
  AndroidHost.fromJson(JsonMap json)
      : id = _string(json, 'id'),
        alias = _string(json, 'alias'),
        state = _string(json, 'state'),
        displayCount = json['displayCount'] as int?,
        lastSeenAt = json['lastSeenAt'] as int?,
        peerId = json['peerId'] as String?,
        peerPublicKey = json['peerPublicKey'] as String?;

  final String id;
  final String alias;
  final String state;
  final int? displayCount;
  final int? lastSeenAt;
  final String? peerId;
  final String? peerPublicKey;

  bool get online => state == 'online';
  bool get connectable =>
      online &&
      (peerId?.isNotEmpty ?? false) &&
      (peerPublicKey?.isNotEmpty ?? false);
}

class AndroidAccount {
  AndroidAccount(this.config,
      {http.Client? client,
      String Function(String)? deviceKey,
      String Function(String, String)? signProof})
      : _client = client ?? http.Client(),
        _deviceKey = deviceKey ?? RymuNative.devicePublicKey,
        _signProof = signProof ?? RymuNative.signEnrollment;

  final AndroidAccountConfig config;
  final http.Client _client;
  final String Function(String) _deviceKey;
  final String Function(String, String) _signProof;
  JsonMap _state = {};
  AccountTransport? _managedTransport;
  Future<String>? _refresh;
  int _generation = 0;
  bool _disposed = false;

  JsonMap? get pendingLogin => _state['login'] as JsonMap?;
  JsonMap? get enrollment => _state['enrollment'] as JsonMap?;
  JsonMap? get session => _state['session'] as JsonMap?;
  bool get accountEnrollment => enrollment?['flow'] == 'account';
  AccountTransport? get managedTransport => _managedTransport;

  Future<void> restore() async {
    final generation = _generation;
    final saved = await rymuAndroidChannel.invokeMethod<String>('readAccount');
    if (saved == null || _disposed || _generation != generation) return;
    final restored = _decodeStored(saved);
    if (restored == null) {
      await clearLocal();
      throw const AccountProblem('saved_account_invalid');
    }
    if (restored['api'] != config.api.toString()) {
      await clearLocal();
      return;
    }
    if (restored['session'] case {'refreshPending': true}) {
      await clearLocal();
      throw const AccountProblem('refresh_interrupted');
    }
    _state = restored;
  }

  JsonMap? _decodeStored(String saved) {
    try {
      final decoded = _object(jsonDecode(saved));
      if (decoded['api'] != config.api.toString()) return decoded;
      for (final field in const ['login', 'enrollment', 'session']) {
        if (decoded[field] case final value?) _object(value);
      }
      if (decoded['session'] case final JsonMap session) {
        _sessionRecord(session, _string(session, 'deviceId'));
      }
      return decoded;
    } on FormatException {
      return null;
    } on AccountProblem {
      return null;
    }
  }

  void _requireGeneration(int expected) {
    if (_disposed || _generation != expected) {
      throw const AccountProblem('login_required');
    }
  }

  Future<void> _save(JsonMap update, {int? generation}) async {
    final expected = generation ?? _generation;
    _requireGeneration(expected);
    final next = {'api': config.api.toString(), ...update};
    await rymuAndroidChannel.invokeMethod<void>(
        'writeAccount', jsonEncode(next));
    _requireGeneration(expected);
    _state = next;
  }

  Future<void> clearLocal() async {
    _resetLocalState();
    await rymuAndroidChannel.invokeMethod<void>('clearAccount');
  }

  void _resetLocalState() {
    _generation++;
    _refresh = null;
    _managedTransport = null;
    _state = {};
  }

  Future<JsonMap> _request(String path, {JsonMap? body, String? bearer}) async {
    if (!config.valid) throw const AccountProblem('configuration_missing');
    try {
      return await _send(path, body: body, bearer: bearer)
          .timeout(const Duration(seconds: 12));
    } on AccountProblem {
      rethrow;
    } on TimeoutException {
      throw const AccountProblem('network_unavailable');
    } on http.ClientException {
      throw const AccountProblem('network_unavailable');
    } on FormatException {
      throw const AccountProblem('invalid_response');
    }
  }

  Future<JsonMap> _send(String path, {JsonMap? body, String? bearer}) async {
    final request = http.Request(
        body == null ? 'GET' : 'POST', Uri.parse('${config.api}/$path'))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
    final response = await _client.send(request);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 1048576) {
        throw const AccountProblem('invalid_response');
      }
      bytes.addAll(chunk);
    }
    final decoded = _object(jsonDecode(utf8.decode(bytes)));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded['error'];
      throw AccountProblem(code is String ? code : 'request_failed',
          statusCode: response.statusCode);
    }
    return decoded;
  }

  Future<void> beginLogin() async {
    final pkce =
        await rymuAndroidChannel.invokeMapMethod<String, String>('createPkce');
    if (pkce == null) throw const AccountProblem('storage_unavailable');
    final response = await _request('native/authorize/start', body: {
      'codeChallenge': pkce['challenge'],
      'state': pkce['state'],
      'redirectUri': _redirect,
      'flow': 'account',
    });
    final flow = response['flow'];
    if (flow != null && flow != 'account') {
      throw const AccountProblem('invalid_response');
    }
    await _save({
      'login': {
        'verifier': pkce['verifier'],
        'state': pkce['state'],
        'url':
            config.checkedBrowserUrl(response['authorizationUrl']).toString(),
        if (flow == 'account')
          'flow': flow
        else
          'verificationCode': _string(response, 'verificationCode'),
        'expiresAt': _number(response, 'expiresAt'),
      },
    });
  }

  Future<void> finishLogin(String callback) async {
    final login = pendingLogin;
    if (login == null) return;
    if (_number(login, 'expiresAt') <= _now) {
      throw const AccountProblem('authorization_expired');
    }
    final code = verifiedOAuthCode(callback, _string(login, 'state'));
    final response = await _request('native/token', body: {
      'code': code,
      'codeVerifier': _string(login, 'verifier'),
      'redirectUri': _redirect,
    });
    if (response['flow'] != login['flow']) {
      throw const AccountProblem('invalid_response');
    }
    await _save({
      'enrollment': {
        'token': _string(response, 'enrollmentToken'),
        'expiresAt': _number(response, 'expiresAt'),
        if (login['flow'] == 'account') 'flow': 'account',
      },
    });
  }

  Future<String> signingSeed() async {
    final seed = await rymuAndroidChannel.invokeMethod<String>('signingSeed');
    if (seed == null || !_oauthToken.hasMatch(seed)) {
      throw const AccountProblem('storage_unavailable');
    }
    return seed;
  }

  Future<void> beginEnrollment(String alias) async {
    var pending = enrollment;
    if (pending == null) throw const AccountProblem('login_required');
    if (_number(pending, 'expiresAt') <= _now) {
      throw const AccountProblem('authorization_expired');
    }
    final token = _string(pending, 'token');
    final accountFlow = pending['flow'] == 'account';
    if (accountFlow && pending['deviceId'] != null) {
      // The server may already have approved a verified proof whose response
      // was interrupted. Finishing still requires its approval and this token.
      try {
        await finishEnrollment();
        return;
      } on AccountProblem catch (error) {
        if (error.code != 'trust_pending') rethrow;
      }
    }
    final seed = await signingSeed();
    if (pending['deviceId'] == null) {
      final deviceKey = _deviceKey(seed);
      if (!_oauthToken.hasMatch(deviceKey)) {
        throw const AccountProblem('identity_unavailable');
      }
      final response =
          await _request('native/enroll/start', bearer: token, body: {
        'alias': alias,
        'platform': 'android',
        'roles': ['controller'],
        'devicePublicKey': deviceKey,
      });
      if (response['flow'] != pending['flow']) {
        throw const AccountProblem('invalid_response');
      }
      pending = {
        'token': token,
        'deviceId': _string(response, 'deviceId'),
        'proof': _string(response, 'proof'),
        'expiresAt': _number(response, 'expiresAt'),
        if (accountFlow)
          'flow': 'account'
        else ...{
          'verificationCode': _string(response, 'verificationCode'),
          'url': config.checkedBrowserUrl(response['approvalUrl']).toString(),
        },
      };
      await _save({'enrollment': pending});
    }
    if (pending['proof'] != null) {
      final signature = _signProof(seed, _string(pending, 'proof'));
      if (!_oauthToken.hasMatch(signature)) {
        throw const AccountProblem('identity_unavailable');
      }
      final verified =
          await _request('native/enroll/verify', bearer: token, body: {
        'deviceId': _string(pending, 'deviceId'),
        'signature': signature,
      });
      if (verified['ok'] != true ||
          (accountFlow && verified['approved'] != true)) {
        throw const AccountProblem('invalid_response');
      }
      await _save({
        'enrollment': {...pending}..remove('proof')
      });
    }
    if (accountFlow) await finishEnrollment();
  }

  Future<void> finishEnrollment() async {
    final pending = enrollment;
    if (pending == null) throw const AccountProblem('login_required');
    if (_number(pending, 'expiresAt') <= _now) {
      throw const AccountProblem('authorization_expired');
    }
    final response = await _request('native/enroll/finish',
        bearer: _string(pending, 'token'),
        body: {'deviceId': _string(pending, 'deviceId')});
    await _save(
        {'session': _sessionRecord(response, _string(pending, 'deviceId'))});
  }

  JsonMap _sessionRecord(JsonMap response, String deviceId) => {
        'deviceId': deviceId,
        'accessToken': _string(response, 'accessToken'),
        'refreshToken': _string(response, 'refreshToken'),
        'expiresAt': _number(response, 'expiresAt'),
        'refreshExpiresAt': _number(response, 'refreshExpiresAt'),
      };

  Future<String> accessToken({bool forceRefresh = false}) async {
    final current = session;
    if (current == null) throw const AccountProblem('login_required');
    final inFlight = _refresh;
    if (inFlight != null) return inFlight;
    if (current['refreshPending'] == true) {
      throw const AccountProblem('refresh_interrupted');
    }
    if (!forceRefresh && _number(current, 'expiresAt') > _now + 30000) {
      return _string(current, 'accessToken');
    }
    if (_number(current, 'refreshExpiresAt') <= _now) {
      throw const AccountProblem('reauthentication_required');
    }
    final refresh = _refreshTokens(current, _generation);
    _refresh = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_refresh, refresh)) _refresh = null;
    }
  }

  Future<String> _refreshTokens(JsonMap current, int generation) async {
    final token = _string(current, 'refreshToken');
    // The server revokes a device when a consumed refresh token is used again.
    // Persist the marker before sending so a lost response or process exit
    // cannot turn the next access attempt into a replay.
    await _save({
      'session': {...current, 'refreshPending': true},
    }, generation: generation);
    try {
      final response = await _request('native/refresh', body: {
        'refreshToken': token,
      });
      final next = _sessionRecord(response, _string(current, 'deviceId'));
      if (next['refreshToken'] == token) {
        throw const AccountProblem('invalid_response');
      }
      await _save({'session': next}, generation: generation);
      return _string(next, 'accessToken');
    } on AccountProblem catch (error) {
      // These rejections are guaranteed by the account service to occur
      // without consuming this token.
      if ((error.statusCode == 409 && error.code == 'account_suspended') ||
          (error.statusCode == 429 && error.code == 'rate_limited')) {
        await _save({'session': current}, generation: generation);
        rethrow;
      }
      if (error.statusCode == 401 && error.code == 'invalid_token') rethrow;
      throw const AccountProblem('refresh_interrupted');
    } on PlatformException {
      throw const AccountProblem('refresh_interrupted');
    }
  }

  Future<List<AndroidHost>> hosts() async {
    final generation = _generation;
    final response = await _request('devices', bearer: await accessToken());
    _requireGeneration(generation);
    final list = response['devices'];
    if (list is! List) throw const AccountProblem('invalid_response');
    final hosts = list
        .map(_object)
        .where((device) =>
            device['platform'] == 'windows' &&
            device['roles'] is List &&
            (device['roles'] as List).contains('host') &&
            device['state'] != 'revoked' &&
            device['state'] != 'expired')
        .map(AndroidHost.fromJson)
        .toList(growable: false);
    _managedTransport = readAccountTransport(response['transport']);
    return hosts;
  }

  Future<void> heartbeat() async {
    await _request('native/heartbeat', bearer: await accessToken(), body: {});
  }

  Future<void> signOut() async {
    try {
      if (session != null) {
        await _request('native/logout', bearer: await accessToken(), body: {});
      }
    } finally {
      await clearLocal();
    }
  }

  void dispose() {
    _disposed = true;
    _resetLocalState();
    _client.close();
  }
}
