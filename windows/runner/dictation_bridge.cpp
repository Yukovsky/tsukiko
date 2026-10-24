#include "dictation_bridge.h"

#include <flutter/method_result_functions.h>

#include "panel_window.h"
#include "win32_window.h"

#include <shlobj.h>
#include <tlhelp32.h>
#include <shlwapi.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <iostream>
#include <utility>

#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_FLAC
#define MA_NO_MP3
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#define WM_TRAYICON (WM_USER + 101)
#define ID_TRAY_OPEN 1001
#define ID_TRAY_SETTINGS 1002
#define ID_TRAY_OPEN_RECORDINGS 1004
#define ID_TRAY_OPEN_MODELS 1005
#define ID_TRAY_QUIT 1003
// Ожидание второго стука при назначении сочетания.
#define ID_CAPTURE_TIMER 2001
// Событие клавиатуры из потока хука: lparam — DictationBridge::KeyEvent*,
// владение переходит к получателю.
#define WM_TSUKIKO_KEY (WM_APP + 71)
// Микрофон поднялся (или нет) в своём потоке: lparam —
// std::shared_ptr<DictationBridge::MicStart>*, владение у получателя.
#define WM_TSUKIKO_MIC (WM_APP + 72)
#define ID_PREWARM_TIMER 2004

/// Метка на наших же событиях клавиатуры.
///
/// Ctrl+V мы отправляем сами, и наш же перехватчик его видит. Без метки
/// это выглядит для него как настоящее нажатие: «ctrl» на сочетании
/// диктовки сработал бы от собственной вставки. Свои события узнаём
/// по dwExtraInfo, а не по флагу «внедрено» вообще: чужие внедрённые
/// нажатия (переназначения клавиш, экранная клавиатура) для человека
/// такие же настоящие, как обычные, и глотать их нельзя.
static const ULONG_PTR kOurInput = 0x7375'6B69;  // 'suki'
// Сколько итоговое состояние висит на плавающей панели.
#define ID_HUD_TIMER 2002

namespace {

bool BoolArgument(const flutter::EncodableMap& map, const char* key) {
  auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return false;
  const auto* value = std::get_if<bool>(&found->second);
  return value && *value;
}

int64_t IntArgument(const flutter::EncodableMap& map, const char* key) {
  auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  return 0;
}

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), static_cast<int>(str.size()), nullptr, 0);
  std::wstring out(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), static_cast<int>(str.size()), &out[0], size);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), static_cast<int>(wstr.size()), nullptr, 0, nullptr, nullptr);
  std::string out(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), static_cast<int>(wstr.size()), &out[0], size, nullptr, nullptr);
  return out;
}

int KeyNameToVk(const std::string& name) {
  if (name == "space") return VK_SPACE;
  if (name == "return" || name == "enter") return VK_RETURN;
  if (name == "tab") return VK_TAB;
  if (name == "escape") return VK_ESCAPE;
  if (name == "delete" || name == "backspace") return VK_BACK;
  if (name == "forwarddelete") return VK_DELETE;
  if (name == "left") return VK_LEFT;
  if (name == "right") return VK_RIGHT;
  if (name == "up") return VK_UP;
  if (name == "down") return VK_DOWN;
  if (name == "home") return VK_HOME;
  if (name == "end") return VK_END;
  if (name == "pageup") return VK_PRIOR;
  if (name == "pagedown") return VK_NEXT;
  if (name.size() == 1) {
    char c = name[0];
    if (c >= 'a' && c <= 'z') return 'A' + (c - 'a');
    if (c >= '0' && c <= '9') return c;
  }
  if (name.size() >= 2 && (name[0] == 'f' || name[0] == 'F')) {
    int fNum = std::atoi(name.c_str() + 1);
    if (fNum >= 1 && fNum <= 24) return VK_F1 + (fNum - 1);
  }
  if (name.size() >= 2 && name[0] == '#') {
    return std::atoi(name.c_str() + 1);
  }
  return 0;
}

std::string VkToKeyName(int vk) {
  switch (vk) {
    case VK_SPACE: return "space";
    case VK_RETURN: return "return";
    case VK_TAB: return "tab";
    case VK_ESCAPE: return "escape";
    case VK_BACK: return "delete";
    case VK_DELETE: return "forwarddelete";
    case VK_LEFT: return "left";
    case VK_RIGHT: return "right";
    case VK_UP: return "up";
    case VK_DOWN: return "down";
    case VK_HOME: return "home";
    case VK_END: return "end";
    case VK_PRIOR: return "pageup";
    case VK_NEXT: return "pagedown";
    default: break;
  }
  if (vk >= 'A' && vk <= 'Z') {
    return std::string(1, static_cast<char>('a' + (vk - 'A')));
  }
  if (vk >= '0' && vk <= '9') {
    return std::string(1, static_cast<char>(vk));
  }
  if (vk >= VK_F1 && vk <= VK_F24) {
    return "f" + std::to_string(vk - VK_F1 + 1);
  }
  return "#" + std::to_string(vk);
}

std::string ModifierFamily(std::string name) {
  if (name.rfind("left", 0) == 0) name.erase(0, 4);
  if (name.rfind("right", 0) == 0) name.erase(0, 5);
  if (name == "opt") return "alt";
  if (name == "win") return "cmd";
  return name;
}

bool IsSidedModifier(const std::string& name) {
  return name.rfind("left", 0) == 0 || name.rfind("right", 0) == 0;
}

bool ModifiersCanCoincide(const std::string& a, const std::string& b) {
  if (a == b) return true;
  if (ModifierFamily(a) != ModifierFamily(b)) return false;
  // Старое общее имя — маска любого физического бока.
  return !IsSidedModifier(a) || !IsSidedModifier(b);
}

bool ModifiersContain(const std::set<std::string>& current,
                      const std::set<std::string>& expected) {
  return std::all_of(expected.begin(), expected.end(), [&](const auto& wanted) {
    return std::any_of(current.begin(), current.end(), [&](const auto& actual) {
      return ModifiersCanCoincide(wanted, actual);
    });
  });
}

bool ModifiersMatch(const std::set<std::string>& current,
                    const std::set<std::string>& expected) {
  return current.size() == expected.size() &&
         ModifiersContain(current, expected) &&
         ModifiersContain(expected, current);
}

int PhysicalModifierVk(const KBDLLHOOKSTRUCT& kbd) {
  const int raw = static_cast<int>(kbd.vkCode);
  if (raw == VK_CONTROL) {
    return (kbd.flags & LLKHF_EXTENDED) ? VK_RCONTROL : VK_LCONTROL;
  }
  if (raw == VK_MENU) {
    return (kbd.flags & LLKHF_EXTENDED) ? VK_RMENU : VK_LMENU;
  }
  if (raw == VK_SHIFT) {
    const int mapped = static_cast<int>(
        MapVirtualKeyW(kbd.scanCode, MAPVK_VSC_TO_VK_EX));
    if (mapped == VK_LSHIFT || mapped == VK_RSHIFT) return mapped;
  }
  return raw;
}

const char* ModifierName(int vk) {
  switch (vk) {
    case VK_LCONTROL: return "leftctrl";
    case VK_RCONTROL: return "rightctrl";
    case VK_LMENU: return "leftalt";
    case VK_RMENU: return "rightalt";
    case VK_LSHIFT: return "leftshift";
    case VK_RSHIFT: return "rightshift";
    case VK_LWIN: return "leftwin";
    case VK_RWIN: return "rightwin";
    default: return nullptr;
  }
}

void AudioCaptureCallback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
  auto* bridge = static_cast<DictationBridge*>(pDevice->pUserData);
  if (!bridge || !pInput) return;

  auto* encoder = static_cast<ma_encoder*>(bridge->GetEncoder());
  if (encoder) {
    ma_encoder_write_pcm_frames(encoder, pInput, frameCount, nullptr);
  }

  bridge->PushAudioFrames(static_cast<const int16_t*>(pInput), frameCount,
                          pDevice->sampleRate);
}

} // namespace

DictationBridge& DictationBridge::GetInstance() {
  static DictationBridge instance;
  return instance;
}

DictationBridge::DictationBridge() = default;

DictationBridge::~DictationBridge() {
  Shutdown();
}

void DictationBridge::Initialize(flutter::BinaryMessenger* messenger, HWND window_handle) {
  main_window_ = window_handle;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "tsukiko/dictation", &flutter::StandardMethodCodec::GetInstance());

  RegisterMethodChannel();
  SetupTrayIcon();
  InstallKeyboardHook();
  // Панель записи поднимаем не сейчас, а когда приложение уже встало
  // и никто ничего не ждёт: подъём движка стоит сотен миллисекунд на том
  // же потоке, и в запуск его добавлять незачем — как и в первое нажатие
  // клавиши диктовки, чем он был раньше (см. PrewarmHud).
  SetTimer(main_window_, ID_PREWARM_TIMER, 2500, nullptr);
}

void DictationBridge::AttachPanel(flutter::BinaryMessenger* messenger,
                                  PanelWindow* panel) {
  panel_ = panel;
  panel_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "tsukiko/dictation",
          &flutter::StandardMethodCodec::GetInstance());
  RegisterHandler(panel_channel_.get());

  // Панель считает память сервера, пока её видно, и перестаёт, когда
  // её убрали. Без этих двух событий счётчик либо не заводится вовсе,
  // либо тикает в пустоту.
  panel->on_visibility_changed = [this](bool shown) {
    if (!panel_channel_) return;
    panel_channel_->InvokeMethod(shown ? "panelShown" : "panelHidden", nullptr);
  };
}

void DictationBridge::Shutdown() {
  UninstallKeyboardHook();
  RemoveTrayIcon();
  SettleMicStart();
  if (is_recording_) {
    StopAudioRecording();
  }
  // Полтора гигабайта в памяти нельзя оставлять сиротой. Оба движка:
  // диктовка держит модель между фразами, очередь — пока считает.
  KillDictationServer();
  KillRecognizer();

  // Свои окна и каналы отпускаем сейчас, пока жив главный движок Flutter.
  // Мост — синглтон и умирает последним, при выходе из процесса; если
  // держать их до тех пор, панель записи и окно настроек разбирались бы
  // уже после движков, на чьих мессенджерах сидят их каналы, — и выход
  // кончался падением в flutter_windows.dll.
  hud_editor_channel_.reset();
  hud_channel_.reset();
  hud_.reset();
  settings_channel_.reset();
  settings_.reset();
  panel_channel_.reset();
  channel_.reset();
  panel_ = nullptr;
}

