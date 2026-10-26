#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 资源目录按 exe 位置绝对定位（模板的相对 L"data" 依赖启动时工作
  // 目录，换启动器就会找不到资产 → 白窗）。
  wchar_t exe_path[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  std::wstring exe_dir(exe_path);
  size_t last_sep = exe_dir.find_last_of(L"\\\\/");
  std::wstring data_dir = last_sep == std::wstring::npos
                              ? std::wstring(L"data")
                              : exe_dir.substr(0, last_sep + 1) + L"data";
  flutter::DartProject project(data_dir);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // 训练器独立窗口（第二实例）：主窗口保持可用于校对，训练页单独一窗。
  // 同一 exe 以 "training-window" 参数再启动一份即可；窗口标题区分用途。
  bool training_window = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "training-window" || arg == "--training-window") {
      training_window = true;
      break;
    }
  }

  // 训练窗口全局单例：已有训练窗口时不再新开，把旧窗口带到前台即可
  //（命名互斥体随进程退出自动释放，不会残留）。
  if (training_window) {
    HANDLE singleton = CreateMutexW(nullptr, TRUE, L"Local\\ZiJiTrainingWindow");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND existing = FindWindowW(nullptr, L"字迹 · 模型训练");
      if (existing != nullptr) {
        ShowWindow(existing, SW_RESTORE);
        SetForegroundWindow(existing);
      }
      ReleaseMutex(singleton);
      CloseHandle(singleton);
      return EXIT_SUCCESS;
    }
    // 故意不关句柄：持有到进程退出，互斥体才代表"训练窗口在运行"。
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(training_window ? L"字迹 · 模型训练" : L"字迹",
                     origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  // 不依赖启动器给的显示状态（ShellExecute 会给 SW_SHOWNORMAL，而
  // CreateProcess 系启动器可能带 SW_HIDE），窗口自己确保可见。
  window.EnsureVisible();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
