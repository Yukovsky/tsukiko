#include "panel_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

/// Значок приложения для окон, которые заводятся не через Win32Window.
/// Без него Windows рисует в заголовке и в Alt+Tab пустой лист бумаги.
HICON AppIcon() {
  return LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
}

}  // namespace

namespace {

constexpr wchar_t kClassName[] = L"TsukikoPanelWindow";
constexpr int kWidth = 340;

constexpr wchar_t kHudClassName[] = L"TsukikoHudWindow";
// Те же размеры, что у панели на macOS.
constexpr int kHudWidth = 372;
constexpr int kHudHeight = 52;

constexpr wchar_t kSettingsClassName[] = L"TsukikoSettingsWindow";
// Базовый логический размер окна настроек для масштабирования под системный DPI.
// В него свободно помещаются все 5 вкладок без обрезания.
constexpr int kSettingsBaseWidth = 680;
constexpr int kSettingsBaseHeight = 620;

}  // namespace

PanelWindow::PanelWindow() = default;

PanelWindow::~PanelWindow() {
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

flutter::BinaryMessenger* PanelWindow::Create(
    const flutter::DartProject& base) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = PanelWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);

  // WS_EX_TOOLWINDOW убирает кнопку с панели задач: это поповер, а не
  // ещё одно окно приложения. WS_EX_TOPMOST держит его поверх чужих.
  window_ = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kClassName, L"tsukiko",
      WS_POPUP, 0, 0, kWidth, height_, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (!window_) return nullptr;

  // Свой движок со своей точкой входа: диктовка живёт отдельно от очереди
  // и работает, даже когда главное окно спрятано.
  flutter::DartProject project = base;
  project.set_dart_entrypoint("panelMain");
  controller_ = std::make_unique<flutter::FlutterViewController>(
      kWidth, height_, project);
  if (!controller_->engine() || !controller_->view()) {
    controller_ = nullptr;
    return nullptr;
  }
  // Плагины ставятся на каждый движок отдельно: регистратор принадлежит
  // движку, а не процессу. Без этого file_selector и desktop_drop живут
  // только в главном окне, а в остальных любой их вызов кончается
  // MissingPluginException — так и не работала кнопка «выбрать другую
  // папку» в настройках.
  RegisterPlugins(controller_->engine());
  // Как это делает Win32Window для главного окна: вид движка становится
  // содержимым окна и растягивается на всю его клиентскую часть.
  HWND view = controller_->view()->GetNativeWindow();
  SetParent(view, window_);
  MoveWindow(view, 0, 0, kWidth, height_, TRUE);
  ShowWindow(view, SW_SHOW);
  return controller_->engine()->messenger();
}

LRESULT CALLBACK PanelWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<PanelWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));

  if (self) {
    // Щёлкнули мимо — панель уходит. Так ведёт себя всякий поповер,
    // и так же она ведёт себя на macOS.
    if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
      self->Hide();
      return 0;
    }
    if (message == WM_CLOSE) {
      self->Hide();
      return 0;
    }
    if (self->controller_) {
      std::optional<LRESULT> result =
          self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
      if (result) return *result;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

/// У значка в области уведомлений, а не посреди экрана: панель принадлежит
/// значку, и появляться она должна там, куда только что щёлкнули.
void PanelWindow::PositionNearTray() {
  POINT pt;
  GetCursorPos(&pt);
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);

  int x = pt.x - kWidth / 2;
  if (x < work.left) x = work.left;
  if (x + kWidth > work.right) x = work.right - kWidth;
  // Значок обычно внизу справа, и панель встаёт над ним; если полоса
  // задач сверху — под ним.
  int y = (pt.y > (work.top + work.bottom) / 2) ? work.bottom - height_
                                                : work.top;
  SetWindowPos(window_, HWND_TOPMOST, x, y, kWidth, height_, SWP_NOACTIVATE);
}

void PanelWindow::Show() {
  if (!window_ || IsVisible()) return;
  PositionNearTray();
  ShowWindow(window_, SW_SHOWNOACTIVATE);
  SetForegroundWindow(window_);
  if (on_visibility_changed) on_visibility_changed(true);
}

void PanelWindow::Hide() {
  if (!window_ || !IsVisible()) return;
  ShowWindow(window_, SW_HIDE);
  if (on_visibility_changed) on_visibility_changed(false);
}

void PanelWindow::Toggle() {
  IsVisible() ? Hide() : Show();
}