/// Погасить движок расшифровки, если очередь как раз считала.
///
/// Раньше на выходе гас только сервер диктовки, а движок очереди
/// оставался: закрытие окна мимо `dispose`, и полтора гигабайта продолжали
/// жить сами по себе, досчитывая запись, которую уже некому показать.
///
/// По номеру, а не по имени процесса, — в отличие от сервера диктовки.
/// Имя `tsukiko-recognizer` носит и движок отдельной программы расшифровки
/// (`tsukiko-transcribe`), которая могла работать рядом и своего выхода
/// не просила: гасить её значило бы отнимать чужой час счёта. Номер пишет
/// очередь (`rememberRecognizerPid` в lib/core/whisper_server.dart) ровно
/// на то время, пока движок её собственный.
void DictationBridge::KillRecognizer() {
  wchar_t* appdata = nullptr;
  size_t len = 0;
  if (_wdupenv_s(&appdata, &len, L"APPDATA") != 0 || !appdata) return;
  std::wstring path =
      std::wstring(appdata) + L"\\app.yuko.tsukiko\\recognizer.pid";
  free(appdata);

  DWORD pid = 0;
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"r") == 0 && f) {
    unsigned long value = 0;
    if (fwscanf_s(f, L"%lu", &value) == 1) pid = static_cast<DWORD>(value);
    fclose(f);
  }
  _wremove(path.c_str());
  if (pid == 0) return;

  HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
  if (!proc) return;
  TerminateProcess(proc, 0);
  CloseHandle(proc);
}

/// Погасить забытый сервер диктовки.
///
/// На macOS своего отличают по метке в командной строке: там сервер
/// работает под именем `whisper-server`, и такое же имя может носить
/// чужой. Здесь проще и надёжнее — имя своё, `tsukiko-dictation`, мы его
/// сами и дали. По нему и узнаём; настоящий `whisper-server` не трогаем
/// вовсе, чтобы не погасить чужую работу.
void DictationBridge::KillDictationServer() {
  // Нынешний сервер известен точно по pid. Это покрывает и whisper-server,
  // и nemo-speech, имя которого нельзя безопасно угадать по снимку процессов.
  wchar_t* appdata = nullptr;
  size_t appdata_len = 0;
  if (_wdupenv_s(&appdata, &appdata_len, L"APPDATA") == 0 && appdata) {
    const std::wstring pid_path =
        std::wstring(appdata) + L"\\app.yuko.tsukiko\\whisper-server.pid";
    free(appdata);
    DWORD recorded_pid = 0;
    FILE* pid_file = nullptr;
    if (_wfopen_s(&pid_file, pid_path.c_str(), L"r") == 0 && pid_file) {
      unsigned long value = 0;
      if (fwscanf_s(pid_file, L"%lu", &value) == 1) {
        recorded_pid = static_cast<DWORD>(value);
      }
      fclose(pid_file);
    }
    _wremove(pid_path.c_str());
    if (recorded_pid != 0) {
      HANDLE recorded = OpenProcess(PROCESS_TERMINATE, FALSE, recorded_pid);
      if (recorded) {
        TerminateProcess(recorded, 0);
        CloseHandle(recorded);
      }
    }
  }

  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return;
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  std::vector<DWORD> victims;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      // Только своё имя. Просто `whisper-server` трогать нельзя: у
      // человека рядом может работать чужой, и погасить его — то же
      // самое, что снести чужую программу.
      if (std::wstring(entry.szExeFile).find(L"tsukiko-dictation") ==
          std::wstring::npos) {
        continue;
      }
      victims.push_back(entry.th32ProcessID);
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);

  for (DWORD pid : victims) {
    HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (!proc) continue;
    TerminateProcess(proc, 0);
    CloseHandle(proc);
  }
}

void DictationBridge::SetTaskbarButtonVisible(bool visible) {
  if (!main_window_) return;
  // Ничего не менялось — и трогать нечего. Смена стиля ниже прячет
  // и показывает окно, а зовут сюда с каждой правкой любой настройки:
  // панель диктовки после `settingsChanged` перечитывает всё подряд
  // и заново применяет в том числе эту галку. Человек видел, как окно
  // на миг пропадает и появляется всякий раз, когда он менял модель.
  if (taskbar_button_visible_ && *taskbar_button_visible_ == visible) return;
  taskbar_button_visible_ = visible;
  LONG_PTR style = GetWindowLongPtr(main_window_, GWL_EXSTYLE);
  // Стиль меняется только на скрытом окне: иначе система кнопку
  // не перерисует.
  const bool was_visible = IsWindowVisible(main_window_) != 0;
  if (was_visible) ShowWindow(main_window_, SW_HIDE);
  if (visible) {
    style &= ~WS_EX_TOOLWINDOW;
    style |= WS_EX_APPWINDOW;
  } else {
    style &= ~WS_EX_APPWINDOW;
    style |= WS_EX_TOOLWINDOW;
  }
  SetWindowLongPtr(main_window_, GWL_EXSTYLE, style);
  if (was_visible) ShowWindow(main_window_, SW_SHOW);
}

void DictationBridge::RegisterMethodChannel() {
  RegisterHandler(channel_.get());
}

