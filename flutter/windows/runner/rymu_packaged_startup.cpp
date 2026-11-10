#include "rymu_packaged_startup.h"

#include <windows.h>
#include <appmodel.h>
#include <roapi.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>
#include <flutter/standard_method_codec.h>
#include <atomic>
#include <string>

using winrt::Windows::ApplicationModel::StartupTask;
using winrt::Windows::ApplicationModel::StartupTaskState;
using StartupResult = flutter::MethodResult<flutter::EncodableValue>;

namespace {
constexpr wchar_t kTaskId[] = L"RymuStartup";

std::string StateName(StartupTaskState state) {
  switch (state) {
    case StartupTaskState::Disabled: return "disabled";
    case StartupTaskState::DisabledByUser: return "disabledByUser";
    case StartupTaskState::Enabled: return "enabled";
    case StartupTaskState::DisabledByPolicy: return "disabledByPolicy";
    case StartupTaskState::EnabledByPolicy: return "enabledByPolicy";
    default: return "unavailable";
  }
}
}

struct RymuPackagedStartup::State {
  std::atomic<bool> active{true};
  bool busy = false;
  LONG identity = APPMODEL_ERROR_NO_PACKAGE;
  HRESULT initialized = E_FAIL;

  // C++/WinRT resumes the coroutine on its originating STA. No blocking .get()
  // is used on Flutter's platform thread, and replies cannot outlive its engine.
  static winrt::fire_and_forget Request(std::shared_ptr<State> state,
      std::string method, std::unique_ptr<StartupResult> result) {
    try {
      auto task = co_await StartupTask::GetAsync(kTaskId);
      if (!state->active.load()) co_return;
      auto current = task.State();
      if (method == "enable" && current == StartupTaskState::Disabled) {
        current = co_await task.RequestEnableAsync();
      } else if (method == "disable" && current == StartupTaskState::Enabled) {
        task.Disable();
        current = task.State();
      }
      // DisabledByUser and either policy state are authoritative. Only the
      // user/administrator can change them in Windows settings.
      if (state->active.load()) {
        state->busy = false;
        result->Success(flutter::EncodableValue(StateName(current)));
      }
    } catch (...) {
      if (state->active.load()) {
        state->busy = false;
        result->Error("startup_unavailable", "Windows startup is unavailable.");
      }
    }
  }
};

RymuPackagedStartup::RymuPackagedStartup(flutter::BinaryMessenger* messenger)
    : state_(std::make_shared<State>()) {
  UINT32 length = 0;
  state_->identity = GetCurrentPackageFullName(&length, nullptr);
  if (state_->identity == ERROR_INSUFFICIENT_BUFFER) {
    state_->initialized = RoInitialize(RO_INIT_SINGLETHREADED);
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "rymu/windows_packaged_startup",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([state = state_](const auto& call, auto result) {
    const auto method = call.method_name();
    if (method != "query" && method != "enable" && method != "disable") {
      result->NotImplemented();
      return;
    }
    if (state->identity == APPMODEL_ERROR_NO_PACKAGE) {
      result->Success(flutter::EncodableValue("unpackaged"));
      return;
    }
    if (state->identity != ERROR_INSUFFICIENT_BUFFER || FAILED(state->initialized)) {
      result->Error("startup_unavailable", "Windows package identity is unavailable.");
      return;
    }
    if (state->busy) {
      result->Error("startup_busy", "A Windows startup request is still in progress.");
      return;
    }
    state->busy = true;
    State::Request(state, method, std::move(result));
  });
}

RymuPackagedStartup::~RymuPackagedStartup() {
  state_->active.store(false);
  channel_->SetMethodCallHandler(nullptr);
  if (SUCCEEDED(state_->initialized)) RoUninitialize();
}
