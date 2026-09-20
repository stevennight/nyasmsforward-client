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

  // Single instance: the app lives in the tray, so a second launch (Start menu, desktop shortcut) must bring the
  // running window back instead of adding a second tray icon and a second event stream. The mutex is per sign-in
  // session ("Local\"), so other users on the same PC are not affected.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\NyaSmsForward.SingleInstance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A hidden window (closed to the tray) is still found by FindWindow.
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      ::ShowWindow(existing, IsIconic(existing) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"NyaSmsForward", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