/// Обработчик один на оба канала: спрашивать умеют обе стороны — очередь
/// про занятость диктовки, панель про запись и клавиши.
void DictationBridge::RegisterHandler(
    flutter::MethodChannel<flutter::EncodableValue>* target) {
  target->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();

    if (method == "windowTheme") {
      // 'light', 'dark' или пусто — как в системе. Шлёт главное окно,
      // когда меняется настройка «Тема».
      const auto* id = std::get_if<std::string>(call.arguments());
      const int mode = !id ? 0 : *id == "light" ? 1 : *id == "dark" ? 2 : 0;
      Win32Window::SetThemeOverride(mode);
      if (main_window_) Win32Window::ApplyTitleBarTheme(main_window_);
      if (settings_ && settings_->handle()) {
        Win32Window::ApplyTitleBarTheme(settings_->handle());
      }
      result->Success();
      return;
    }
    if (method == "bind") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto parseSpec = [](const flutter::EncodableMap& map) -> HotkeySpec {
          HotkeySpec spec;
          auto modsIt = map.find(flutter::EncodableValue("mods"));
          if (modsIt != map.end()) {
            if (const auto* list = std::get_if<flutter::EncodableList>(&modsIt->second)) {
              for (const auto& item : *list) {
                if (const auto* s = std::get_if<std::string>(&item)) {
                  spec.mods.insert(*s);
                }
              }
            }
          }
          auto keysIt = map.find(flutter::EncodableValue("keys"));
          if (keysIt != map.end()) {
            if (const auto* list = std::get_if<flutter::EncodableList>(&keysIt->second)) {
              for (const auto& item : *list) {
                if (const auto* s = std::get_if<std::string>(&item)) {
                  int vk = KeyNameToVk(*s);
                  if (vk > 0) spec.keys.insert(vk);
                }
              }
            }
          }
          auto tapsIt = map.find(flutter::EncodableValue("taps"));
          if (tapsIt != map.end()) {
            if (const auto* t = std::get_if<int>(&tapsIt->second)) {
              spec.taps = *t;
            }
          }
          spec.is_empty = spec.mods.empty() && spec.keys.empty();
          return spec;
        };

        auto holdIt = args->find(flutter::EncodableValue("hold"));
        if (holdIt != args->end()) {
          if (const auto* hMap = std::get_if<flutter::EncodableMap>(&holdIt->second)) {
            hold_spec_ = parseSpec(*hMap);
          }
        }
        auto toggleIt = args->find(flutter::EncodableValue("toggle"));
        if (toggleIt != args->end()) {
          if (const auto* tMap = std::get_if<flutter::EncodableMap>(&toggleIt->second)) {
            toggle_spec_ = parseSpec(*tMap);
          }
        }
        auto cancelIt = args->find(flutter::EncodableValue("cancel"));
        if (cancelIt != args->end()) {
          if (const auto* cMap = std::get_if<flutter::EncodableMap>(&cancelIt->second)) {
            cancel_spec_ = parseSpec(*cMap);
          }
        }
        // Защёлки относятся к прежним сочетаниям: с новыми они соврут
        // о том, что клавиша уже нажата.
        hold_state_ = TapState();
        toggle_state_ = TapState();
        cancel_state_ = TapState();
      }
      result->Success();
    } else if (method == "capture") {
      is_capturing_ = true;
      capture_swallow_ = true;
      captured_mods_.clear();
      captured_keys_.clear();
      held_keys_.clear();
      // Начало отсчёта и ожидание второго стука — с чистого листа:
      // прошлый захват мог кончиться на полпути.
      capture_started_at_ = 0;
      has_pending_capture_ = false;
      KillTimer(main_window_, ID_CAPTURE_TIMER);
      result->Success();
    } else if (method == "cancelCapture") {
      is_capturing_ = false;
      capture_swallow_ = false;
      has_pending_capture_ = false;
      KillTimer(main_window_, ID_CAPTURE_TIMER);
      captured_mods_.clear();
      captured_keys_.clear();
      result->Success();
    } else if (method == "settingsChanged") {
      SendReloadSettings();
      result->Success();
    } else if (method == "calibrationActive") {
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared(
          result.release());
      if (!panel_channel_) {
        shared->Success();
      } else {
        panel_channel_->InvokeMethod(
            "calibrationActive",
            std::make_unique<flutter::EncodableValue>(*call.arguments()),
            std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
                [shared](const flutter::EncodableValue*) { shared->Success(); },
                [shared](const std::string&, const std::string&,
                         const flutter::EncodableValue*) { shared->Success(); },
                [shared]() { shared->Success(); }));
      }
    } else if (method == "dictationStatus") {
      // Спрашивает очередь, отвечает диктовка: только её изолят знает,
      // говорит ли человек прямо сейчас. Прежде здесь возвращалось
      // «recording»/«idle» — слова, которых Dart не знает: они обои
      // сводились к «away», и очередь никогда не уступала диктовке.
      ForwardToPanel("dictationStatus", std::move(result),
                     flutter::EncodableValue("away"));
    } else if (method == "releaseModel") {
      ForwardToPanel("releaseModel", std::move(result),
                     flutter::EncodableValue());
    } else if (method == "openSettings") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      std::string tab = "dictation";
      if (args) {
        auto it = args->find(flutter::EncodableValue("tab"));
        if (it != args->end()) {
          if (const auto* t = std::get_if<std::string>(&it->second)) tab = *t;
        }
      }
      ShowSettings(tab);
      result->Success();
    } else if (method == "initialTab") {
      result->Success(flutter::EncodableValue(settings_tab_));
    } else if (method == "permissions") {
      result->Success(flutter::EncodableValue(true));
    } else if (method == "requestPermission" || method == "openPermissionSettings") {
      ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-microphone", nullptr, nullptr, SW_SHOWNORMAL);
      result->Success();
    } else if (method == "serverMarks") {
      // Метки нужны там, где своё имя от чужого не отличить. Здесь имя
      // своё — `tsukiko-dictation`, — и метка не добавляет ничего
      // (см. KillDictationServer). Принимаем и молчим: канал один
      // на обе системы.
      result->Success();
    } else if (method == "trash") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto pathIt = args->find(flutter::EncodableValue("path"));
        if (pathIt != args->end()) {
          if (const auto* path = std::get_if<std::string>(&pathIt->second)) {
            result->Success(flutter::EncodableValue(MoveToTrash(*path)));
            return;
          }
        }
      }
      result->Success(flutter::EncodableValue(false));
    } else if (method == "quit") {
      PostQuitMessage(0);
      result->Success();
    } else if (method == "record") {
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> reply(
          result.release());
      StartAudioRecording([reply](const std::string& path) {
        // Пустая строка в Dart выглядит как настоящий путь. Из-за этого
        // не поднявшийся микрофон отправлял в whisper файл с именем "",
        // а человек получал ложное «запись сохранена» вместо причины.
        if (path.empty()) {
          reply->Success();
        } else {
          reply->Success(flutter::EncodableValue(path));
        }
      });
    } else if (method == "stopRecord") {
      std::string path = StopAudioRecording();
      result->Success(flutter::EncodableValue(path));
    } else if (method == "level") {
      result->Success(flutter::EncodableValue(GetAudioLevel()));
    } else if (method == "micLive") {
      result->Success(flutter::EncodableValue(mic_live_.load()));
    } else if (method == "paste") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        auto textIt = args->find(flutter::EncodableValue("text"));
        if (textIt != args->end()) {
          if (const auto* text = std::get_if<std::string>(&textIt->second)) {
            result->Success(flutter::EncodableValue(PasteText(*text)));
            return;
          }
        }
      }
      result->Success(flutter::EncodableValue(false));
    } else if (method == "hud") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args) {
        for (const auto* key : {"pending", "processing"}) {
          auto value = args->find(flutter::EncodableValue(key));
          if (value != args->end()) hud_queue_[flutter::EncodableValue(key)] = value->second;
        }
        if (hud_channel_) hud_channel_->InvokeMethod("hudQueue",
            std::make_unique<flutter::EncodableValue>(hud_queue_));
        PrewarmHud();
        auto mode = args->find(flutter::EncodableValue("mode"));
        if (hud_ && mode != args->end()) if (const auto* value = std::get_if<std::string>(&mode->second)) hud_->SetMode(*value);
        SendHudLayout();
        auto it = args->find(flutter::EncodableValue("state"));
        if (it != args->end()) {
          if (const auto* st = std::get_if<std::string>(&it->second)) {
            SetHudState(*st);
          }
        }
      }
      result->Success();
    } else if (method == "getHudQueue") {
      result->Success(flutter::EncodableValue(hud_queue_));
    } else if (method == "getHudState") {
      result->Success(flutter::EncodableValue(current_hud_state_));
    } else if (method == "configureHud") {
      PrewarmHud();
      if (const auto* labels = std::get_if<flutter::EncodableMap>(call.arguments())) hud_layout_labels_ = *labels;
      if (hud_ && !hud_->editing() && project_) {
        auto mode = hud_layout_labels_.find(flutter::EncodableValue("mode"));
        if (mode != hud_layout_labels_.end()) if (const auto* value = std::get_if<std::string>(&mode->second)) hud_->SetMode(*value);
        hud_->on_editor_closed = [this]() {
          hud_->FinishEditing(false); NotifyHudMode(); SetHudState(current_hud_state_); SendHudLayout();
          PostMessageW(main_window_, WM_APP + 66, 0, 0);
        };
        hud_->Configure(*project_, [this](flutter::BinaryMessenger* messenger) {
          hud_editor_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "tsukiko/dictation", &flutter::StandardMethodCodec::GetInstance());
          RegisterHandler(hud_editor_channel_.get());
          SendHudLayout();
        });
      }
      UpdateTrayIndicator();
      SendHudLayout();
      result->Success();
    } else if (method == "resetHud") {
      PrewarmHud();
      if (hud_) hud_->ResetPosition();
      SendHudLayout(); result->Success();
    } else if (method == "getHudLayout") {
      flutter::EncodableMap layout = hud_layout_labels_;
      layout[flutter::EncodableValue("editing")] = flutter::EncodableValue(hud_ && hud_->editing());
      layout[flutter::EncodableValue("scaleValue")] = flutter::EncodableValue(hud_ ? hud_->scale() : 1.0);
      layout[flutter::EncodableValue("mode")] = flutter::EncodableValue(hud_ ? hud_->mode() : "panel");
      result->Success(flutter::EncodableValue(layout));
    } else if (method == "hudLayout") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args && hud_) {
        auto number = [&](const char* key, double fallback) {
          auto value = args->find(flutter::EncodableValue(key));
          if (value != args->end()) if (const auto* n = std::get_if<double>(&value->second)) return *n;
          return fallback;
        };
        if (args->count(flutter::EncodableValue("mode"))) {
          const auto* mode = std::get_if<std::string>(&args->at(flutter::EncodableValue("mode")));
          if (mode) { hud_->SetMode(*mode); NotifyHudMode(); SetHudState(current_hud_state_); }
        } else if (args->count(flutter::EncodableValue("nudgeX"))) {
          hud_->Nudge(number("nudgeX", 0), number("nudgeY", 0));
        } else if (args->count(flutter::EncodableValue("dx"))) {
          hud_->Move(number("dx", 0), number("dy", 0),
              BoolArgument(*args, "end"));
        } else if (args->count(flutter::EncodableValue("scaleValue"))) {
          hud_->SetScale(number("scaleValue", 1));
        } else if (args->count(flutter::EncodableValue("save"))) {
          bool save = BoolArgument(*args, "save");
          hud_->FinishEditing(save);
          if (!save) NotifyHudMode();
          SetHudState(current_hud_state_);
          PostMessageW(main_window_, WM_APP + 66, 0, 0);
        }
      }
      SendHudLayout(); result->Success();
    } else if (method == "hudQueueMenu") {
      HMENU menu = CreatePopupMenu();
      const auto* labels = std::get_if<flutter::EncodableMap>(call.arguments());
      const char* actions[] = {"record", "abort", "clearQueue"};
      for (int i = 0; i < 3; ++i) {
        bool enabled = i == 0 ? current_hud_state_ != "recording" :
            i == 1 ? BoolArgument(hud_queue_, "processing") :
            IntArgument(hud_queue_, "pending") > 0;
        if (enabled && labels) {
          auto value = labels->find(flutter::EncodableValue(actions[i]));
          if (value != labels->end()) {
            if (const auto* label = std::get_if<std::string>(&value->second)) {
              AppendMenuW(menu, MF_STRING, i + 1, Utf8ToWide(*label).c_str());
            }
          }
        }
      }
      POINT at; GetCursorPos(&at);
      HWND previous = GetForegroundWindow();
      HWND owner = hud_ ? hud_->handle() : main_window_;
      SetForegroundWindow(owner);
      int command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
          at.x, at.y, 0, owner, nullptr);
      DestroyMenu(menu);
      if (previous && IsWindow(previous)) SetForegroundWindow(previous);
      if (command >= 1 && command <= 3 && panel_channel_) {
        panel_channel_->InvokeMethod("hud", std::make_unique<flutter::EncodableValue>(actions[command - 1]));
      }
      result->Success();
    } else if (method == "hudAction") {
      // Нажали кнопку на плавающей панели. Рисует её свой изолят, а
      // делает дело — диктовка: переправляем ей.
      if (const auto* action = std::get_if<std::string>(call.arguments())) {
        if (panel_channel_) {
          panel_channel_->InvokeMethod(
              "hud", std::make_unique<flutter::EncodableValue>(*action));
        }
      }
      result->Success();
    } else if (method == "openMainWindow") {
      ShowMainWindow();
      result->Success();
    } else if (method == "panelHeight") {
      // Приходит картой {'height': …}, а не голым числом.
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (panel_ && args) {
        auto it = args->find(flutter::EncodableValue("height"));
        if (it != args->end()) {
          if (const auto* h = std::get_if<double>(&it->second)) {
            panel_->SetContentHeight(static_cast<int>(*h));
          }
        }
      }
      result->Success();
    } else if (method == "dockIcon") {
      // На macOS это значок в Dock, здесь — кнопка на панели задач.
      // Прячется она стилем окна: WS_EX_TOOLWINDOW кнопку убирает,
      // WS_EX_APPWINDOW возвращает. Значок в области уведомлений при этом
      // остаётся — иначе приложение стало бы недостижимым.
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      bool visible = true;
      if (args) {
        auto it = args->find(flutter::EncodableValue("visible"));
        if (it != args->end()) {
          if (const auto* v = std::get_if<bool>(&it->second)) visible = *v;
        }
      }
      SetTaskbarButtonVisible(visible);
      result->Success();
    } else if (method == "loginItem") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args && args->find(flutter::EncodableValue("enabled")) != args->end()) {
        auto enIt = args->find(flutter::EncodableValue("enabled"));
        if (const auto* en = std::get_if<bool>(&enIt->second)) {
          result->Success(flutter::EncodableValue(SetLoginItemEnabled(*en)));
          return;
        }
      }
      result->Success(flutter::EncodableValue(GetLoginItemEnabled()));
    } else {
      result->NotImplemented();
    }
  });
}

