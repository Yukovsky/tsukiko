#include "flutter_window.h"

#include <optional>
#include <cwchar>
#include <cwctype>
#include <set>
#include <string>
#include <vector>
#include <commctrl.h>
#include <commdlg.h>
#include <ole2.h>
#include <shellapi.h>

#include "dictation_bridge.h"
#include "panel_window.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Что очередь берёт в работу: присылает Dart (audioExt и transcriptExt),
// строчными и с точкой. Пока список не пришёл, принимаем всё — решит очередь.
std::set<std::wstring> g_drop_extensions;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), length);
  return out;
}

// Папку берём целиком: очередь сама выберет из неё звук.
bool DropTakes(const std::wstring& path) {
  if (g_drop_extensions.empty()) return true;
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    return true;
  }
  const size_t dot = path.find_last_of(L".\\/");
  if (dot == std::wstring::npos || path[dot] != L'.') return false;
  std::wstring ext = path.substr(dot);
  for (auto& c : ext) c = static_cast<wchar_t>(std::towlower(c));
  return g_drop_extensions.count(ext) > 0;
}

std::vector<std::wstring> DroppedPaths(HDROP drop) {
  std::vector<std::wstring> paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring path(length + 1, L'\0');
    DragQueryFileW(drop, i, path.data(), length + 1);
    path.resize(length);
    paths.push_back(std::move(path));
  }
  return paths;
}

std::vector<std::wstring> DataObjectPaths(IDataObject* data) {
  FORMATETC format{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium{};
  if (!data || data->GetData(&format, &medium) != S_OK) return {};
  auto paths = DroppedPaths(reinterpret_cast<HDROP>(medium.hGlobal));
  ReleaseStgMedium(&medium);
  return paths;
}

flutter::EncodableList ToEncodable(const std::vector<std::wstring>& paths) {
  flutter::EncodableList list;
  for (const auto& path : paths) list.emplace_back(Utf8FromUtf16(path.c_str()));
  return list;
}

// Проводник работает без повышения, и в окно, запущенное от администратора,
// Windows не пускает OLE-перетаскивание (а WM_DROPFILES — без фильтра
// сообщений): курсор перечёркнут, приложение не узнаёт ничего. Так бывало после установщика
// «для всех пользователей» — его «Запустить tsukiko» наследовал права.
bool IsElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool elevated =
      GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size) &&
      elevation.TokenIsElevated;
  CloseHandle(token);
  return elevated;
}

// Свой OLE target нужен, чтобы видеть начало перетаскивания. WM_DROPFILES
// сообщает только о завершённом drop, поэтому анимация Flutter не появлялась.
// Путь читаем через Unicode API и выделяем буфер по реальной длине.
class FileDropTarget final : public IDropTarget {
 public:
  explicit FileDropTarget(flutter::MethodChannel<flutter::EncodableValue>* channel)
      : channel_(channel) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (iid != IID_IUnknown && iid != IID_IDropTarget) {
      *object = nullptr;
      return E_NOINTERFACE;
    }
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = --refs_;
    if (left == 0) delete this;
    return left;
  }

  // Тип проверяем сразу, а не после броска: неподходящий файл получает
  // перечёркнутый курсор, а окно говорит, что такие не берёт.
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                      DWORD* effect) override {
    const auto paths = DataObjectPaths(data);
    hovering_ = !paths.empty();
    supported_ = false;
    for (const auto& path : paths) {
      if (DropTakes(path)) {
        supported_ = true;
        break;
      }
    }
    *effect = supported_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (hovering_) {
      channel_->InvokeMethod("fileDragEntered",
                             std::make_unique<flutter::EncodableValue>(supported_));
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = supported_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (hovering_) Notify("fileDragExited");
    hovering_ = supported_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL,
                                DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    if (hovering_) Notify("fileDragExited");
    const bool supported = supported_;
    hovering_ = supported_ = false;
    if (!supported) return S_OK;
    const auto paths = DataObjectPaths(data);
    if (!paths.empty()) {
      *effect = DROPEFFECT_COPY;
      channel_->InvokeMethod(
          "filesDropped", std::make_unique<flutter::EncodableValue>(ToEncodable(paths)));
    }
    return S_OK;
  }

 private:
  void Notify(const char* method) {
    channel_->InvokeMethod(method, std::make_unique<flutter::EncodableValue>());
  }
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  ULONG refs_ = 1;
  bool hovering_ = false;
  bool supported_ = false;
};

