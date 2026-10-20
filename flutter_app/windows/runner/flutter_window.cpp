#include "flutter_window.h"

#include <imm.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

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
  ime_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ocr/ime_virtual_key",
      &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setImeEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = std::get_if<bool>(call.arguments());
        if (!enabled || !flutter_controller_) {
          result->Error("bad_args", "setImeEnabled expects a bool");
          return;
        }
        // 关闭 = 解除输入法关联：字母键不再进入拼音缓冲。开启 = 恢复默认关联。
        // 顶层窗口与承载 Flutter 内容的子窗口都设置，覆盖键盘焦点所在的那个。
        const UINT flags = *enabled ? IACE_DEFAULT : 0;
        ImmAssociateContextEx(GetHandle(), nullptr, flags);
        ImmAssociateContextEx(flutter_controller_->view()->GetNativeWindow(),
                              nullptr, flags);
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 中文输入法（微软拼音、搜狗等）在中文模式下接管字母键时，按下消息的虚拟
  // 键码会变成 VK_PROCESSKEY，Flutter 据此丢弃该按键，页面快捷键收不到。这里
  // 用 ImmGetVirtualKey 取回真实键码转给 Dart。消息不消费，输入法照常工作。
  if ((message == WM_KEYDOWN || message == WM_SYSKEYDOWN) &&
      wparam == VK_PROCESSKEY && ime_channel_) {
    UINT vk = ImmGetVirtualKey(hwnd);
    if (vk != 0 && vk != VK_PROCESSKEY) {
      ime_channel_->InvokeMethod(
          "virtualKey",
          std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(vk)));
    }
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