void DictationBridge::SetupTrayIcon() {
  if (tray_installed_) return;

  ZeroMemory(&tray_data_, sizeof(tray_data_));
  tray_data_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_data_.hWnd = main_window_;
  tray_data_.uID = 1;
  tray_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_data_.uCallbackMessage = WM_TRAYICON;
  tray_data_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
  if (!tray_data_.hIcon) {
    tray_data_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  wcscpy_s(tray_data_.szTip, L"tsukiko — диктовка и расшифровка");

  Shell_NotifyIconW(NIM_ADD, &tray_data_);
  tray_installed_ = true;
}

void DictationBridge::UpdateTrayIndicator() {
  if (!tray_installed_) return;
  bool active = hud_ && hud_->mode() == "status" && (current_hud_state_ == "recording" || hud_->editing());
  if (active && !recording_icon_) {
    int size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForWindow(main_window_));
    size = std::max(16, size);
    BITMAPINFO info = {}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size; info.bmiHeader.biHeight = -size;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
    void* pixels = nullptr;
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (color && pixels) {
      ZeroMemory(pixels, size * size * 4);
      auto previous = SelectObject(dc, color);
      auto point = [size](int value) { return value * size / 18; };
      HBRUSH brush = CreateSolidBrush(RGB(235, 55, 65));
      HPEN pen = CreatePen(PS_SOLID, std::max(1, size / 9), RGB(235, 55, 65));
      auto old_brush = SelectObject(dc, brush), old_pen = SelectObject(dc, pen);
      RoundRect(dc, point(6), point(1), point(12), point(11), point(5), point(5));
      Arc(dc, point(3), point(3), point(15), point(14), point(3), point(8), point(15), point(8));
      MoveToEx(dc, point(9), point(13), nullptr); LineTo(dc, point(9), point(17));
      MoveToEx(dc, point(5), point(17), nullptr); LineTo(dc, point(13), point(17));
      SelectObject(dc, old_brush); SelectObject(dc, old_pen); DeleteObject(brush); DeleteObject(pen);
      auto* rgba = static_cast<DWORD*>(pixels);
      for (int i = 0; i < size * size; ++i) if (rgba[i] & 0xffffff) rgba[i] |= 0xff000000;
      HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
      ICONINFO icon = {}; icon.fIcon = TRUE; icon.hbmColor = color; icon.hbmMask = mask;
      recording_icon_ = CreateIconIndirect(&icon);
      DeleteObject(mask); SelectObject(dc, previous);
    }
    if (color) DeleteObject(color);
    DeleteDC(dc);
  }
  tray_data_.uFlags = NIF_ICON | NIF_TIP;
  tray_data_.hIcon = active && recording_icon_ ? recording_icon_ : LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
  wcscpy_s(tray_data_.szTip, active ? L"tsukiko — идёт запись" : L"tsukiko — диктовка и расшифровка");
  Shell_NotifyIconW(NIM_MODIFY, &tray_data_);
}

void DictationBridge::RemoveTrayIcon() {
  if (!tray_installed_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_data_);
  tray_installed_ = false;
  if (recording_icon_) { DestroyIcon(recording_icon_); recording_icon_ = nullptr; }
}

namespace {

std::wstring GetModelsDirectoryPath() {
  wchar_t* appdata = nullptr;
  size_t len = 0;
  std::wstring path;
  if (_wdupenv_s(&appdata, &len, L"APPDATA") == 0 && appdata) {
    path = std::wstring(appdata) + L"\\app.yuko.tsukiko\\models";
    free(appdata);
  }
  return path;
}

std::wstring GetRecordingsDirectoryPath() {
  wchar_t* appdata = nullptr;
  size_t len = 0;
  if (_wdupenv_s(&appdata, &len, L"APPDATA") == 0 && appdata) {
    std::wstring settings_path =
        std::wstring(appdata) + L"\\app.yuko.tsukiko\\settings.json";
    free(appdata);
    FILE* f = nullptr;
    if (_wfopen_s(&f, settings_path.c_str(), L"rb") == 0 && f) {
      fseek(f, 0, SEEK_END);
      long size = ftell(f);
      fseek(f, 0, SEEK_SET);
      if (size > 0 && size < 1024 * 1024) {
        std::string content(size, '\0');
        fread(&content[0], 1, size, f);
        fclose(f);
        auto pos = content.find("\"libraryPath\"");
        if (pos != std::string::npos) {
          auto colon = content.find(':', pos);
          if (colon != std::string::npos) {
            auto q1 = content.find('"', colon);
            if (q1 != std::string::npos) {
              auto q2 = content.find('"', q1 + 1);
              if (q2 != std::string::npos) {
                std::string path_str = content.substr(q1 + 1, q2 - q1 - 1);
                std::string unescaped;
                for (size_t i = 0; i < path_str.size(); ++i) {
                  if (path_str[i] == '\\' && i + 1 < path_str.size() &&
                      path_str[i + 1] == '\\') {
                    unescaped += '\\';
                    ++i;
                  } else {
                    unescaped += path_str[i];
                  }
                }
                if (!unescaped.empty()) {
                  int wlen = MultiByteToWideChar(CP_UTF8, 0, unescaped.c_str(),
                                                 -1, nullptr, 0);
                  if (wlen > 0) {
                    std::wstring wpath(wlen - 1, L'\0');
                    MultiByteToWideChar(CP_UTF8, 0, unescaped.c_str(), -1,
                                       &wpath[0], wlen);
                    return wpath;
                  }
                }
              }
            }
          }
        }
      } else {
        fclose(f);
      }
    }
  }

  wchar_t* userprofile = nullptr;
  size_t ulen = 0;
  if (_wdupenv_s(&userprofile, &ulen, L"USERPROFILE") == 0 && userprofile) {
    std::wstring path = std::wstring(userprofile) + L"\\Documents\\tsukiko";
    free(userprofile);
    return path;
  }
  return L"";
}

}  // namespace

void DictationBridge::ShowContextMenu() {
  POINT pt;
  GetCursorPos(&pt);
  HMENU hMenu = CreatePopupMenu();
  InsertMenuW(hMenu, 0, MF_BYPOSITION | MF_STRING, ID_TRAY_OPEN, L"Открыть tsukiko");
  InsertMenuW(hMenu, 1, MF_BYPOSITION | MF_STRING, ID_TRAY_SETTINGS, L"Настройки…");
  InsertMenuW(hMenu, 2, MF_BYPOSITION | MF_SEPARATOR, 0, nullptr);
  InsertMenuW(hMenu, 3, MF_BYPOSITION | MF_STRING, ID_TRAY_OPEN_RECORDINGS, L"Открыть папку записей");
  InsertMenuW(hMenu, 4, MF_BYPOSITION | MF_STRING, ID_TRAY_OPEN_MODELS, L"Открыть папку моделей");
  InsertMenuW(hMenu, 5, MF_BYPOSITION | MF_SEPARATOR, 0, nullptr);
  InsertMenuW(hMenu, 6, MF_BYPOSITION | MF_STRING, ID_TRAY_QUIT, L"Выход");

  SetForegroundWindow(main_window_);
  int cmd = TrackPopupMenu(hMenu, TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, main_window_, nullptr);
  DestroyMenu(hMenu);

  if (cmd == ID_TRAY_OPEN) {
    ShowMainWindow();
  } else if (cmd == ID_TRAY_SETTINGS) {
    ShowSettings("dictation");
  } else if (cmd == ID_TRAY_OPEN_RECORDINGS) {
    std::wstring path = GetRecordingsDirectoryPath();
    if (!path.empty()) {
      SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
      ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOW);
    }
  } else if (cmd == ID_TRAY_OPEN_MODELS) {
    std::wstring path = GetModelsDirectoryPath();
    if (!path.empty()) {
      SHCreateDirectoryExW(nullptr, path.c_str(), nullptr);
      ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOW);
    }
  } else if (cmd == ID_TRAY_QUIT) {
    PostQuitMessage(0);
  }
}

bool DictationBridge::HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) {
      ResetKeyState();
      SendSystemSleep();
      return true;
    }
    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
      ResetKeyState();
      SendSystemWake();
      return true;
    }
  }
  if (message == WM_APP + 66) {
    if (hud_ && !hud_->editing()) { hud_editor_channel_.reset(); hud_->ReleaseEditor(); }
    return true;
  }
  if (message == WM_TIMER && wparam == ID_HUD_TIMER) {
    KillTimer(main_window_, ID_HUD_TIMER);
    if (current_hud_state_ != "recording" && current_hud_state_ != "transcribing") SetHudState("hidden");
    return true;
  }
  if (message == WM_TIMER && wparam == ID_PREWARM_TIMER) {
    KillTimer(main_window_, ID_PREWARM_TIMER);
    PrewarmHud();
    return true;
  }


  if (message == WM_TSUKIKO_MIC) {
    std::unique_ptr<std::shared_ptr<MicStart>> start(
        reinterpret_cast<std::shared_ptr<MicStart>*>(lparam));
    if (start && *start) CompleteMicStart(*start);
    return true;
  }
  if (message == WM_TSUKIKO_KEY) {
    std::unique_ptr<KeyEvent> event(reinterpret_cast<KeyEvent*>(lparam));
    if (event) ProcessKeyEvent(*event);
    return true;
  }
  if (message == WM_TIMER && wparam == ID_CAPTURE_TIMER) {
    KillTimer(main_window_, ID_CAPTURE_TIMER);
    OnCaptureTimeout();
    return true;
  }
  if (message == WM_TRAYICON) {
    if (lparam == WM_LBUTTONUP) {
      // Значку принадлежит панель диктовки, а не главное окно: так же
      // на macOS. Главное окно открывается пунктом меню.
      if (panel_) {
        panel_->Toggle();
      } else {
        ToggleMainWindow();
      }
      return true;
    }
    if (lparam == WM_RBUTTONUP) {
      ShowContextMenu();
      return true;
    }
  } else if (message == WM_CLOSE) {
    // Вместо выхода закрытие окна прячет его в трей
    ShowWindow(main_window_, SW_HIDE);
    return true;
  }
  return false;
}

