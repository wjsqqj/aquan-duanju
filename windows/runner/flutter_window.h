#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Boss key: global hotkey Ctrl+Shift+H toggles window visibility from Dart.
  // Dart enables it through the "aquan/boss_key" channel; a failed
  // registration must never break startup.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      boss_key_channel_;
  bool boss_key_registered_ = false;
  // Keep the source ASCII-only: MSVC treats C4819 (non-codepage-936
  // characters) as an error on this project.
  void SetBossHotKeyEnabled(bool enabled);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
