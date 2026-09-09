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

namespace {

/// Windows 11 = build 22000+. RtlGetVersion is not subject to the
/// compatibility-manifest lying that affects GetVersion()/VerifyVersionInfo.
bool IsWindows11OrGreater() {
  using RtlGetVersionPtr =
      LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  RTL_OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  auto fn = reinterpret_cast<RtlGetVersionPtr>(GetProcAddress(
      GetModuleHandle(L"ntdll.dll"), "RtlGetVersion"));
  if (fn == nullptr || fn(&info) != 0) return false;
  return info.dwBuildNumber >= 22000;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // NOTE: do NOT strip WS_CAPTION here. DWM uses the caption-style bits
  // (WS_CAPTION | WS_MINIMIZEBOX | WS_MAXIMIZEBOX) to trigger the native
  // minimize / maximize / restore / close animations and to draw the drop
  // shadow -- removing WS_CAPTION silently disables all of them. The title
  // bar is instead hidden in MessageHandler (WM_NCCALCSIZE): the caption
  // band is reclaimed as client area while the native frame stays intact
  // (the in-app SyphonTitleBar takes over window controls).
  // Keep WS_THICKFRAME (resizable), WS_MINIMIZEBOX, WS_MAXIMIZEBOX and
  // WS_SYSMENU (Alt+Space system menu).

  // Accept files dragged in from Explorer (WM_DROPFILES -> HandleFileDrop)
  DragAcceptFiles(GetHandle(), TRUE);

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
  // -- Pre-plugin window management ----------------------------------------
  // window_manager's window-proc delegate handles WM_GETMINMAXINFO and
  // WM_NCCALCSIZE and returns "handled" unconditionally, which would prevent
  // the adjustments below from ever running -- apply them first.

  if (message == WM_GETMINMAXINFO) {
    // Pin the maximized rect to the work area of the monitor the window is
    // on, so maximizing never covers the Windows taskbar. The system
    // pre-fill only accounts for the primary monitor and assumes a captioned
    // window; window_manager returns "handled" without fixing it up.
    // Applied in place; window_manager still gets the message afterwards to
    // apply the configured min/max track sizes.
    MINMAXINFO* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfo(mon, &mi)) {
      mmi->ptMaxPosition = {mi.rcWork.left, mi.rcWork.top};
      mmi->ptMaxSize = {mi.rcWork.right - mi.rcWork.left,
                        mi.rcWork.bottom - mi.rcWork.top};
    }
  }

  if (message == WM_NCCALCSIZE && wparam) {
    // Hide the native title bar without stripping WS_CAPTION (see OnCreate):
    // reclaim the caption band as client area, keeping the resize borders.
    // Mirrors window_manager's TitleBarStyle.hidden handling, but active from
    // window creation on -- no dependency on the Dart-side setup racing the
    // first presented frame.
    NCCALCSIZE_PARAMS* sz = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (IsZoomed(hwnd)) {
      // Maximized: align the client area to the work area (the maximized
      // window rect overhangs the work area by the frame size).
      if (GetMonitorInfo(mon, &mi)) {
        LONG l = sz->rgrc[0].left - mi.rcWork.left;
        LONG t = sz->rgrc[0].top - mi.rcWork.top;
        sz->rgrc[0].left -= l;
        sz->rgrc[0].top -= t;
        sz->rgrc[0].right += l;
        sz->rgrc[0].bottom += t;
      }
    } else {
      // Normal: caption band becomes client area (no drawn title bar).
      // Windows 10 leaves a 1px white line at the top when fully reclaimed.
      sz->rgrc[0].top += IsWindows11OrGreater() ? 0 : 1;
      // Reserve the resize borders on left/right/bottom (required for edge
      // resizing; same values window_manager uses).
      sz->rgrc[0].right -= 8;
      sz->rgrc[0].bottom -= 8;
      sz->rgrc[0].left -= -8;
    }
    return 0;
  }

  if (message == WM_NCHITTEST) {
    // With WS_CAPTION kept, DefWindowProc may still report HTCAPTION inside
    // the (now client) caption band -- that would swallow clicks on the
    // in-app toolbar. Remap it to the client area; the toolbar implements
    // dragging itself via window_manager.startDragging(). Resize-edge hit
    // results (HTLEFT etc.) fall through to normal handling.
    if (DefWindowProc(hwnd, message, wparam, lparam) == HTCAPTION) {
      return HTCLIENT;
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
    case WM_DROPFILES:
      HandleFileDrop(reinterpret_cast<HDROP>(wparam));
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