void DictationBridge::ShowMainWindow() {
  if (!main_window_) return;
  ShowWindow(main_window_, SW_RESTORE);
  SetForegroundWindow(main_window_);
}

void DictationBridge::ToggleMainWindow() {
  if (!main_window_) return;
  if (IsWindowVisible(main_window_)) {
    ShowWindow(main_window_, SW_HIDE);
  } else {
    ShowMainWindow();
  }
}

// ── Клавиатурный хук ────────────────────────────────────────────────────────

void DictationBridge::InstallKeyboardHook() {
  if (hook_thread_.joinable()) return;
  HANDLE started = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  hook_thread_ = std::thread([this, started]() {
    // Очередь сообщений потоку нужна до того, как о нём узнают снаружи:
    // иначе WM_QUIT из UninstallKeyboardHook некуда положить.
    MSG msg;
    PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    hook_thread_id_ = GetCurrentThreadId();
    SetEvent(started);
    HookThreadMain();
  });
  WaitForSingleObject(started, 2000);
  CloseHandle(started);
}

void DictationBridge::HookThreadMain() {
  // Поток только отвечает системе «пропустить или проглотить», и отвечать
  // он должен сразу, даже когда машина нагружена.
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc,
                                     GetModuleHandle(nullptr), 0);
  // Windows молча снимает низкоуровневый хук, если он однажды не ответил
  // вовремя, и сообщить об этом некому: хоткей просто умирает до перезапуска.
  // Раз в полминуты ставим хук заново, но только когда ничего не зажато:
  // иначе потерянное отпускание оставило бы запись включённой.
  SetTimer(nullptr, 0, 30000, nullptr);
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (msg.message == WM_TIMER && msg.hwnd == nullptr) {
      bool any_down = false;
      for (int vk = 8; vk < 255 && !any_down; ++vk) {  // с 8: мышь не считаем
        any_down = (GetAsyncKeyState(vk) & 0x8000) != 0;
      }
      if (!any_down) {
        if (HHOOK fresh = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc,
                                            GetModuleHandle(nullptr), 0)) {
          if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
          keyboard_hook_ = fresh;
        }
      }
      continue;
    }
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (keyboard_hook_) {
    UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
}

void DictationBridge::UninstallKeyboardHook() {
  if (hook_thread_.joinable()) {
    // Поток мог не успеть завести очередь за две секунды ожидания при
    // запуске: тогда WM_QUIT некуда положить, и join ждал бы вечно.
    // Номер потока появляется ровно тогда, когда очередь уже есть.
    while (!hook_thread_id_) Sleep(1);
    PostThreadMessageW(hook_thread_id_, WM_QUIT, 0, 0);
    hook_thread_.join();
    hook_thread_id_ = 0;
  }
  held_keys_.clear();
}

bool DictationBridge::TapState::Update(bool raw, bool is_double,
                                      bool base_held, ULONGLONG now) {
  if (suppressed) {
    if (base_held) return false;
    suppressed = false;
  }
  const bool was_pressed = pressed_at != 0;
  if (raw == was_pressed) return false;

  if (raw) {
    pressed_at = now;
    const bool armed = armed_at != 0 && (now - armed_at) < kDoubleTapWindowMs;
    // Двойному нужен взвод первым стуком; обычному хватает нажатия.
    const bool on = is_double ? armed : true;
    if (on == active) return false;
    active = on;
    return true;
  }

  const ULONGLONG held = now - pressed_at;
  pressed_at = 0;
  // Сочетание не отпустили, а набрали поверх лишнее: AltGr+8 ради «₽»,
  // Alt+Tab, Ctrl+C. Это не стук. Прежде такой выход взводил двойное,
  // а отпускание лишней клавиши при всё ещё зажатом Alt считалось вторым
  // стуком — и набранный «₽» включал запись. Пока набор не отпустят
  // целиком, он больше не нажатие. Уже сработавшее сочетание выключается,
  // как и раньше: что это отмена, решает вызывающий.
  if (base_held) {
    armed_at = 0;
    if (!active) {
      suppressed = true;
      return false;
    }
    active = false;
    return true;
  }
  // Короткое нажатие, которое ничего не включило, — это первый стук.
  // Затянувшееся или уже сработавшее взводит не больше, чем один раз.
  armed_at = (!active && held < kTapMaxHoldMs) ? now : 0;
  if (!active) return false;
  active = false;
  return true;
}

void DictationBridge::TapState::SuppressUntilRelease() {
  suppressed = true;
  active = false;
  pressed_at = 0;
  armed_at = 0;
}

/// Второй стук не пришёл вовремя.
///
/// Любой непустой набор назначаем одиночным нажатием. Если это ровно одна
/// клавиша, окно настроек отдельно спросит согласие до сохранения.
void DictationBridge::OnCaptureTimeout() {
  if (!has_pending_capture_) return;
  has_pending_capture_ = false;
  const bool alone_is_enough =
      !pending_keys_.empty() || !pending_mods_.empty();
  if (alone_is_enough) {
    FinishCapture(pending_mods_, pending_keys_, 1);
  }
}

void DictationBridge::FinishCapture(const std::set<std::string>& mods,
                                    const std::vector<std::string>& keys,
                                    int taps) {
  is_capturing_ = false;
  capture_swallow_ = false;
  has_pending_capture_ = false;
  KillTimer(main_window_, ID_CAPTURE_TIMER);
  std::vector<std::string> modsList(mods.begin(), mods.end());
  SendCapturedHotkey(modsList, keys, taps);
}

LRESULT CALLBACK DictationBridge::LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  // Работает в потоке хука (см. hook_thread_). Здесь только снимок
  // события и ответ системе; разбор сочетаний — в главном потоке,
  // в ProcessKeyEvent, куда событие уходит сообщением.
  if (nCode == HC_ACTION) {
    auto& bridge = DictationBridge::GetInstance();
    auto* kbd = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    bool isDown = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
    bool isUp = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
    int vk = PhysicalModifierVk(*kbd);

    // Своё же Ctrl+V от вставки текста. Для перехватчика оно выглядит
    // как настоящее нажатие, и сочетание с Ctrl срабатывало бы от
    // собственной вставки. Чужие внедрённые нажатия при этом остаются
    // настоящими: переназначенная клавиша для человека такая же, как
    // обычная.
    if (kbd->dwExtraInfo == kOurInput) {
      return CallNextHookEx(nullptr, nCode, wParam, lParam);
    }

    // Правый Alt на раскладках с AltGr — а это и русская (AltGr+8 = «₽»),
    // и почти все европейские — приходит парой: система сама подкладывает
    // перед ним левый Ctrl со скан-кодом 0x21D и отпускает его перед
    // отпусканием Alt. Для перехватчика это выглядело как «Ctrl+Alt»:
    // «R Alt» совпадал лишь в миг отпускания фантомного Ctrl, то есть
    // в конце нажатия. «R Alt дважды» срабатывал только при очень быстрых
    // стуках (окно двойного считалось от конца первого нажатия до конца
    // второго), а «R Ctrl + R Alt» не совпадал вовсе, пока Alt держат.
    // Фантомный Ctrl пропускаем дальше, но в сочетания не считаем.
    // Настоящий левый Ctrl (скан-код 0x1D) по-прежнему считается.
    static bool altgr_ctrl_down = false;
    static bool real_left_ctrl_down = false;
    if (kbd->vkCode == VK_LCONTROL && (kbd->scanCode & 0x200) != 0) {
      if (isDown) altgr_ctrl_down = true;
      if (isUp) altgr_ctrl_down = false;
      return CallNextHookEx(nullptr, nCode, wParam, lParam);
    }
    if (vk == VK_LCONTROL) {
      if (isDown) real_left_ctrl_down = true;
      if (isUp) real_left_ctrl_down = false;
    }

    // Зажата ли клавиша — с поправкой на само это событие.
    //
    // Отсюда росли все три беды разом: «сработало не с первого раза»,
    // «пара секунд до начала записи» и «запись не заканчивается».
    // Низкоуровневый хук система зовёт ДО того, как обновит таблицу
    // состояний клавиш, — про клавишу самого события GetAsyncKeyState
    // отвечает по-старому. Поэтому Ctrl+Alt опознавалось не на нажатии
    // Alt, а на следующем событии клавиатуры, какое бы оно ни было:
    // не нажмёшь ничего ещё — запись не начнётся вовсе, а отпустишь —
    // не кончится. На macOS такого нет: CGEventTap отдаёт готовый
    // flags-снимок вместе с событием.
    //
    // Про клавишу события отвечаем сами, про остальные — как раньше.
    // Снимаем здесь, в мгновение события: главный поток доберётся до
    // него позже, когда клавиши могли уже отпустить.
    auto pressed = [](int k) { return (GetAsyncKeyState(k) & 0x8000) != 0; };
    auto held = [&](int k) -> bool {
      if (k != vk) {
        // Пока держится фантомный Ctrl от AltGr, таблица состояний считает
        // левый Ctrl нажатым — верим своему учёту настоящих нажатий.
        if (k == VK_LCONTROL && altgr_ctrl_down) return real_left_ctrl_down;
        return pressed(k);
      }
      if (isDown) return true;
      if (!isUp) return pressed(k);
      return false;
    };

    auto* event = new KeyEvent();
    event->vk = vk;
    event->down = isDown;
    event->up = isUp;
    event->time = GetTickCount64();
    for (int modifier : {VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU,
                         VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN}) {
      if (held(modifier)) event->mods.insert(ModifierName(modifier));
    }
    if (!PostMessageW(bridge.main_window_, WM_TSUKIKO_KEY, 0,
                      reinterpret_cast<LPARAM>(event))) {
      delete event;
    }

    // Пока в настройках назначают сочетание, его нажатия поглощаются:
    // набираемая буква не должна попасть в чужое поле. Отпускание
    // поглощаем у тех клавиш, чьё нажатие уже проглотили, — в том числе
    // когда захват кончился на этом самом наборе.
    // Отпускание до хука доходит не всегда: Ctrl+Alt+Del и Win+L уводят
    // его на защищённый рабочий стол. Поэтому новое нажатие той же
    // клавиши вне захвата закрывает старую запись — иначе следующий
    // обычный Ctrl+C потерял бы отпускание Ctrl, и он «залип» бы.
    static std::set<int> swallowed;
    if (isDown && bridge.capture_swallow_) {
      swallowed.insert(vk);
      return 1;
    }
    if (isDown) swallowed.erase(vk);
    if (isUp && swallowed.erase(vk) > 0) return 1;
  }
  return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

