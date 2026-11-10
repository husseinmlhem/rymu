#include "rymu_installer_startup.h"

#include <windows.h>
#include <appmodel.h>

#include <algorithm>

std::optional<int> RymuInstallerStartup(const std::vector<std::string>& arguments) {
  constexpr auto flag = "--rymu-installer-startup";
  if (std::find(arguments.begin(), arguments.end(), flag) == arguments.end()) {
    return std::nullopt;
  }
  if (arguments.size() != 2 || arguments[0] != flag ||
      (arguments[1] != "on" && arguments[1] != "off")) {
    return ERROR_INVALID_PARAMETER;
  }
  const bool enabled = arguments[1] == "on";
  UINT32 package_name_length = 0;
  if (GetCurrentPackageFullName(&package_name_length, nullptr) !=
      APPMODEL_ERROR_NO_PACKAGE) {
    return ERROR_ACCESS_DENIED;
  }
  wchar_t executable[32768]{};
  const auto executable_size = GetModuleFileNameW(nullptr, executable, 32768);
  wchar_t local_app_data[32768]{};
  const auto profile_size = GetEnvironmentVariableW(L"LOCALAPPDATA", local_app_data, 32768);
  if (executable_size == 0 || executable_size >= 32768 ||
      profile_size == 0 || profile_size >= 32768) {
    return ERROR_BAD_PATHNAME;
  }
  const auto installed = std::wstring(local_app_data) + L"\\Programs\\Rymu\\Rymu.exe";
  wchar_t expected[32768]{};
  const auto expected_size = GetFullPathNameW(installed.c_str(), 32768, expected, nullptr);
  if (expected_size == 0 || expected_size >= 32768 ||
      _wcsicmp(executable, expected) != 0) {
    return ERROR_ACCESS_DENIED;
  }
  const auto command = std::wstring(L"\"") + executable + L"\"";
  if (command.size() > 260) return ERROR_FILENAME_EXCED_RANGE;

  HKEY run = nullptr;
  auto status = RegCreateKeyExW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &run, nullptr);
  if (status != ERROR_SUCCESS) return status;
  HKEY choice = nullptr;
  status = RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Rymu\\Installer", 0,
      nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &choice, nullptr);
  if (status != ERROR_SUCCESS) {
    RegCloseKey(run);
    return status;
  }
  DWORD old_type = 0;
  DWORD old_size = 0;
  status = RegQueryValueExW(run, L"RymuAutoHost", nullptr, &old_type, nullptr, &old_size);
  const bool had_value = status == ERROR_SUCCESS;
  if ((status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) || old_size > 65536) {
    RegCloseKey(choice);
    RegCloseKey(run);
    return old_size > 65536 ? ERROR_INVALID_DATA : status;
  }
  std::vector<BYTE> old_value(old_size);
  if (had_value && old_size != 0) {
    status = RegQueryValueExW(run, L"RymuAutoHost", nullptr, &old_type,
        old_value.data(), &old_size);
    if (status != ERROR_SUCCESS) {
      RegCloseKey(choice);
      RegCloseKey(run);
      return status;
    }
  }
  status = enabled
      ? RegSetValueExW(run, L"RymuAutoHost", 0, REG_SZ,
            reinterpret_cast<const BYTE*>(command.c_str()),
            static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)))
      : RegDeleteValueW(run, L"RymuAutoHost");
  if (!enabled && status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  if (status == ERROR_SUCCESS) {
    const DWORD value = enabled ? 1 : 0;
    status = RegSetValueExW(choice, L"StartWithWindows", 0, REG_DWORD,
        reinterpret_cast<const BYTE*>(&value), sizeof(value));
    if (status != ERROR_SUCCESS) {
      const auto restored = had_value
          ? RegSetValueExW(run, L"RymuAutoHost", 0, old_type,
                old_value.data(), old_size)
          : RegDeleteValueW(run, L"RymuAutoHost");
      if (restored != ERROR_SUCCESS && restored != ERROR_FILE_NOT_FOUND) {
        status = restored;
      }
    }
  }
  RegCloseKey(choice);
  RegCloseKey(run);
  return status;
}
