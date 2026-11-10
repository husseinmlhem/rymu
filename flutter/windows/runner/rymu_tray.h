#ifndef RUNNER_RYMU_TRAY_H_
#define RUNNER_RYMU_TRAY_H_

#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <optional>
#include <string>

class RymuTray {
 public:
  RymuTray(HWND window, flutter::BinaryMessenger* messenger);
  ~RymuTray();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  bool EnsureIcon();
  void RemoveIcon();
  void ShowWindow();
  void ShowMenu();
  void Command(UINT command);

  HWND window_;
  UINT taskbar_created_;
  NOTIFYICONDATAW icon_{};
  bool enabled_ = false;
  bool added_ = false;
  bool arabic_ = false;
  std::wstring status_;
  std::unique_ptr<flutter::MethodChannel<>> channel_;
};

#endif
