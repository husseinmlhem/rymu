import 'package:flutter/services.dart';

class WindowsTray {
  static const _channel = MethodChannel('rymu/windows_tray');

  static void onQuit(Future<void> Function()? callback) {
    _channel.setMethodCallHandler(callback == null
        ? null
        : (call) async {
            if (call.method == 'quit') await callback();
          });
  }

  static Future<bool> configure(
      {required bool ar, required String status}) async {
    try {
      return await _channel
              .invokeMethod<bool>('configure', {'ar': ar, 'status': status}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> hide() async {
    try {
      return await _channel.invokeMethod<bool>('hide') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> remove() async {
    try {
      await _channel.invokeMethod<void>('remove');
    } on PlatformException {
      // Closing the runner also removes its icon.
    } on MissingPluginException {
      // Older runners have no tray to remove.
    }
  }
}