bool PanelWindow::IsVisible() const {
  return window_ && IsWindowVisible(window_);
}

void PanelWindow::SetContentHeight(int height) {
  if (height <= 0 || height == height_) return;
  height_ = height;
  if (controller_ && controller_->view()) {
    MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, kWidth, height_,
               TRUE);
  }
  SetWindowPos(window_, nullptr, 0, 0, kWidth, height_,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (IsVisible()) PositionNearTray();
}


// ── окно настроек ───────────────────────────────────────────────────────────

SettingsWindow::~SettingsWindow() {
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

void SettingsWindow::Show(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  if (window_) {
    ShowWindow(window_, SW_RESTORE);
    SetForegroundWindow(window_);
    return;
  }

  WNDCLASSW wc = {};
  wc.lpfnWndProc = SettingsWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kSettingsClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hIcon = AppIcon();
  RegisterClassW(&wc);

  // Масштабируем базовый размер под реальный DPI монитора: на 125%-175% экранах
  // окно больше не сжимается в маленький нечитаемый квадрат.
  POINT pt = {0, 0};
  HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO mi = {sizeof(mi)};
  GetMonitorInfoW(monitor, &mi);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale = (dpi > 0) ? (dpi / 96.0) : 1.0;

  int client_width = static_cast<int>(kSettingsBaseWidth * scale);
  int client_height = static_cast<int>(kSettingsBaseHeight * scale);

  RECT rect = {0, 0, client_width, client_height};
  AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
  int win_width = rect.right - rect.left;
  int win_height = rect.bottom - rect.top;

  int x = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - win_width) / 2;
  int y = mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - win_height) / 2;

  // WS_OVERLAPPEDWINDOW даёт возможность свободно растягивать окно и разворачивать его на весь экран.
  window_ = CreateWindowExW(
      0, kSettingsClassName, L"Настройки",
      WS_OVERLAPPEDWINDOW, x, y, win_width, win_height,
      nullptr, nullptr, GetModuleHandle(nullptr), this);
  if (!window_) return;

  flutter::DartProject project = base;
  project.set_dart_entrypoint("settingsMain");
  controller_ = std::make_unique<flutter::FlutterViewController>(
      client_width, client_height, project);
  if (!controller_->engine() || !controller_->view()) {
    controller_ = nullptr;
    DestroyWindow(window_);
    window_ = nullptr;
    return;
  }
  RegisterPlugins(controller_->engine());
  HWND view = controller_->view()->GetNativeWindow();
  SetParent(view, window_);
  MoveWindow(view, 0, 0, client_width, client_height, TRUE);
  ShowWindow(view, SW_SHOW);
  on_ready(controller_->engine()->messenger());

  ShowWindow(window_, SW_SHOW);
  SetForegroundWindow(window_);
}

LRESULT CALLBACK SettingsWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                         LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<SettingsWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) {
    // Закрытие прячет окно, а движок остаётся жить: он держит около ста
    // мегабайт, зато повторное открытие мгновенное — то же решение,
    // что и на macOS.
    if (message == WM_CLOSE) {
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    }
    // Растягивание окна и реакция на изменение размеров / разворачивание
    if (message == WM_SIZE) {
      if (self->controller_ && self->controller_->view()) {
        HWND view = self->controller_->view()->GetNativeWindow();
        RECT client_rect;
        GetClientRect(hwnd, &client_rect);
        MoveWindow(view, 0, 0, client_rect.right - client_rect.left,
                   client_rect.bottom - client_rect.top, TRUE);
      }
      return 0;
    }
    if (message == WM_DPICHANGED) {
      auto* new_rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, new_rect->left, new_rect->top,
                   new_rect->right - new_rect->left,
                   new_rect->bottom - new_rect->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    if (message == WM_GETMINMAXINFO) {
      auto* minmax = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = GetDpiForWindow(hwnd);
      double scale = (dpi > 0) ? (dpi / 96.0) : 1.0;
      minmax->ptMinTrackSize.x = static_cast<LONG>(520 * scale);
      minmax->ptMinTrackSize.y = static_cast<LONG>(460 * scale);
      return 0;
    }
    // Клавиатура достаётся виду Flutter, а не пустой рамке вокруг него:
    // иначе в полях настроек нельзя набрать ни буквы. Фокус отдаём только при
    // активации окна, чтобы не отбирать его у модальных диалогов (например,
    // выбора папки) при деактивации (WA_INACTIVE).
    if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE &&
        self->controller_ && self->controller_->view()) {
      SetFocus(self->controller_->view()->GetNativeWindow());
    }
    if (self->controller_) {
      std::optional<LRESULT> result =
          self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                     lparam);
      if (result) return *result;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}


