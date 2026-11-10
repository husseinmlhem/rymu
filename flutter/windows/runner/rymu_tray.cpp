#include "rymu_tray.h"

#include <flutter/standard_method_codec.h>

#include "resource.h"

namespace {
constexpr UINT kTrayCallback = WM_APP + 0x52;
constexpr UINT kTrayOpen = 0x7351;
constexpr UINT kTrayQuit = 0x7352;
}

RymuTray::RymuTray(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  icon_.cbSize = sizeof(icon_);
  icon_.hWnd = window_;
  icon_.uID = 1;
  icon_.uCallbackMessage = kTrayCallback;
  icon_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  channel_ = std::make_unique<flutter::MethodChannel<>>(
      messenger, "rymu/windows_tray", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "configure") {
          const auto* args = call.arguments()
              ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
          if (!args) {
            result->Error("invalid_arguments");
            return;
          }
          const auto ar = args->find(flutter::EncodableValue("ar"));
          arabic_ = ar != args->end() && std::get_if<bool>(&ar->second) &&
              std::get<bool>(ar->second);
          const auto status = args->find(flutter::EncodableValue("status"));
          const auto* code = status == args->end()
              ? nullptr : std::get_if<std::string>(&status->second);
          if (code && *code == "online") {
            status_ = arabic_ ? L"جاهز للاتصال" : L"Ready for connections";
          } else if (code && *code == "waiting") {
            status_ = arabic_ ? L"بانتظار الاتصال بالخدمة" : L"Waiting for connection";
          } else if (code && *code == "stopped") {
            status_ = arabic_ ? L"الاستضافة متوقفة" : L"Hosting stopped";
          } else {
            status_ = arabic_ ? L"يلزم تسجيل الدخول" : L"Sign in required";
          }
          const auto tip = std::wstring(L"Rymu — ") + status_;
          wcsncpy_s(icon_.szTip, tip.c_str(), _TRUNCATE);
          enabled_ = true;
          const bool ready = EnsureIcon();
          if (!ready && !IsWindowVisible(window_)) ShowWindow();
          result->Success(flutter::EncodableValue(ready));
        } else if (call.method_name() == "hide") {
          const bool ready = enabled_ && EnsureIcon();
          if (ready) ::ShowWindow(window_, SW_HIDE);
          else ShowWindow();
          result->Success(flutter::EncodableValue(ready));
        } else if (call.method_name() == "remove") {
          enabled_ = false;
          RemoveIcon();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

RymuTray::~RymuTray() {
  channel_->SetMethodCallHandler(nullptr);
  RemoveIcon();
}

bool RymuTray::EnsureIcon() {
  if (added_ && Shell_NotifyIconW(NIM_MODIFY, &icon_)) return true;
  added_ = Shell_NotifyIconW(NIM_ADD, &icon_) != FALSE;
  if (added_) {
    icon_.uVersion = NOTIFYICON_VERSION_4;
    if (!Shell_NotifyIconW(NIM_SETVERSION, &icon_)) {
      RemoveIcon();
    }
  }
  return added_;
}

void RymuTray::RemoveIcon() {
  if (added_) Shell_NotifyIconW(NIM_DELETE, &icon_);
  added_ = false;
}

void RymuTray::ShowWindow() {
  ::ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void RymuTray::Command(UINT command) {
  if (command == kTrayOpen) {
    ShowWindow();
  } else if (command == kTrayQuit) {
    channel_->InvokeMethod("quit", nullptr);
  }
}

void RymuTray::ShowMenu() {
  const auto menu = CreatePopupMenu();
  if (!menu) {
    ShowWindow();
    return;
  }
  AppendMenuW(menu, MF_STRING | MF_DISABLED, 0, status_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayOpen, arabic_ ? L"فتح ريمو" : L"Open Rymu");
  AppendMenuW(menu, MF_STRING, kTrayQuit,
              arabic_ ? L"خروج كامل" : L"Quit Rymu");
  SetMenuDefaultItem(menu, kTrayOpen, FALSE);
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(window_);
  const auto command = TrackPopupMenu(menu,
      TPM_RETURNCMD | TPM_RIGHTBUTTON | (arabic_ ? TPM_LAYOUTRTL : 0),
      point.x, point.y, 0, window_, nullptr);
  DestroyMenu(menu);
  PostMessageW(window_, WM_NULL, 0, 0);
  Command(command);
}

std::optional<LRESULT> RymuTray::HandleMessage(UINT message, WPARAM wparam,
                                             LPARAM lparam) {
  if (!enabled_) return std::nullopt;
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    added_ = false;
    if (!EnsureIcon()) ShowWindow();
    return 0;
  }
  if (message == kTrayCallback && HIWORD(lparam) == icon_.uID) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT) ShowWindow();
    else if (event == WM_CONTEXTMENU) ShowMenu();
    return 0;
  }
  if (message == WM_COMMAND && lparam == 0 &&
      (LOWORD(wparam) == kTrayOpen || LOWORD(wparam) == kTrayQuit)) {
    Command(LOWORD(wparam));
    return 0;
  }
  return std::nullopt;
}
