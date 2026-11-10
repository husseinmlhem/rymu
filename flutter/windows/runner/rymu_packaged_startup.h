#ifndef RUNNER_RYMU_PACKAGED_STARTUP_H_
#define RUNNER_RYMU_PACKAGED_STARTUP_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

class RymuPackagedStartup {
 public:
  explicit RymuPackagedStartup(flutter::BinaryMessenger* messenger);
  ~RymuPackagedStartup();
  RymuPackagedStartup(const RymuPackagedStartup&) = delete;
  RymuPackagedStartup& operator=(const RymuPackagedStartup&) = delete;

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