// ── плавающая панель записи ─────────────────────────────────────────────────

HudWindow::~HudWindow() {
  if (guides_) DestroyWindow(guides_);
  controller_ = nullptr;
  if (window_) DestroyWindow(window_);
}

void HudWindow::Show(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  wanted_visible_ = true;
  Prepare(base, on_ready);
  if (first_frame_ready_) ShowReady();
}

namespace {
constexpr wchar_t kHudPrefs[] = L"Software\\Tsukiko\\HUD";
LRESULT CALLBACK GuidesProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_PAINT) {
    PAINTSTRUCT paint; HDC dc = BeginPaint(hwnd, &paint);
    RECT bounds; GetClientRect(hwnd, &bounds);
    HBRUSH tint = CreateSolidBrush(RGB(65, 130, 230));
    FillRect(dc, &bounds, tint); DeleteObject(tint);
    HPEN line = CreatePen(PS_SOLID, 2, RGB(210, 230, 255));
    auto old = SelectObject(dc, line);
    MoveToEx(dc, bounds.right / 2, 0, nullptr); LineTo(dc, bounds.right / 2, bounds.bottom);
    MoveToEx(dc, 0, bounds.bottom / 2, nullptr); LineTo(dc, bounds.right, bounds.bottom / 2);
    SelectObject(dc, old); DeleteObject(line); EndPaint(hwnd, &paint); return 0;
  }
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  return DefWindowProc(hwnd, message, wp, lp);
}
}

HudWindow::HudWindow(bool editor) : is_editor_(editor) {
  if (is_editor_) return;
  auto read = [](const wchar_t* name, DWORD fallback) {
    DWORD value = fallback, bytes = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, kHudPrefs, name, RRF_RT_REG_DWORD,
                     nullptr, &value, &bytes) != ERROR_SUCCESS) return fallback;
    return value;
  };
  placement_.scale = HudPlacement::ValidScale(read(L"scale", 1000) / 1000.0);
  placement_.positioned = read(L"positioned", 0) != 0;
  placement_.x = std::clamp(read(L"x", 500000) / 1000000.0, 0.0, 1.0);
  placement_.y = std::clamp(read(L"y", 500000) / 1000000.0, 0.0, 1.0);
}

void HudWindow::SavePlacement() {
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kHudPrefs, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  auto write = [&](const wchar_t* name, DWORD value) {
    RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
  };
  write(L"scale", static_cast<DWORD>(placement_.scale * 1000));
  write(L"positioned", placement_.positioned ? 1 : 0);
  write(L"x", static_cast<DWORD>(placement_.x * 1000000));
  write(L"y", static_cast<DWORD>(placement_.y * 1000000));
  RegCloseKey(key);
}

double HudWindow::DpiScale() const {
  return window_ ? GetDpiForWindow(window_) / 96.0 : 1.0;
}

HudArea HudWindow::WorkArea() const {
  MONITORINFO info = {}; info.cbSize = sizeof(info);
  if (monitor_ && GetMonitorInfoW(monitor_, &info)) {
    auto r = info.rcWork;
    return {static_cast<double>(r.left), static_cast<double>(r.top),
            static_cast<double>(r.right - r.left), static_cast<double>(r.bottom - r.top)};
  }
  RECT r; SystemParametersInfoW(SPI_GETWORKAREA, 0, &r, 0);
  return {static_cast<double>(r.left), static_cast<double>(r.top),
          static_cast<double>(r.right - r.left), static_cast<double>(r.bottom - r.top)};
}

void HudWindow::CaptureCenter() {
  double factor = DpiScale() * placement_.scale;
  double width = (mode_ == "timer" ? 148 : HudPanelWidth(queued_, editing_)) * factor;
  double height = (mode_ == "timer" ? 44 : kHudHeight) * factor;
  placement_.Capture(placement_.Origin(WorkArea(), width, height, 92 * DpiScale()), WorkArea(), width, height);
}

