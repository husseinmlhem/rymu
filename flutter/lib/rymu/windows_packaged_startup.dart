import 'package:flutter/services.dart';

enum PackagedStartupState {
  disabled,
  disabledByUser,
  enabled,
  disabledByPolicy,
  enabledByPolicy;

  bool get enabledForWindows => this == enabled || this == enabledByPolicy;

  bool get managedByPolicy =>
      this == disabledByPolicy || this == enabledByPolicy;
}

/// This API is used only after detecting a packaged process. The OS permission
/// is separate from saved consent to resume hosting after the app opens.
class WindowsPackagedStartup {
  static const _channel = MethodChannel('rymu/windows_packaged_startup');

  static Future<PackagedStartupState> query() => _request('query');
  static Future<PackagedStartupState> setEnabled(bool enabled) =>
      _request(enabled ? 'enable' : 'disable');

  static Future<PackagedStartupState> _request(String method) async {
    final value = await _channel
        .invokeMethod<String>(method)
        .timeout(const Duration(seconds: 8));
    return PackagedStartupState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => throw StateError('Windows startup state is unavailable'),
    );
  }
}
