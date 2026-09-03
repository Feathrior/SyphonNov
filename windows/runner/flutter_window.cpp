#include "flutter_window.h"

#include <optional>

#include <shellapi.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Frameless window: hide the native title bar (the in-app SyphonTitleBar
  // takes over window controls). window_manager 0.4.x TitleBarStyle.hidden
  // only extends the DWM frame on Windows and does NOT remove WS_CAPTION, so
  // we remove the caption style at the native layer.
  // Keep WS_THICKFRAME (resizable), WS_MINIMIZEBOX, WS_MAXIMIZEBOX and
  // WS_SYSMENU (Alt+Space system menu).
  HWND hwnd = GetHandle();
  LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~(WS_CAPTION);
  SetWindowLongPtr(hwnd, GWL_STYLE, style);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                   SWP_FRAMECHANGED);

  // Accept files dragged in from Explorer (WM_DROPFILES -> HandleFileDrop)
  DragAcceptFiles(hwnd, TRUE);

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
    case WM_DROPFILES:
      HandleFileDrop(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_GETMINMAXINFO:
      // Frameless window: when maximized, snap to the working area (exclude
      // the Windows taskbar). After WS_CAPTION is removed the system may
      // report full-screen max size, so clamp position/size to the work
      // area of the current monitor (also fixes Win+Up / snap-to-top).
      {
        MINMAXINFO* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
        HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi;
        mi.cbSize = sizeof(mi);
        if (GetMonitorInfo(mon, &mi)) {
          LONG w = mi.rcWork.right - mi.rcWork.left;
          LONG h = mi.rcWork.bottom - mi.rcWork.top;
          mmi->ptMaxPosition = {mi.rcWork.left, mi.rcWork.top};
          mmi->ptMaxSize = {w, h};
          mmi->ptMaxTrackSize = {w, h};
        }
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

/// std::wstring -> UTF-8 (for path transport over the platform channel)
std::string FlutterWindow::Utf8FromWide(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

void FlutterWindow::HandleFileDrop(HDROP hDrop) {
  // Read every dropped file path (UTF-8, sent to Dart)
  const UINT fileCount = DragQueryFile(hDrop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList paths;
  for (UINT i = 0; i < fileCount; i++) {
    const UINT len = DragQueryFile(hDrop, i, nullptr, 0);
    if (len == 0) continue;
    std::wstring buf(len, L'\0');
    DragQueryFile(hDrop, i, buf.data(), len + 1);
    paths.emplace_back(flutter::EncodableValue(Utf8FromWide(buf)));
  }
  // Drop point: DragQueryPoint returns screen coordinates; convert to client
  // coordinates before handing them to Dart
  POINT pt{};
  DragQueryPoint(hDrop, &pt);
  ScreenToClient(GetHandle(), &pt);
  DragFinish(hDrop);

  if (paths.empty() || !flutter_controller_) return;

  flutter::EncodableMap args;
  args[flutter::EncodableValue("paths")] =
      flutter::EncodableValue(std::move(paths));
  args[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<double>(pt.x));
  args[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<double>(pt.y));
  flutter::MethodChannel<flutter::EncodableValue> channel(
      flutter_controller_->engine()->messenger(), "syphon/file_drop",
      &flutter::StandardMethodCodec::GetInstance());
  channel.InvokeMethod(
      "drop", std::make_unique<flutter::EncodableValue>(std::move(args)));
}