/// Разбор события клавиатуры — в главном потоке, где живут каналы
/// и состояние сочетаний. Сюда приходит снимок из потока хука.
void DictationBridge::ProcessKeyEvent(const KeyEvent& event) {
  auto& bridge = *this;
  const int vk = event.vk;
  const bool isDown = event.down;
  const bool isUp = event.up;

  auto isModifierVk = [](int k) {
    return k == VK_CONTROL || k == VK_LCONTROL || k == VK_RCONTROL ||
           k == VK_MENU || k == VK_LMENU || k == VK_RMENU ||
           k == VK_SHIFT || k == VK_LSHIFT || k == VK_RSHIFT ||
           k == VK_LWIN || k == VK_RWIN;
  };

  const std::set<std::string>& currentMods = event.mods;

  // Отпускание может не дойти до хука (Win+L, Ctrl+Alt+Del) и даже до самой
  // системы: GetAsyncKeyState тогда тоже считает клавишу зажатой. У настоящей
  // зажатой клавиши идёт автоповтор, у залипшей нет: молчащую забываем.
  constexpr ULONGLONG kStaleKeyMs = 5000;
  for (auto it = bridge.held_key_at_.begin(); it != bridge.held_key_at_.end();) {
    if (it->first != vk && event.time - it->second > kStaleKeyMs) {
      bridge.held_keys_.erase(it->first);
      it = bridge.held_key_at_.erase(it);
    } else {
      ++it;
    }
  }

  // В отличие от модификаторов, Windows не отдаёт снимок всех обычных
  // клавиш. Храним их края сами: иначе одиночный Ctrl продолжал бы
  // совпадать и внутри Ctrl+C, хотя пользователь разрешил только его.
  if (!isModifierVk(vk)) {
    if (isDown) {
      bridge.held_keys_.insert(vk);
      bridge.held_key_at_[vk] = event.time;
    }
    if (isUp) {
      bridge.held_keys_.erase(vk);
      bridge.held_key_at_.erase(vk);
    }
  }

  if (bridge.is_capturing_) {
    const ULONGLONG now = event.time;
    if (bridge.capture_started_at_ == 0 && (isDown || !currentMods.empty())) {
      bridge.capture_started_at_ = now;
    }
    if (isDown) {
      bridge.captured_mods_.insert(currentMods.begin(), currentMods.end());
      if (!isModifierVk(vk)) bridge.captured_keys_.insert(vk);
      // Само нажатие уже проглотил поток хука (см. capture_swallow_).
      return;
    }

    // Набор кончается отпусканием, и только им: у низкоуровневого хука
    // других событий не бывает, но полагаться на «раз не нажатие,
    // значит отпускание» — значит однажды посчитать набранным то,
    // чего не набирали.
    if (!isUp) return;

    // Всё отпущено — сочетание набрано. Пока держат, набор копится.
    const bool anythingHeld =
        !currentMods.empty() || !bridge.held_keys_.empty();
    if (anythingHeld ||
        (bridge.captured_keys_.empty() && bridge.captured_mods_.empty())) {
      return;
    }

    std::set<std::string> mods = bridge.captured_mods_;
    std::vector<std::string> keys;
    for (int k : bridge.captured_keys_) keys.push_back(VkToKeyName(k));
    std::sort(keys.begin(), keys.end());
    const bool quick = (now - bridge.capture_started_at_) < kTapMaxHoldMs;
    bridge.captured_mods_.clear();
    bridge.captured_keys_.clear();
    bridge.capture_started_at_ = 0;

    // Тот же набор во второй раз и вовремя — это двойное нажатие.
    if (bridge.has_pending_capture_ && bridge.pending_mods_ == mods &&
        bridge.pending_keys_ == keys) {
      bridge.FinishCapture(mods, keys, 2);
      return;
    }

    // Одна клавиша тоже годится; явное согласие на глобальный бинд
    // спрашивает окно настроек после захвата.
    const bool alone_is_enough = !keys.empty() || !mods.empty();

    // Затянувшееся нажатие вторым стуком уже не станет.
    if (!quick) {
      if (alone_is_enough) bridge.FinishCapture(mods, keys, 1);
      return;
    }

    // Короткий стук: ждём второго.
    bridge.has_pending_capture_ = true;
    bridge.pending_mods_ = mods;
    bridge.pending_keys_ = keys;
    SetTimer(bridge.main_window_, ID_CAPTURE_TIMER,
             static_cast<UINT>(kDoubleTapWindowMs), nullptr);
    return;
  }

  // Сопоставление с hold_spec_ и toggle_spec_
  auto containsSpec = [&](const HotkeySpec& spec) -> bool {
    if (spec.is_empty) return false;
    return ModifiersContain(currentMods, spec.mods) &&
           std::includes(bridge.held_keys_.begin(), bridge.held_keys_.end(),
                         spec.keys.begin(), spec.keys.end());
  };

  auto matchSpec = [&](const HotkeySpec& spec) -> bool {
    return containsSpec(spec) && ModifiersMatch(currentMods, spec.mods) &&
           bridge.held_keys_ == spec.keys;
  };

  // Сочетание зажато целиком, но сверху добавили лишнее.
  //
  // Нажать Ctrl+Alt+Shift разом физически нельзя: по дороге набор
  // проходит через Ctrl+Alt, и запись успевает начаться. Отпустить её
  // как обычное окончание нельзя — человек этого сочетания не назначал
  // и ничего не диктовал. Такое отпускание — отмена: записанное
  // выбрасывается, и панель уходит с экрана сразу.
  auto exceedsSpec = [&](const HotkeySpec& spec) -> bool {
    return containsSpec(spec) && !matchSpec(spec);
  };

  // Одно правило на все случаи, как и на macOS: сочетание работает,
  // когда зажаты ровно его модификаторы и его клавиши. Двойное
  // нажатие разбирает TapState — до второго стука оно не включает
  // ничего.
  const ULONGLONG now = event.time;

  if (bridge.hold_state_.Update(matchSpec(bridge.hold_spec_),
                                bridge.hold_spec_.is_double(),
                                containsSpec(bridge.hold_spec_), now)) {
    const bool active = bridge.hold_state_.active;
    const bool cancelled = !active && exceedsSpec(bridge.hold_spec_);
    bridge.SendHotkeyEvent("hold", active, cancelled);
    if (cancelled) bridge.hold_state_.SuppressUntilRelease();
  }

  // Отпускание само по себе ничего не переключает — оно лишь
  // разрешает следующему нажатию сработать. Кроме отмены: набрали
  // сверху лишнее — включённое той же клавишей выключается назад.
  if (bridge.toggle_state_.Update(matchSpec(bridge.toggle_spec_),
                                  bridge.toggle_spec_.is_double(),
                                  containsSpec(bridge.toggle_spec_), now)) {
    if (bridge.toggle_state_.active) {
      bridge.SendHotkeyEvent("toggle", true);
    } else if (exceedsSpec(bridge.toggle_spec_)) {
      bridge.SendHotkeyEvent("toggle", false, true);
      bridge.toggle_state_.SuppressUntilRelease();
    }
  }

  // «Бросить начатое» — одно нажатие, отпускание ничего не значит.
  // Не назначено — spec пуст, и matchSpec на нём всегда false.
  if (bridge.cancel_state_.Update(matchSpec(bridge.cancel_spec_),
                                  bridge.cancel_spec_.is_double(),
                                  containsSpec(bridge.cancel_spec_), now)) {
    if (bridge.cancel_state_.active) {
      bridge.SendHotkeyEvent("cancel", true);
    } else if (exceedsSpec(bridge.cancel_spec_)) {
      bridge.cancel_state_.SuppressUntilRelease();
    }
  }
}

void DictationBridge::SendHotkeyEvent(const std::string& id, bool down, bool cancel) {
  if (!DictationChannel()) return;
  flutter::EncodableMap map;
  map[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
  map[flutter::EncodableValue("down")] = flutter::EncodableValue(down);
  map[flutter::EncodableValue("cancel")] = flutter::EncodableValue(cancel);
  DictationChannel()->InvokeMethod(
      "hotkey", std::make_unique<flutter::EncodableValue>(map));
}

void DictationBridge::SendCapturedHotkey(const std::vector<std::string>& mods,
                                        const std::vector<std::string>& keys,
                                        int taps) {
  flutter::EncodableMap map;
  flutter::EncodableList modsList;
  for (const auto& m : mods) modsList.push_back(flutter::EncodableValue(m));
  flutter::EncodableList keysList;
  for (const auto& k : keys) keysList.push_back(flutter::EncodableValue(k));

  map[flutter::EncodableValue("mods")] = modsList;
  map[flutter::EncodableValue("keys")] = keysList;
  map[flutter::EncodableValue("taps")] = flutter::EncodableValue(taps);

  if (settings_channel_) {
    settings_channel_->InvokeMethod("captured", std::make_unique<flutter::EncodableValue>(map));
  }
  if (channel_) {
    channel_->InvokeMethod("captured", std::make_unique<flutter::EncodableValue>(map));
  }
  if (panel_channel_) {
    panel_channel_->InvokeMethod("captured", std::make_unique<flutter::EncodableValue>(map));
  }
}

/// Переспросить сторону диктовки и отдать её ответ тому, кто спросил.
///
/// Панели нет — отвечаем [fallback]: без неё нет и диктовки, а значит
/// и модели в памяти.
void DictationBridge::ForwardToPanel(
    const std::string& method,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    flutter::EncodableValue fallback) {
  std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared(
      result.release());
  if (!panel_channel_) {
    shared->Success(fallback);
    return;
  }
  panel_channel_->InvokeMethod(
      method, nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [shared, fallback](const flutter::EncodableValue* answer) {
            shared->Success(answer ? *answer : fallback);
          },
          [shared, fallback](const std::string&, const std::string&,
                             const flutter::EncodableValue*) {
            shared->Success(fallback);
          },
          [shared, fallback]() { shared->Success(fallback); }));
}

