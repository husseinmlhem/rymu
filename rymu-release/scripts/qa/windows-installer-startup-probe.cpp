#include <windows.h>

#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

#include "../../apps/native/flutter/windows/runner/rymu_installer_startup.h"

namespace {
constexpr auto kRun = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr auto kChoice = L"Software\\Rymu\\Installer";

void Check(bool passed, const char* message) {
  if (!passed) throw std::runtime_error(message);
}

std::optional<std::wstring> ReadRun() {
  wchar_t value[32768]{};
  DWORD bytes = sizeof(value);
  const auto status = RegGetValueW(HKEY_CURRENT_USER, kRun, L"RymuAutoHost",
      RRF_RT_REG_SZ, nullptr, value, &bytes);
  if (status == ERROR_FILE_NOT_FOUND) return std::nullopt;
  Check(status == ERROR_SUCCESS, "Sandbox Run read failed");
  return std::wstring(value);
}

DWORD ReadChoice() {
  DWORD value = 9;
  DWORD bytes = sizeof(value);
  Check(RegGetValueW(HKEY_CURRENT_USER, kChoice, L"StartWithWindows",
      RRF_RT_REG_DWORD, nullptr, &value, &bytes) == ERROR_SUCCESS,
      "Sandbox installer preference read failed");
  return value;
}
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 3 || std::wstring(argv[1]).find(L"Software\\RymuStartupProbe-") != 0) {
    return ERROR_INVALID_PARAMETER;
  }
  HKEY sandbox = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, argv[1], 0, KEY_ALL_ACCESS, &sandbox) != ERROR_SUCCESS) {
    return ERROR_ACCESS_DENIED;
  }
  if (RegOverridePredefKey(HKEY_CURRENT_USER, sandbox) != ERROR_SUCCESS) {
    RegCloseKey(sandbox);
    return ERROR_ACCESS_DENIED;
  }
  int exit_code = 0;
  try {
    wchar_t marker[80]{};
    DWORD bytes = sizeof(marker);
    Check(RegGetValueW(HKEY_CURRENT_USER, nullptr, L"RymuProbeMarker", RRF_RT_REG_SZ,
        nullptr, marker, &bytes) == ERROR_SUCCESS && std::wstring(marker) == argv[2],
        "HKCU override marker mismatch; refusing helper");
    Check(!RymuInstallerStartup({}).has_value(), "Normal app launch intercepted");
    Check(RymuInstallerStartup({"--rymu-installer-startup"}) == ERROR_INVALID_PARAMETER,
        "Missing choice accepted");
    Check(RymuInstallerStartup({"--rymu-installer-startup", "bad"}) == ERROR_INVALID_PARAMETER,
        "Invalid choice accepted");
    Check(RymuInstallerStartup({"--rymu-installer-startup", "on", "extra"}) == ERROR_INVALID_PARAMETER,
        "Extra argument accepted");
    Check(!ReadRun().has_value(), "Unexpected Run command before helper");
    Check(RymuInstallerStartup({"--rymu-installer-startup", "on"}) == ERROR_SUCCESS,
        "Helper enable failed");
    wchar_t executable[32768]{};
    Check(GetModuleFileNameW(nullptr, executable, 32768) > 0, "Executable path unavailable");
    Check(ReadRun() == std::wstring(L"\"") + executable + L"\"", "Wrong Run command");
    Check(ReadChoice() == 1, "ON preference missing");
    Check(RymuInstallerStartup({"--rymu-installer-startup", "off"}) == ERROR_SUCCESS,
        "Helper disable failed");
    Check(!ReadRun().has_value() && ReadChoice() == 0, "OFF preference not applied");
    Check(RymuInstallerStartup({"--rymu-installer-startup", "off"}) == ERROR_SUCCESS,
        "Repeated disable failed");
    wchar_t profile[32768]{};
    Check(GetEnvironmentVariableW(L"LOCALAPPDATA", profile, 32768) > 0, "Profile missing");
    Check(SetEnvironmentVariableW(L"LOCALAPPDATA", L"C:\\RymuForeignProbe") != FALSE,
        "Could not set process-local path fixture");
    const auto refused = RymuInstallerStartup({"--rymu-installer-startup", "on"});
    SetEnvironmentVariableW(L"LOCALAPPDATA", profile);
    Check(refused == ERROR_ACCESS_DENIED, "Foreign executable accepted");
    Check(!ReadRun().has_value() && ReadChoice() == 0, "Refused helper changed registry");
    std::cout << "{\"exact_argument_gate\":true,\"installed_path_guard\":true,"
                 "\"quoted_run_command_on\":true,\"pending_choice_on\":true,"
                 "\"run_removed_and_pending_off\":true,\"disable_idempotent\":true,"
                 "\"foreign_path_refused_without_mutation\":true}" << std::endl;
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    exit_code = 1;
  }
  if (RegOverridePredefKey(HKEY_CURRENT_USER, nullptr) != ERROR_SUCCESS) exit_code = 2;
  RegCloseKey(sandbox);
  return exit_code;
}
