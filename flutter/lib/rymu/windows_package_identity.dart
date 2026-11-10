import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Package identity is stable for the lifetime of a Windows process.
class WindowsPackageIdentity {
  static final bool packaged = _detect();

  static bool _detect() {
    if (!Platform.isWindows) return false;
    return using((arena) {
      final length = arena<Uint32>();
      final status = GetCurrentPackageFullName(length, nullptr);
      if (status == 15700) return false; // APPMODEL_ERROR_NO_PACKAGE
      if (status == WIN32_ERROR.ERROR_INSUFFICIENT_BUFFER) return true;
      // Fail closed: an unknown identity must never fall back to Run-key writes.
      throw StateError('Reading Windows package identity failed ($status)');
    });
  }
}