/// Окно настроек по требованию: движок поднимается при первом открытии
/// и дальше живёт — сто мегабайт против мгновенного открытия.
void DictationBridge::ShowSettings(const std::string& tab) {
  settings_tab_ = tab;
  if (!project_) {
    ShowMainWindow();
    return;
  }
  if (!settings_) settings_ = std::make_unique<SettingsWindow>();
  settings_->Show(*project_, [this](flutter::BinaryMessenger* messenger) {
    settings_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "tsukiko/dictation",
            &flutter::StandardMethodCodec::GetInstance());
    RegisterHandler(settings_channel_.get());
  });
  // Окно уже было открыто — просто просим его перейти на нужную вкладку.
  if (settings_channel_) {
    settings_channel_->InvokeMethod(
        "tab", std::make_unique<flutter::EncodableValue>(tab));
  }
}

/// Показать или убрать плавающую панель записи и сказать ей, что
/// показывать.
///
/// Движок под неё поднимается при первом показе: панель приходит только
/// во время диктовки, а до тех пор держать ради неё сто мегабайт незачем.
void DictationBridge::SendHudLayout() {
  flutter::EncodableMap layout = hud_layout_labels_;
  layout[flutter::EncodableValue("editing")] = flutter::EncodableValue(hud_ && hud_->editing());
  layout[flutter::EncodableValue("scaleValue")] = flutter::EncodableValue(hud_ ? hud_->scale() : 1.0);
  layout[flutter::EncodableValue("mode")] = flutter::EncodableValue(hud_ ? hud_->mode() : "panel");
  for (auto* channel : {hud_channel_.get(), hud_editor_channel_.get()}) if (channel) {
    channel->InvokeMethod("hudLayout", std::make_unique<flutter::EncodableValue>(layout));
  }
}

void DictationBridge::NotifyHudMode() {
  if (hud_) DictationChannel()->InvokeMethod("hudMode", std::make_unique<flutter::EncodableValue>(hud_->mode()));
}

void DictationBridge::PrewarmHud() {
  if (!project_ || hud_) return;
  hud_ = std::make_unique<HudWindow>();
  hud_->Prepare(*project_, [this](flutter::BinaryMessenger* messenger) {
    hud_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "tsukiko/dictation",
            &flutter::StandardMethodCodec::GetInstance());
    RegisterHandler(hud_channel_.get());
    SendHudLayout();
    if (current_hud_state_ != "hidden") {
      hud_channel_->InvokeMethod(
          "hudState",
          std::make_unique<flutter::EncodableValue>(current_hud_state_));
    }
  });
}

void DictationBridge::SetHudState(const std::string& state) {
  // The argument can alias current_hud_state_; keep a value before modifying it.
  std::string next = state;
  current_hud_state_ = next;
  PrewarmHud();
  if (hud_) hud_->SetQueue(HudBacklogCount(next == "recording",
      IntArgument(hud_queue_, "pending"), BoolArgument(hud_queue_, "processing")) > 0);
  if (hud_channel_) hud_channel_->InvokeMethod("hudState", std::make_unique<flutter::EncodableValue>(next));
  if (hud_ && project_) {
    if ((hud_->editing() || next != "hidden") && hud_->floating()) hud_->Show(*project_, [this](flutter::BinaryMessenger*) {});
    else hud_->Hide();
  }
  UpdateTrayIndicator();
  KillTimer(main_window_, ID_HUD_TIMER);
  UINT linger = 0;
  if (next == "done") linger = 700;
  if (next == "cancelled") linger = 2200;
  if (next == "failed" || next == "copied") linger = 2600;
  if (next == "silent") linger = 1800;
  if (linger) SetTimer(main_window_, ID_HUD_TIMER, linger, nullptr);
}

void DictationBridge::SendReloadSettings() {
  // Настройки правит одно окно, а знать о правке должны все: у каждого
  // своя копия в своём изоляте.
  if (channel_) channel_->InvokeMethod("reload", nullptr);
  if (panel_channel_) panel_channel_->InvokeMethod("reload", nullptr);
  if (settings_channel_) settings_channel_->InvokeMethod("reload", nullptr);
  // Панели записи тоже: язык и тему она берёт из тех же настроек, и без
  // «reload» оставалась бы с прежними до перезапуска приложения.
  if (hud_channel_) hud_channel_->InvokeMethod("reload", nullptr);
  if (hud_editor_channel_) hud_editor_channel_->InvokeMethod("reload", nullptr);
}

void DictationBridge::SendTab(const std::string& tab) {
  if (!channel_) return;
  channel_->InvokeMethod("tab", std::make_unique<flutter::EncodableValue>(tab));
}

void DictationBridge::ResetKeyState() {
  held_keys_.clear();
  held_key_at_.clear();
  hold_state_ = TapState{};
  toggle_state_ = TapState{};
  cancel_state_ = TapState{};
}

void DictationBridge::SendSystemSleep() {
  if (channel_) channel_->InvokeMethod("systemSleep", nullptr);
  if (panel_channel_) panel_channel_->InvokeMethod("systemSleep", nullptr);
  if (settings_channel_) settings_channel_->InvokeMethod("systemSleep", nullptr);
}

void DictationBridge::SendSystemWake() {
  if (channel_) channel_->InvokeMethod("systemWake", nullptr);
  if (panel_channel_) panel_channel_->InvokeMethod("systemWake", nullptr);
  if (settings_channel_) settings_channel_->InvokeMethod("systemWake", nullptr);
}

// ── Аудио запись через miniaudio ──────────────────────────────────────────

void DictationBridge::StartAudioRecording(
    std::function<void(const std::string&)> done) {
  SettleMicStart();
  if (is_recording_) {
    StopAudioRecording();
  }

  wchar_t tempPath[MAX_PATH];
  GetTempPathW(MAX_PATH, tempPath);
  auto now = std::chrono::system_clock::now().time_since_epoch().count();
  static uint64_t sequence = 0;
  std::wstring fileW = std::wstring(tempPath) + L"tsukiko_record_" + std::to_wstring(now) + L"_" + std::to_wstring(++sequence) + L".wav";
  current_record_path_ = WideToUtf8(fileW);

  auto* encoder = new ma_encoder();
  ma_encoder_config encConfig = ma_encoder_config_init(ma_encoding_format_wav, ma_format_s16, 1, 16000);
  if (ma_encoder_init_file(current_record_path_.c_str(), &encConfig, encoder) != MA_SUCCESS) {
    delete encoder;
    done("");
    return;
  }
  ma_encoder_ = encoder;
  // Поток устройства ещё не запущен, так что счётчик сбрасываем без гонки.
  warmup_frames_ = 0;
  mic_live_.store(false);

  if (HANDLE old = audio_ready_event_.exchange(nullptr)) CloseHandle(old);
  HANDLE ready_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  audio_ready_event_.store(ready_event);
  if (!ready_event) {
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
    done("");
    return;
  }

  auto start = std::make_shared<MicStart>();
  start->done = std::move(done);
  mic_start_ = start;
  HWND notify = main_window_;
  ma_context* context = AudioContext();
  mic_thread_ = std::thread([this, start, notify, context]() {
    // У потока свой MTA на время запуска. Контекст общий и создан на
    // главном потоке: иначе свой контекст устройства при ma_device_uninit
    // (уже на главном) звал бы CoUninitialize без пары и снимал бы
    // OleInitialize главного потока.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    auto* device = new ma_device();
    ma_device_config devConfig = ma_device_config_init(ma_device_type_capture);
    devConfig.capture.format = ma_format_s16;
    devConfig.capture.channels = 1;
    devConfig.sampleRate = 16000;
    devConfig.dataCallback = AudioCaptureCallback;
    devConfig.pUserData = this;

    bool ok = ma_device_init(context, &devConfig, device) == MA_SUCCESS;
    if (ok && ma_device_start(device) != MA_SUCCESS) {
      ma_device_uninit(device);
      ok = false;
    }
    if (!ok) {
      delete device;
      device = nullptr;
    }
    start->device = device;
    start->ok = ok;
    auto* message = new std::shared_ptr<MicStart>(start);
    if (!PostMessageW(notify, WM_TSUKIKO_MIC, 0,
                      reinterpret_cast<LPARAM>(message))) {
      delete message;
    }
    if (SUCCEEDED(com)) CoUninitialize();
  });
}

// Один контекст miniaudio на процесс, созданный на главном потоке. Там COM
// уже STA (OleInitialize), MTA-инициализация контекста получает
// RPC_E_CHANGED_MODE, и CoUninitialize он не зовёт ни при каком разборе.
// nullptr — пусть устройство заводит свой, как раньше.
ma_context* DictationBridge::AudioContext() {
  static ma_context context;
  static const bool ready = ma_context_init(nullptr, 0, nullptr, &context) == MA_SUCCESS;
  return ready ? &context : nullptr;
}

void DictationBridge::SettleMicStart() {
  if (mic_thread_.joinable()) mic_thread_.join();
  if (mic_start_) CompleteMicStart(mic_start_);
}

void DictationBridge::CompleteMicStart(const std::shared_ptr<MicStart>& start) {
  // Сообщение из потока могло прийти уже после того, как запуск довели
  // до конца сами (остановкой или новым запуском): второй раз не отвечаем.
  if (start->handled) return;
  start->handled = true;
  if (mic_thread_.joinable()) mic_thread_.join();
  if (mic_start_ == start) mic_start_.reset();
  auto done = std::move(start->done);
  if (start->ok) {
    ma_device_ = start->device;
    is_recording_ = true;
    ResetLevelMeter();
    if (done) done(current_record_path_);
    return;
  }
  if (ma_encoder_) {
    auto* encoder = static_cast<ma_encoder*>(ma_encoder_);
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
  }
  if (HANDLE ready = audio_ready_event_.exchange(nullptr)) CloseHandle(ready);
  if (done) done("");
}