void HudWindow::SetQueue(bool queued) {
  if (queued_ == queued) return;
  const bool resizing = mode_ == "panel" && !editing_;
  const double old_width = HudPanelWidth(queued_, editing_) * DpiScale() * placement_.scale;
  const auto old_origin = placement_.Origin(WorkArea(), old_width, kHudHeight * DpiScale() * placement_.scale, 92 * DpiScale());
  if (resizing) CaptureCenter();
  queued_ = queued;
  if (resizing) {
    if (dragging_) {
      const double new_width = HudPanelWidth(queued_, editing_) * DpiScale() * placement_.scale;
      const auto origin = placement_.Origin(WorkArea(), new_width, kHudHeight * DpiScale() * placement_.scale, 92 * DpiScale());
      drag_origin_.x += origin.x - old_origin.x;
    }
    ResizeAndPosition();
  }
}

void HudWindow::SetMode(const std::string& value) {
  std::string next = (value == "status" || value == "timer" || value == "off") ? value : "panel";
  if (next == mode_) return;
  if (floating()) CaptureCenter();
  dragging_ = false;
  mode_ = next;
  ResizeAndPosition();
  if (!floating()) ShowWindow(window_, SW_HIDE);
  else if (wanted_visible_) ShowReady();
}

void HudWindow::ResizeAndPosition() {
  if (!window_) return;
  const double dpi = DpiScale();
  int width = static_cast<int>((is_editor_ ? 360 : mode_ == "timer" ? 148 : HudPanelWidth(queued_, editing_)) * (is_editor_ ? 1 : placement_.scale) * dpi);
  int height = static_cast<int>((is_editor_ ? 228 : mode_ == "timer" ? 44 : kHudHeight) * (is_editor_ ? 1 : placement_.scale) * dpi);
  auto point = placement_.Origin(WorkArea(), width, height, 92 * dpi);
  if (is_editor_) {
    RECT rect; GetWindowRect(window_, &rect);
    point = placement_.Clamp({static_cast<double>(rect.left), static_cast<double>(rect.top)}, WorkArea(), width, height);
  }
  SetWindowPos(window_, above_window_ ? above_window_ : HWND_TOPMOST, static_cast<int>(point.x), static_cast<int>(point.y), width, height, SWP_NOACTIVATE);
  if (controller_) {
    MoveWindow(controller_->view()->GetNativeWindow(), 0, 0, width, height, TRUE);
    controller_->ForceRedraw();
  }
  if (!is_editor_) PositionEditor(true);
}

void HudWindow::PositionEditor(bool animate) {
  if (!editing_ || !editor_ || !editor_->window_) return;
  editor_->monitor_ = monitor_;
  RECT rect; GetWindowRect(window_, &rect);
  HudArea preview = floating() ? HudArea{static_cast<double>(rect.left), static_cast<double>(rect.top), static_cast<double>(rect.right - rect.left), static_cast<double>(rect.bottom - rect.top)} : HudArea{};
  double dpi = DpiScale(), width = 360 * dpi, height = 228 * dpi;
  int next = HudControlsPlacement::Corner(WorkArea(), width, height, preview, editor_corner_, dpi);
  if (next != editor_corner_ || !animate) {
    editor_corner_ = next;
    auto target = HudControlsPlacement::Rect(WorkArea(), width, height, next, dpi);
    editor_->AnimateTo({target.left, target.top}, animate);
  }
}

void HudWindow::AnimateTo(HudPoint target, bool animate) {
  RECT rect; GetWindowRect(window_, &rect);
  BOOL animations = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
  KillTimer(window_, 42);
  moving_ = false;
  if (!animate || !animations) {
    SetWindowPos(window_, above_window_ ? above_window_ : HWND_TOPMOST, static_cast<int>(target.x), static_cast<int>(target.y), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
    return;
  }
  motion_start_ = {static_cast<double>(rect.left), static_cast<double>(rect.top)};
  motion_target_ = target;
  motion_started_ = std::chrono::steady_clock::now();
  moving_ = true;
  SetTimer(window_, 42, 16, nullptr);
}

void HudWindow::ShowReady() {
  if (!window_ || !wanted_visible_ || (!is_editor_ && !floating())) return;
  if (!is_editor_ && !IsVisible() && !editing_) {
    POINT pointer; GetCursorPos(&pointer);
    monitor_ = MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST);
  }
  ResizeAndPosition();
  ShowWindow(window_, is_editor_ ? SW_SHOW : SW_SHOWNOACTIVATE);
}

