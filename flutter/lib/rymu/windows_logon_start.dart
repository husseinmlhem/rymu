import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

import 'windows_package_identity.dart';

class WindowsLogonStart {
  static const _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'RymuAutoHost';
  static const _installerKey = r'Software\Rymu\Installer';
  static const _installerValue = 'StartWithWindows';

  static String? get _command {
    if (WindowsPackageIdentity.packaged) return null;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (!Platform.isWindows || localAppData == null) return null;
    final installed =
        path.windows.join(localAppData, 'Programs', 'Rymu', 'Rymu.exe');
    final executable = path.windows.normalize(Platform.resolvedExecutable);
    if (!path.windows.isAbsolute(executable) ||
        path.windows.normalize(installed).toLowerCase() !=
            executable.toLowerCase()) {
      return null;
    }
    final command = '"$executable"';
    return command.length <= 260 ? command : null;
  }

  static bool get supported => _command != null;

  static bool? get pendingInstallerPreference {
    if (!supported) return null;
    return using((arena) {
      final key = arena<IntPtr>();
      final opened = RegOpenKeyEx(
          HKEY_CURRENT_USER,
          _installerKey.toNativeUtf16(allocator: arena),
          0,
          REG_SAM_FLAGS.KEY_QUERY_VALUE,
          key);
      if (opened == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return null;
      if (opened != WIN32_ERROR.ERROR_SUCCESS) {
        throw StateError('Opening the installer preference failed ($opened)');
      }
      try {
        final value = arena<Uint32>();
        final type = arena<Uint32>();
        final size = arena<Uint32>()..value = sizeOf<Uint32>();
        final status = RegQueryValueEx(
            key.value,
            _installerValue.toNativeUtf16(allocator: arena),
            nullptr,
            type,
            value.cast(),
            size);
        if (status == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return null;
        if (status != WIN32_ERROR.ERROR_SUCCESS ||
            type.value != REG_VALUE_TYPE.REG_DWORD ||
            size.value != 4 ||
            value.value > 1) {
          throw StateError('Reading the installer preference failed ($status)');
        }
        return value.value == 1;
      } finally {
        RegCloseKey(key.value);
      }
    });
  }

  static void clearInstallerPreference() {
    if (!supported) return;
    using((arena) {
      final key = arena<IntPtr>();
      final opened = RegOpenKeyEx(
          HKEY_CURRENT_USER,
          _installerKey.toNativeUtf16(allocator: arena),
          0,
          REG_SAM_FLAGS.KEY_SET_VALUE,
          key);
      if (opened == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return;
      if (opened != WIN32_ERROR.ERROR_SUCCESS) {
        throw StateError('Opening the installer preference failed ($opened)');
      }
      try {
        final status = RegDeleteValue(
            key.value, _installerValue.toNativeUtf16(allocator: arena));
        if (status != WIN32_ERROR.ERROR_SUCCESS &&
            status != WIN32_ERROR.ERROR_FILE_NOT_FOUND) {
          throw StateError(
              'Clearing the installer preference failed ($status)');
        }
      } finally {
        RegCloseKey(key.value);
      }
    });
  }

  static void setEnabled(bool enabled) {
    final command = _command;
    if (command == null) {
      if (enabled) {
        throw StateError('Rymu is outside its per-user installation');
      }
      return;
    }
    using((arena) {
      final subkey = _runKey.toNativeUtf16(allocator: arena);
      final name = _valueName.toNativeUtf16(allocator: arena);
      final key = arena<IntPtr>();
      final status = enabled
          ? RegCreateKeyEx(
              HKEY_CURRENT_USER,
              subkey,
              0,
              nullptr,
              REG_OPEN_CREATE_OPTIONS.REG_OPTION_NON_VOLATILE,
              REG_SAM_FLAGS.KEY_SET_VALUE,
              nullptr,
              key,
              nullptr)
          : RegOpenKeyEx(
              HKEY_CURRENT_USER, subkey, 0, REG_SAM_FLAGS.KEY_SET_VALUE, key);
      if (!enabled && status == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return;
      if (status != WIN32_ERROR.ERROR_SUCCESS) {
        throw StateError(
            'Opening the Windows logon registry key failed ($status)');
      }
      try {
        final result = enabled
            ? RegSetValueEx(
                key.value,
                name,
                0,
                REG_VALUE_TYPE.REG_SZ,
                command.toNativeUtf16(allocator: arena).cast(),
                (command.length + 1) * sizeOf<Uint16>())
            : RegDeleteValue(key.value, name);
        if (!enabled && result == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return;
        if (result != WIN32_ERROR.ERROR_SUCCESS) {
          throw StateError(
              'Updating the Windows logon registry value failed ($result)');
        }
      } finally {
        RegCloseKey(key.value);
      }
    });
  }
}
