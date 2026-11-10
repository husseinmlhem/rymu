// Runs the production startup setter under a process-local HKCU override.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../apps/native/flutter/lib/rymu/windows_logon_start.dart';

const _run = r'Software\Microsoft\Windows\CurrentVersion\Run';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String? readString(int key, String name) => using((arena) {
      final type = arena<Uint32>();
      final size = arena<Uint32>()..value = 4096;
      final buffer = arena<Uint8>(4096);
      final result = RegQueryValueEx(key, name.toNativeUtf16(allocator: arena),
          nullptr, type, buffer, size);
      if (result == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return null;
      check(result == WIN32_ERROR.ERROR_SUCCESS, 'Registry query failed');
      check(
          type.value == REG_VALUE_TYPE.REG_SZ, 'Registry value is not REG_SZ');
      return buffer.cast<Utf16>().toDartString();
    });

String? readRun() => using((arena) {
      final handle = arena<IntPtr>();
      final result = RegOpenKeyEx(
          HKEY_CURRENT_USER,
          _run.toNativeUtf16(allocator: arena),
          0,
          REG_SAM_FLAGS.KEY_READ,
          handle);
      if (result == WIN32_ERROR.ERROR_FILE_NOT_FOUND) return null;
      check(result == WIN32_ERROR.ERROR_SUCCESS, 'Sandbox Run key open failed');
      try {
        return readString(handle.value, 'RymuAutoHost');
      } finally {
        RegCloseKey(handle.value);
      }
    });

void writeInstallerPreference(int value) => using((arena) {
      final key = arena<IntPtr>();
      check(
          RegCreateKeyEx(
                  HKEY_CURRENT_USER,
                  r'Software\Rymu\Installer'.toNativeUtf16(allocator: arena),
                  0,
                  nullptr,
                  REG_OPEN_CREATE_OPTIONS.REG_OPTION_NON_VOLATILE,
                  REG_SAM_FLAGS.KEY_SET_VALUE,
                  nullptr,
                  key,
                  nullptr) ==
              WIN32_ERROR.ERROR_SUCCESS,
          'Sandbox installer key creation failed');
      try {
        final data = arena<Uint32>()..value = value;
        check(
            RegSetValueEx(
                    key.value,
                    'StartWithWindows'.toNativeUtf16(allocator: arena),
                    0,
                    REG_VALUE_TYPE.REG_DWORD,
                    data.cast(),
                    sizeOf<Uint32>()) ==
                WIN32_ERROR.ERROR_SUCCESS,
            'Sandbox installer preference write failed');
      } finally {
        RegCloseKey(key.value);
      }
    });

void main(List<String> args) {
  check(Platform.isWindows && args.length == 2,
      'Windows sandbox arguments required');
  check(RegExp(r'^Software\\RymuStartupProbe-[a-f0-9]{32}$').hasMatch(args[0]),
      'Invalid probe key');
  check(RegExp(r'^[a-f0-9]{32}$').hasMatch(args[1]), 'Invalid probe marker');
  final checks = <String, bool>{};
  using((arena) {
    final handle = arena<IntPtr>();
    final opened = RegOpenKeyEx(
        HKEY_CURRENT_USER,
        args[0].toNativeUtf16(allocator: arena),
        0,
        REG_SAM_FLAGS.KEY_ALL_ACCESS,
        handle);
    check(opened == WIN32_ERROR.ERROR_SUCCESS, 'Probe key open failed');
    var overridden = false;
    try {
      // Match the Windows SDK's signed LONG -> ULONG_PTR predefined handle.
      final overrideStatus =
          RegOverridePredefKey(HKEY_CURRENT_USER.toSigned(32), handle.value);
      check(overrideStatus == WIN32_ERROR.ERROR_SUCCESS,
          'HKCU override failed ($overrideStatus)');
      overridden = true;
      check(readString(HKEY_CURRENT_USER, 'RymuProbeMarker') == args[1],
          'HKCU override marker mismatch; refusing production setter');
      checks['process_local_hkcu_override_verified'] = true;
      check(WindowsLogonStart.supported,
          'Production installed-path guard failed');
      checks['production_installed_path_guard'] = true;
      check(readRun() == null, 'Sandbox Run value unexpectedly exists');
      WindowsLogonStart.setEnabled(true);
      final expected = '"${Platform.resolvedExecutable}"';
      check(readRun() == expected,
          'Production Run command is not the quoted executable');
      checks['production_setter_registers_exact_quoted_executable'] = true;
      WindowsLogonStart.setEnabled(true);
      check(readRun() == expected, 'Repeated enable changed Run command');
      checks['repeated_enable_is_idempotent'] = true;
      WindowsLogonStart.setEnabled(false);
      check(readRun() == null, 'Production disable did not remove Run value');
      WindowsLogonStart.setEnabled(false);
      check(readRun() == null, 'Repeated disable recreated Run value');
      checks['production_setter_removes_value_idempotently'] = true;
      check(WindowsLogonStart.pendingInstallerPreference == null,
          'Unexpected pending installer preference');
      writeInstallerPreference(0);
      check(
          WindowsLogonStart.pendingInstallerPreference == false &&
              WindowsLogonStart.pendingInstallerPreference == false,
          'Production installer OFF read was lost or consumed');
      WindowsLogonStart.clearInstallerPreference();
      check(WindowsLogonStart.pendingInstallerPreference == null,
          'Production installer preference not cleared');
      writeInstallerPreference(1);
      check(WindowsLogonStart.pendingInstallerPreference == true,
          'Production installer ON read failed');
      WindowsLogonStart.clearInstallerPreference();
      WindowsLogonStart.clearInstallerPreference();
      check(WindowsLogonStart.pendingInstallerPreference == null,
          'Repeated clear recreated preference');
      checks['production_pending_choice_read_without_consumption'] = true;
      checks['production_pending_choice_clear_idempotent'] = true;
    } finally {
      if (overridden) {
        check(
            RegOverridePredefKey(HKEY_CURRENT_USER.toSigned(32), 0) ==
                WIN32_ERROR.ERROR_SUCCESS,
            'HKCU override restoration failed');
        checks['hkcu_override_restored'] = true;
      }
      RegCloseKey(handle.value);
    }
  });
  stdout.writeln(jsonEncode(checks));
}