flutter::EncodableList PickAudioFiles(HWND owner, DWORD* error) {
  std::wstring buffer(65536, L'\0');
  // GetOpenFileNameW uses a double-NUL-terminated filter list.
  static constexpr wchar_t filter[] =
      L"Audio and video\0*.ogg;*.oga;*.opus;*.mp3;*.m4a;*.aac;*.wav;*.aiff;*.aif;*.aifc;*.caf;*.flac;*.mp4;*.mov;*.m4b;*.wma;"
      L"*.mkv;*.webm;*.mka;*.m4v;*.3gp;*.3g2;*.wmv;*.avi;*.ts;*.mts;*.m2ts;*.amr;*.w64\0"
      L"All files\0*.*\0";
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = owner;
  dialog.lpstrFilter = filter;
  dialog.lpstrFile = buffer.data();
  dialog.nMaxFile = static_cast<DWORD>(buffer.size());
  dialog.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST |
                 OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

  flutter::EncodableList paths;
  if (!GetOpenFileNameW(&dialog)) {
    *error = CommDlgExtendedError();  // 0 means the user cancelled.
    return paths;
  }
  const wchar_t* first = buffer.c_str();
  const wchar_t* next = first + wcslen(first) + 1;
  if (*next == L'\0') {
    paths.emplace_back(Utf8FromUtf16(first));
    return paths;
  }
  for (; *next != L'\0'; next += wcslen(next) + 1) {
    paths.emplace_back(Utf8FromUtf16((std::wstring(first) + L"\\" + next).c_str()));
  }
  return paths;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool show_on_first_frame)
    : project_(project), show_on_first_frame_(show_on_first_frame) {}

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
  file_input_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "tsukiko/file_input",
      &flutter::StandardMethodCodec::GetInstance());
  file_input_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "setDropExtensions") {
      g_drop_extensions.clear();
      if (const auto* list = std::get_if<flutter::EncodableList>(call.arguments())) {
        for (const auto& item : *list) {
          if (const auto* ext = std::get_if<std::string>(&item)) {
            g_drop_extensions.insert(Utf16FromUtf8(*ext));
          }
        }
      }
      result->Success();
    } else if (call.method_name() == "pickAudioFiles") {
      DWORD error = 0;
      auto paths = PickAudioFiles(GetHandle(), &error);
      if (error != 0) {
        result->Error("file_dialog_failed", "Windows file dialog failed",
                      flutter::EncodableValue(static_cast<int32_t>(error)));
      } else {
        result->Success(flutter::EncodableValue(paths));
      }
    } else {
      result->NotImplemented();
    }
  });
  DictationBridge::GetInstance().Initialize(flutter_controller_->engine()->messenger(), GetHandle());
  // Окно настроек поднимает свой движок само, когда его впервые откроют.
  DictationBridge::GetInstance().SetDartProject(&project_);

  // Второй движок — панель диктовки. Без неё `panelMain` не запускал бы
  // никто, а с ним и диктовку: она живёт там, а не в очереди.
  panel_ = std::make_unique<PanelWindow>();
  if (auto* messenger = panel_->Create(project_)) {
    DictationBridge::GetInstance().AttachPanel(messenger, panel_.get());
  } else {
    panel_ = nullptr;
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // desktop_drop's Windows OLE target uses a fixed MAX_PATH buffer. Replace
  // only this view's target with one that reports hover and reads full paths.
  file_drop_window_ = flutter_controller_->view()->GetNativeWindow();
  RevokeDragDrop(file_drop_window_);
  if (!IsElevated()) {
    file_drop_target_ = new FileDropTarget(file_input_.get());
    if (RegisterDragDrop(file_drop_window_, file_drop_target_) != S_OK) {
      file_drop_target_->Release();
      file_drop_target_ = nullptr;
    }
  }
  if (!file_drop_target_) {
    // Запасной путь: без подсветки при наведении, но файл дойдёт. От
    // администратора WM_DROPFILES пропускаем через фильтр сообщений сами
    // (0x0049 — WM_COPYGLOBALDATA, им Проводник передаёт список файлов).
    for (const UINT message : {static_cast<UINT>(WM_DROPFILES),
                               static_cast<UINT>(WM_COPYDATA), 0x0049u}) {
      ChangeWindowMessageFilterEx(file_drop_window_, message, MSGFLT_ALLOW, nullptr);
    }
    SetWindowSubclass(file_drop_window_, FileDropProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
    DragAcceptFiles(file_drop_window_, TRUE);
  }

  // Показать окно на первом кадре — и только на первом.
  //
  // Show() — это ShowWindow(SW_SHOWNORMAL), а он не «показывает», а ещё и
  // выводит окно вперёд, отнимая фокус у того, что сейчас на экране.
  // Второй раз это уже не показ, а выпрыгивание: окно очереди лезло
  // поверх настроек на каждую правку — правка рассылается всем движкам
  // как «перечитать», главное окно перерисовывается, и обратный вызов
  // срабатывал снова.
  //
  // При запуске из автозапуска не показываем вовсе: приложение подняли
  // ради диктовки, а не ради очереди. Окно никуда не делось — оно
  // откроется по значку в трее или из панели. Ровно так же устроено
  // на macOS (MainFlutterWindow.awakeFromNib, --login-item), и Windows
  // отставала: там окно вылезало на весь экран при каждом входе в систему.
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (shown_once_ || !show_on_first_frame_) return;
    shown_once_ = true;
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (file_drop_window_) {
    if (file_drop_target_) {
      RevokeDragDrop(file_drop_window_);
      file_drop_target_->Release();
      file_drop_target_ = nullptr;
    } else {
      DragAcceptFiles(file_drop_window_, FALSE);
      RemoveWindowSubclass(file_drop_window_, FileDropProc, 1);
    }
    file_drop_window_ = nullptr;
  }
  file_input_ = nullptr;
  DictationBridge::GetInstance().Shutdown();
  panel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::FileDropProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam,
                                             UINT_PTR id, DWORD_PTR context) {
  if (message != WM_DROPFILES) {
    return DefSubclassProc(window, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<FlutterWindow*>(context);
  HDROP drop = reinterpret_cast<HDROP>(wparam);
  const auto paths = DroppedPaths(drop);
  DragFinish(drop);
  // Без наведения тип не проверить заранее — отбирает очередь, и про
  // неподходящие файлы она скажет сама.
  if (self->file_input_ && !paths.empty()) {
    self->file_input_->InvokeMethod(
        "filesDropped", std::make_unique<flutter::EncodableValue>(ToEncodable(paths)));
  }
  return 0;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (DictationBridge::GetInstance().HandleWindowMessage(hwnd, message, wparam, lparam)) {
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