void HudWindow::Configure(const flutter::DartProject& base, const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  if (!window_ || editing_) return;
  saved_ = placement_; saved_mode_ = mode_; CaptureCenter(); editing_ = true;
  POINT pointer; GetCursorPos(&pointer); monitor_ = MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST);
  WNDCLASSW wc = {}; wc.lpfnWndProc = GuidesProc;
  wc.hInstance = GetModuleHandle(nullptr); wc.lpszClassName = L"TsukikoHUDGuides";
  RegisterClassW(&wc);
  auto work = WorkArea();
  guides_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
    wc.lpszClassName, L"", WS_POPUP, static_cast<int>(work.left), static_cast<int>(work.top),
    static_cast<int>(work.width), static_cast<int>(work.height), nullptr, nullptr, wc.hInstance, nullptr);
  SetLayeredWindowAttributes(guides_, 0, 42, LWA_ALPHA);
  SetWindowPos(guides_, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  wanted_visible_ = true; ShowReady();
  previous_focus_ = GetForegroundWindow();
  if (!editor_) editor_ = std::make_unique<HudWindow>(true);
  editor_->monitor_ = monitor_; editor_corner_ = 0;
  editor_->above_window_ = window_;
  editor_->on_close_ = [this]() { if (on_editor_closed) on_editor_closed(); };
  editor_->Show(base, on_ready);
  PositionEditor(false);
  if (editor_->window_ && editor_->controller_) {
    SetForegroundWindow(editor_->window_);
    SetFocus(editor_->controller_->view()->GetNativeWindow());
  }
}

void HudWindow::FinishEditing(bool save) {
  if (!editing_) return;
  if (save) { CaptureCenter(); SavePlacement(); } else { placement_ = saved_; mode_ = saved_mode_; }
  dragging_ = false; editing_ = false;
  if (editor_) editor_->Hide();
  if (previous_focus_ && IsWindow(previous_focus_)) SetForegroundWindow(previous_focus_);
  previous_focus_ = nullptr;
  if (guides_) { DestroyWindow(guides_); guides_ = nullptr; }
  ResizeAndPosition();
}

void HudWindow::ReleaseEditor() { if (!editing_) editor_.reset(); }

void HudWindow::ResetPosition() {
  placement_ = HudPlacement();
  ResizeAndPosition();
  if (!editing_) SavePlacement();
}

void HudWindow::SetScale(double scale) {
  CaptureCenter();
  placement_.scale = HudPlacement::ValidScale(scale);
  ResizeAndPosition();
  if (!editing_) SavePlacement();
}

void HudWindow::Move(double dx, double dy, bool ended) {
  if (!window_ || !floating()) return;
  RECT rect; GetWindowRect(window_, &rect);
  double factor = DpiScale() * placement_.scale;
  POINT pointer; GetCursorPos(&pointer);
  if (!dragging_) {
    drag_origin_ = {static_cast<double>(rect.left), static_cast<double>(rect.top)};
    drag_pointer_ = {pointer.x - static_cast<LONG>(dx * factor), pointer.y - static_cast<LONG>(dy * factor)};
    dragging_ = true;
  }
  auto p = placement_.Snap({drag_origin_.x + pointer.x - drag_pointer_.x,
                           drag_origin_.y + pointer.y - drag_pointer_.y},
                          WorkArea(), rect.right - rect.left, rect.bottom - rect.top, 12 * DpiScale());
  SetWindowPos(window_, HWND_TOPMOST, static_cast<int>(p.x), static_cast<int>(p.y), 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
  placement_.Capture(p, WorkArea(), rect.right - rect.left, rect.bottom - rect.top);
  PositionEditor(true);
  if (ended) { dragging_ = false; if (!editing_) SavePlacement(); }
}

void HudWindow::Nudge(double dx, double dy) {
  if (!window_ || !floating()) return;
  RECT r; GetWindowRect(window_, &r);
  auto p = placement_.Clamp({r.left + dx * DpiScale(), r.top + dy * DpiScale()},
                            WorkArea(), r.right - r.left, r.bottom - r.top);
  SetWindowPos(window_, HWND_TOPMOST, static_cast<int>(p.x), static_cast<int>(p.y), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
  placement_.Capture(p, WorkArea(), r.right - r.left, r.bottom - r.top);
  PositionEditor(true);
}

void HudWindow::Prepare(
    const flutter::DartProject& base,
    const std::function<void(flutter::BinaryMessenger*)>& on_ready) {
  if (!window_) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = HudWindow::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = kHudClassName;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&wc);

    window_ = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | (is_editor_ ? WS_EX_LAYERED : WS_EX_NOACTIVATE), kHudClassName,
        L"tsukiko", WS_POPUP, 0, 0, is_editor_ ? 360 : kHudWidth, is_editor_ ? 228 : kHudHeight, nullptr, nullptr,
        GetModuleHandle(nullptr), this);
    if (!window_) return;

    // A lightly translucent editor stays readable over the desktop.
    if (is_editor_) SetLayeredWindowAttributes(window_, 0, 235, LWA_ALPHA);

    // Скруглённые углы — системные, как у всплывающих окон Windows 11.
    // На Windows 10 вызов просто ничего не делает.
    DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
    DwmSetWindowAttribute(window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner,
                          sizeof(corner));

    flutter::DartProject project = base;
    project.set_dart_entrypoint(is_editor_ ? "hudEditorMain" : "hudMain");
    controller_ = std::make_unique<flutter::FlutterViewController>(
        is_editor_ ? 360 : kHudWidth, is_editor_ ? 228 : kHudHeight, project);
    if (!controller_->engine() || !controller_->view()) {
      controller_ = nullptr;
      DestroyWindow(window_);
      window_ = nullptr;
      return;
    }
    RegisterPlugins(controller_->engine());
    HWND view = controller_->view()->GetNativeWindow();
    SetParent(view, window_);
    MoveWindow(view, 0, 0, is_editor_ ? 360 : kHudWidth, is_editor_ ? 228 : kHudHeight, TRUE);
    ShowWindow(view, SW_SHOW);
    on_ready(controller_->engine()->messenger());
    // Первый показ ждёт первый кадр Flutter. Иначе Windows показывает
    // серую пустую поверхность, пока запускается отдельный движок HUD.
    controller_->engine()->SetNextFrameCallback([this]() {
      first_frame_ready_ = true;
      ShowReady();
    });
    controller_->ForceRedraw();
  }
}