std::string DictationBridge::StopAudioRecording() {
  SettleMicStart();
  if (!is_recording_) return current_record_path_;

  // ma_device_start сообщает только о запуске устройства, не о том, что
  // WASAPI уже отдал звук. Быстрое отпускание клавиши раньше закрывало
  // устройство в этой щели и оставляло WAV без единого отсчёта. Ждём не
  // произвольную задержку, а ровно первый callback; таймаут нужен для
  // физически исчезнувшего или зависшего микрофона.
  if (HANDLE ready = audio_ready_event_.load()) WaitForSingleObject(ready, 500);
  is_recording_ = false;
  if (ma_device_) {
    auto* device = static_cast<ma_device*>(ma_device_);
    ma_device_stop(device);
    ma_device_uninit(device);
    delete device;
    ma_device_ = nullptr;
  }
  if (ma_encoder_) {
    auto* encoder = static_cast<ma_encoder*>(ma_encoder_);
    ma_encoder_uninit(encoder);
    delete encoder;
    ma_encoder_ = nullptr;
  }
  if (HANDLE ready = audio_ready_event_.exchange(nullptr)) CloseHandle(ready);

  ResetLevelMeter();
  return current_record_path_;
}

/// Уровень для индикатора — та же шкала, что и на macOS (Dictation.swift,
/// currentLevel). Это не перевод формулы наугад, а перенос её смысла:
/// децибелы вместо сырой амплитуды, точка отсчёта по фону комнаты и
/// баллистика VU-метра.
///
/// Прежде здесь стоял `max(|отсчёт|) / 32768` — сырая линейная амплитуда.
/// Обычная речь по амплитуде это сотые-десятые доли единицы, то есть
/// полоска поднималась на проценты от высоты, и хозяину приходилось
/// кричать, чтобы её увидеть. На macOS та же речь занимает почти всю
/// шкалу, потому что там считается вот это.
///
/// Считаем здесь, в потоке звукового устройства, а не по запросу из Dart:
/// длительность порции известна точно (кадры делить на частоту), а
/// опрашивают уровень панель и поповер с разной частотой — сглаживание
/// по числу вызовов разъезжалось бы вместе с ней.
void DictationBridge::PushAudioFrames(const int16_t* samples, uint32_t frames,
                                      uint32_t sample_rate) {
  if (!samples || frames == 0 || sample_rate == 0) return;

  // Callback пишет в encoder до этого вызова (см. AudioCaptureCallback),
  // поэтому сигнал означает не просто «устройство ожило», а «в WAV уже
  // попал хотя бы один блок, его можно безопасно закрывать».
  if (HANDLE ready = audio_ready_event_.load()) SetEvent(ready);

  if (!mic_live_.load(std::memory_order_relaxed)) {
    bool sound = false;
    for (uint32_t i = 0; i < frames && !sound; ++i) sound = samples[i] != 0;
    warmup_frames_ += frames;
    if (sound || warmup_frames_ >= sample_rate) mic_live_.store(true);
  }

  // Среднеквадратичное, а не пиковое: на macOS берётся averagePower —
  // средняя мощность за промежуток. По пику речь и щелчок мышью выглядят
  // одинаково, по средней — нет.
  double sum = 0.0;
  for (uint32_t i = 0; i < frames; ++i) {
    const double v = static_cast<double>(samples[i]) / 32768.0;
    sum += v * v;
  }
  const double rms = std::sqrt(sum / frames);

  // Ниже −60 дБ считать нечего: это уже не комната, а цифровая тишина,
  // и фон, уехавший туда, растянул бы шкалу до бессмыслицы. Заодно это
  // спасает от log10(0) на выключенном микрофоне.
  double db = rms > 1e-6 ? 20.0 * std::log10(rms) : -60.0;
  if (db < -60.0) db = -60.0;

  const double dt = static_cast<double>(frames) / sample_rate;

  // Фон комнаты: вниз оценка идёт быстро, вверх — медленно, а громче
  // порога — почти никак. Иначе речь сама поднимает фон, от которого её
  // же и отсчитывают, и индикатор оседает за несколько секунд разговора.
  if (!has_noise_floor_) {
    noise_floor_db_ = std::min(static_cast<float>(db), -45.0f);
    has_noise_floor_ = true;
  }
  const double was = noise_floor_db_;
  const double floor_tau = db < was ? 0.5 : (db < was + 6.0 ? 3.0 : 60.0);
  const double floor = was + (db - was) * (1.0 - std::exp(-dt / floor_tau));
  noise_floor_db_ = static_cast<float>(floor);

  // Окно под речь, а не под весь тракт. Порог — 4 дБ над фоном (дыхание
  // и вентилятор остаются внизу), потолок — 22 дБ над ним, но не ниже
  // −14 дБ: в очень тихой комнате фон уезжает так низко, что от него
  // любая речь упиралась бы в верх шкалы.
  const double bottom = floor + 4.0;
  const double top = std::max(floor + 22.0, -14.0);
  double target = (db - bottom) / (top - bottom);
  if (target < 0.0) target = 0.0;
  if (target > 1.0) target = 1.0;

  // Баллистика: атака 20 мс, спад 300 мс. Быстрее атака — метр дрожит,
  // короче спад — глаз не успевает за всплесками; 300 мс — время
  // интеграции обычного VU-метра, к нему привыкло восприятие.
  const double tau = target > meter_level_ ? 0.02 : 0.3;
  const double level =
      meter_level_ + (target - meter_level_) * (1.0 - std::exp(-dt / tau));
  meter_level_ = static_cast<float>(level);
  current_level_ = meter_level_;
}

double DictationBridge::GetAudioLevel() {
  return static_cast<double>(current_level_);
}

// ── Вставка текста ─────────────────────────────────────────────────────────

namespace {

/// Открыть буфер обмена, не сдаваясь с первой попытки.
///
/// Буфер — вещь общая на всю систему, и держать его может кто угодно:
/// браузер, менеджер буфера, соседнее окно. Отказ с первой попытки
/// означал бы «текст пропал», хотя ждать надо было двадцать миллисекунд.
bool OpenClipboardPatiently(HWND owner) {
  for (int i = 0; i < 12; ++i) {
    if (OpenClipboard(owner)) return true;
    Sleep(20);
  }
  return false;
}

}  // namespace

/// Вставить текст в чужое окно через буфер обмена и Ctrl+V.
/// Текст остаётся в буфере обмена (CF_UNICODETEXT), чтобы целевые
/// приложения успели его прочитать и пользователь мог использовать его повторно.
bool DictationBridge::PasteText(const std::string& text) {
  if (hud_ && hud_->editing()) return false;
  if (hud_ && hud_->editing()) return false;
  if (text.empty()) return true;

  if (!OpenClipboardPatiently(main_window_)) return false;

  EmptyClipboard();

  std::wstring wtext = Utf8ToWide(text);
  size_t bytes = (wtext.size() + 1) * sizeof(wchar_t);
  HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!hMem) {
    CloseClipboard();
    return false;
  }

  void* dst = GlobalLock(hMem);
  if (!dst) {
    GlobalFree(hMem);
    CloseClipboard();
    return false;
  }
  memcpy(dst, wtext.c_str(), bytes);
  GlobalUnlock(hMem);
  if (!SetClipboardData(CF_UNICODETEXT, hMem)) {
    // Не приняли — память наша, и освобождать её тоже нам.
    GlobalFree(hMem);
    CloseClipboard();
    return false;
  }
  CloseClipboard();

  // Человек мог ещё держать сочетание диктовки: на Windows это
  // Ctrl+Alt или Ctrl+Shift+Пробел. Отпустить их надо самим, иначе
  // получатель увидит не Ctrl+V, а Ctrl+Alt+V — и не вставит ничего.
  std::vector<INPUT> inputs;
  auto key = [&](WORD vk, bool up) {
    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    in.ki.dwExtraInfo = kOurInput;
    inputs.push_back(in);
  };
  // int, а не WORD: константы VK_* в заголовках Windows — обычные int,
  // и вывод типа списка на WORD ругается потерей точности.
  for (int vk : {VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN}) {
    if (GetAsyncKeyState(vk) & 0x8000) key(static_cast<WORD>(vk), true);
  }
  key(VK_CONTROL, false);
  key('V', false);
  key('V', true);
  key(VK_CONTROL, true);

  return SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT)) == inputs.size();
}

void DictationBridge::RestoreClipboard() {
  // No-op: CF_UNICODETEXT intentionally left in clipboard to prevent
  // corruption and allow target apps / user reliable access.
}

// ── Корзина и автозапуск ───────────────────────────────────────────────────

bool DictationBridge::MoveToTrash(const std::string& path) {
  std::wstring wpath = Utf8ToWide(path);
  wpath.push_back(L'\0'); // Двойной нулевой терминатор для SHFileOperation

  SHFILEOPSTRUCTW op = {};
  op.hwnd = main_window_;
  op.wFunc = FO_DELETE;
  op.pFrom = wpath.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT;

  int result = SHFileOperationW(&op);
  return result == 0 && !op.fAnyOperationsAborted;
}

bool DictationBridge::GetLoginItemEnabled() {
  HKEY hKey;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  bool exists = (RegQueryValueExW(hKey, L"tsukiko", nullptr, &type, nullptr, nullptr) == ERROR_SUCCESS);
  RegCloseKey(hKey);
  return exists;
}

bool DictationBridge::SetLoginItemEnabled(bool enabled) {
  HKEY hKey;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, KEY_WRITE, &hKey) != ERROR_SUCCESS) {
    return false;
  }
  bool success = false;
  if (enabled) {
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(exePath) + L"\" --login-item";
    DWORD bytes = static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t));
    success = (RegSetValueExW(hKey, L"tsukiko", 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()), bytes) == ERROR_SUCCESS);
  } else {
    success = (RegDeleteValueW(hKey, L"tsukiko") == ERROR_SUCCESS);
  }
  RegCloseKey(hKey);
  return success;
}
