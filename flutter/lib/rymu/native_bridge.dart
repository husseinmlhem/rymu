import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import 'account_transport.dart';

typedef _Native = ffi.IntPtr Function(
    ffi.Pointer<ffi.Uint8>, ffi.IntPtr, ffi.Pointer<ffi.Uint8>, ffi.IntPtr);
typedef _Dart = int Function(
    ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint8>, int);

/// Private Dart/Rust boundary for Rymu, independent of RustDesk's generated FFI.
class RymuNative {
  static final _call = (Platform.isAndroid
          ? ffi.DynamicLibrary.open('librustdesk.so')
          : ffi.DynamicLibrary.open('librustdesk.dll'))
      .lookupFunction<_Native, _Dart>('rymu_control');

  static dynamic _request(String op, [Map<String, Object?> data = const {}]) {
    final bytes = utf8.encode(jsonEncode({'op': op, ...data}));
    const capacity = 65536;
    if (bytes.length > capacity) {
      throw const FormatException('Request too large');
    }
    final input = calloc<ffi.Uint8>(bytes.length);
    final output = calloc<ffi.Uint8>(capacity);
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      final length = _call(input, bytes.length, output, capacity);
      if (length <= 0 || length > capacity) {
        throw const FormatException('Native Rymu request failed');
      }
      final response = jsonDecode(utf8.decode(output.asTypedList(length)))
          as Map<String, dynamic>;
      if (response['error'] case final String message) {
        throw RymuNativeException(message);
      }
      return response['value'];
    } finally {
      input.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      output.asTypedList(capacity).fillRange(0, capacity, 0);
      bytes.fillRange(0, bytes.length, 0);
      calloc.free(input);
      calloc.free(output);
    }
  }

  static void configureTransport(AccountTransport transport) =>
      _request('configureTransport', transport.toNativeOptions());

  static void clearTransport() => _request('clearTransport');

  static void stageSession({
    required String peerId,
    required String hostId,
    required String peerPublicKey,
    required String accessToken,
    required String signingSeed,
    required String apiBase,
    required AccountTransport transport,
    required bool viewOnly,
    bool files = false,
    String? controllerId,
  }) {
    _request('stageSession', {
      ...transport.toNativeOptions(),
      'peerId': peerId,
      'hostId': hostId,
      'peerPublicKey': peerPublicKey,
      'accessToken': accessToken,
      'signingSeed': signingSeed,
      'apiBase': apiBase,
      'viewOnly': viewOnly,
      'files': files,
      'controllerId': controllerId,
    });
  }

  static String devicePublicKey(String signingSeed) =>
      _request('devicePublicKey', {'signingSeed': signingSeed}) as String;

  static String signEnrollment(String signingSeed, String proof) =>
      _request('signEnrollment', {'signingSeed': signingSeed, 'proof': proof})
          as String;

  static Map<String, dynamic> identity() =>
      _request('identity') as Map<String, dynamic>;

  static String transferRoot() {
    final root = _request('transferRoot') as String;
    // Older engines can fall back to the user profile when exchange is absent.
    // A receiving-folder shortcut must not silently choose a broader folder.
    if (!path.windows.isAbsolute(root) ||
        path.windows.basename(root).toLowerCase() != 'files' ||
        path.windows.basename(path.windows.dirname(root)).toLowerCase() !=
            'rymu') {
      throw const RymuNativeException(
          'The Rymu transfer folder is unavailable');
    }
    return root;
  }

  static bool restageConnection(String peerId) =>
      _request('restageConnection', {'peerId': peerId}) == true;
  static void forgetConnection(String peerId) =>
      _request('forgetConnection', {'peerId': peerId});
  static bool hostOnline() => _request('hostOnline') == true;
  static List<dynamic> displays() => _request('displays') as List<dynamic>;
  static List<dynamic>? pairIdentity(String peerId) =>
      _request('pairIdentity', {'peerId': peerId}) as List<dynamic>?;

  static Map<String, dynamic>? readWindowsVault() =>
      _request('vaultRead') as Map<String, dynamic>?;

  static void writeWindowsVault(Map<String, dynamic> data) =>
      _request('vaultWrite', {'data': data});

  static void clearWindowsVault() => _request('vaultClear');

  static void enableHost(String hostId, String apiBase, String accessToken) =>
      _request('enableHost', {
        'hostId': hostId,
        'apiBase': apiBase,
        'accessToken': accessToken,
      });

  static void updateHostBearer(
          String hostId, String apiBase, String accessToken) =>
      _request('updateHostBearer', {
        'hostId': hostId,
        'apiBase': apiBase,
        'accessToken': accessToken,
      });

  static void disableHost() => _request('disableHost');
}

class RymuNativeException implements Exception {
  final String message;
  const RymuNativeException(this.message);

  @override
  String toString() => message;
}