void HudWindow::Hide() {
  if (editing_) return;
  wanted_visible_ = false;
  if (window_) ShowWindow(window_, SW_HIDE);
}

bool HudWindow::IsVisible() const {
  return window_ && IsWindowVisible(window_);
}

LRESULT CALLBACK HudWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self =
      reinterpret_cast<HudWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self && message == WM_TIMER && wparam == 42 && self->moving_) {
    double t = std::clamp(std::chrono::duration<double>(std::chrono::steady_clock::now() - self->motion_started_).count() / .36, 0.0, 1.0);
    double progress = t * t * (3 - 2 * t);
    auto a = self->motion_start_, b = self->motion_target_;
    SetWindowPos(hwnd, self->above_window_ ? self->above_window_ : HWND_TOPMOST, static_cast<int>(a.x + (b.x - a.x) * progress), static_cast<int>(a.y + (b.y - a.y) * progress), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
    if (t >= 1) { KillTimer(hwnd, 42); self->moving_ = false; }
    return 0;
  }
  if (self && message == WM_CLOSE) {
    if (self->on_close_) self->on_close_();
    return 0;
  }
  // Recompute native bounds after Windows has updated the window DPI.
  // The Flutter child receives the original notification before resizing.
  constexpr UINT kRefreshHudBounds = WM_APP + 64;
  if (self && (message == WM_DPICHANGED || message == WM_DISPLAYCHANGE)) {
    self->monitor_ = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (self->controller_) self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    PostMessageW(hwnd, kRefreshHudBounds, 0, 0);
    return 0;
  }
  if (self && message == kRefreshHudBounds) {
    if (self->guides_) {
      auto work = self->WorkArea();
      SetWindowPos(self->guides_, HWND_TOPMOST, static_cast<int>(work.left), static_cast<int>(work.top),
                   static_cast<int>(work.width), static_cast<int>(work.height), SWP_NOACTIVATE);
      InvalidateRect(self->guides_, nullptr, TRUE);
    }
    self->ResizeAndPosition();
    return 0;
  }
  // Ни щелчком, ни клавишей фокус этой панели не достаётся: она нужна
  // поверх чужого окна, в которое сейчас диктуют.
  if (message == WM_MOUSEACTIVATE) return self && self->is_editor_ ? MA_ACTIVATE : MA_NOACTIVATE;
  if (message == WM_ERASEBKGND) {
    HDC hdc = reinterpret_cast<HDC>(wparam);
    RECT rect;
    GetClientRect(hwnd, &rect);
    HBRUSH brush = CreateSolidBrush(RGB(32, 32, 32));
    FillRect(hdc, &rect, brush);
    DeleteObject(brush);
    return 1;
  }
  if (self && self->controller_) {
    std::optional<LRESULT> result =
        self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                   lparam);
    if (result) return *result;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
