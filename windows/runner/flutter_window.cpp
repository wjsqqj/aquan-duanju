#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Boss key hotkey id (unique per window) and chord: Ctrl+Shift+H.
constexpr int kBossHotKeyId = 0xA1;
constexpr UINT kBossHotKeyModifiers =
    MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT;
constexpr UINT kBossHotKeyVirtualKey = 'H';

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Boss key channel: Dart toggles it with setEnabled; a hotkey hit invokes
  // "toggle" so the Dart side can hide the window and pause playback.
  boss_key_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "aquan/boss_key",
          &flutter::StandardMethodCodec::GetInstance());
  boss_key_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setEnabled") {
          const bool* enabled = std::get_if<bool>(call.arguments());
          SetBossHotKeyEnabled(enabled != nullptr && *enabled);
          // Report the real registration result: with a failed hotkey the
          // Dart side refuses to hide the window, otherwise the user would
          // have no global way to bring it back.
          result->Success(flutter::EncodableValue(boss_key_registered_));
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (boss_key_registered_) {
    UnregisterHotKey(GetHandle(), kBossHotKeyId);
    boss_key_registered_ = false;
  }
  if (boss_key_channel_) {
    boss_key_channel_->SetMethodCallHandler(nullptr);
    boss_key_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetBossHotKeyEnabled(bool enabled) {
  if (enabled) {
    if (boss_key_registered_) {
      return;
    }
    boss_key_registered_ =
        RegisterHotKey(GetHandle(), kBossHotKeyId, kBossHotKeyModifiers,
                       kBossHotKeyVirtualKey) != FALSE;
    return;
  }
  if (boss_key_registered_) {
    UnregisterHotKey(GetHandle(), kBossHotKeyId);
    boss_key_registered_ = false;
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Boss key hit: let Dart hide/restore the window and pause/resume playback.
  // Handled before HandleTopLevelWindowProc so plugins cannot swallow it.
  if (message == WM_HOTKEY && static_cast<int>(wparam) == kBossHotKeyId) {
    if (boss_key_channel_) {
      boss_key_channel_->InvokeMethod("toggle", nullptr);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
