#pragma once

#include <flutter/binary_messenger.h>
#include <flutter/dart_project.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <set>
#include <functional>

/// Мост к родному коду Windows: глобальный перехват клавиш, запись звука,
/// вставка текста, Корзина, автозапуск и значок в системном трее.
///
/// Полный аналог Dictation.swift на macOS, отвечающий на тот же канал
/// 'tsukiko/dictation' и посылающий те же события в Dart.
class PanelWindow;
class SettingsWindow;
class HudWindow;

class DictationBridge {
 public:
  static DictationBridge& GetInstance();

  void Initialize(flutter::BinaryMessenger* messenger, HWND window_handle);

  /// Завести канал на движке панели. Именно её сторона ведёт диктовку,
  /// поэтому события клавиш и назначения уходят туда, а не в очередь.
  void AttachPanel(flutter::BinaryMessenger* messenger, PanelWindow* panel);

  /// Проект Flutter нужен, чтобы поднять движок настроек по требованию:
  /// окно открывают редко, а сто мегабайт оно держит всегда.
  void SetDartProject(const flutter::DartProject* project) {
    project_ = project;
  }
  void Shutdown();

  // Обработка сообщений Win32 для трея и горячих клавиш
  bool HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // Вызовы из Dart
  void SendHotkeyEvent(const std::string& id, bool down, bool cancel = false);
  void SendCapturedHotkey(const std::vector<std::string>& mods,
                          const std::vector<std::string>& keys,
                          int taps);
  void SendReloadSettings();
  void SendTab(const std::string& tab);
  void SendSystemSleep();
  void SendSystemWake();
  void ResetKeyState();

  void* GetEncoder() const { return ma_encoder_; }

  /// Пересчитать индикатор уровня по очередной порции звука.
  ///
  /// Зовётся из потока звукового устройства — там, где порция и её
  /// длительность известны точно. Считать по времени вызовов из Dart
  /// нельзя: панель и поповер опрашивают уровень с разной частотой.
  void PushAudioFrames(const int16_t* samples, uint32_t frames,
                       uint32_t sample_rate);

  /// Забыть комнату. Комната у каждой записи своя: с оценкой фона от
  /// прошлого раза индикатор первые секунды врал бы.
  void ResetLevelMeter() {
    current_level_ = 0.0f;
    meter_level_ = 0.0f;
    noise_floor_db_ = -50.0f;
    has_noise_floor_ = false;
  }

 private:
  DictationBridge();
  ~DictationBridge();

  void RegisterMethodChannel();
  void SetupTrayIcon();
  void RemoveTrayIcon();
  void ShowContextMenu();

  // Клавиатурный хук
  void InstallKeyboardHook();
  void UninstallKeyboardHook();
  static LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam);

  // Запись аудио
  std::string StartAudioRecording();
  std::string StopAudioRecording();
  double GetAudioLevel();

  // Вставка текста и буфер обмена
  bool PasteText(const std::string& text);

  // Корзина и автозапуск
  bool MoveToTrash(const std::string& path);
  bool GetLoginItemEnabled();
  bool SetLoginItemEnabled(bool enabled);

  // Окна
  void ShowMainWindow();
  void ToggleMainWindow();

  HWND main_window_ = nullptr;
  /// Канал главного окна и канал панели. Обработчик у них один —
  /// спрашивать умеют обе стороны, — а вот события ходят по-разному:
  /// клавиши и панель касаются только диктовки, а «перечитать настройки»
  /// касается всех.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> panel_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> settings_channel_;
  PanelWindow* panel_ = nullptr;
  const flutter::DartProject* project_ = nullptr;
  std::unique_ptr<SettingsWindow> settings_;
  std::unique_ptr<HudWindow> hud_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> hud_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> hud_editor_channel_;
  flutter::EncodableMap hud_queue_;
  flutter::EncodableMap hud_layout_labels_;
  void SendHudLayout();
  void UpdateTrayIndicator();
  void NotifyHudMode();
  std::string current_hud_state_ = "hidden";

  void SetHudState(const std::string& state);

  /// С какой вкладки открыть настройки. Спрашивает их изолят сразу после
  /// старта: пока он не подписался на канал, посланное ему теряется.
  std::string settings_tab_ = "dictation";

  void ShowSettings(const std::string& tab);

  /// Куда слать то, что касается диктовки. Панели ещё нет — пусть идёт
  /// в главное окно: молчать хуже, чем сказать не туда.
  flutter::MethodChannel<flutter::EncodableValue>* DictationChannel() const {
    return panel_channel_ ? panel_channel_.get() : channel_.get();
  }

  void RegisterHandler(flutter::MethodChannel<flutter::EncodableValue>* channel);

  void KillDictationServer();
  void SetTaskbarButtonVisible(bool visible);

  /// Поднять движок плавающей панели записи заранее, не показывая её.
  ///
  /// Панель — четвёртый движок Flutter, и поднимался он в ответ на первое
  /// нажатие клавиши диктовки: новый изолят, снимок приложения и первый
  /// кадр — всё на том же потоке, что разбирает сообщения окна. Первая
  /// диктовка после запуска этим и оплачивалась, и ждать приходилось
  /// заметно. Теперь это делается один раз, когда приложение уже
  /// поднялось и никто ничего не ждёт.
  void PrewarmHud();

  void RestoreClipboard();

  /// Погасить движок расшифровки, записанный очередью. См. .cpp.
  void KillRecognizer();

  /// Что мы уже сделали с кнопкой на панели задач. Пусто — ещё ничего:
  /// первый вызов всегда применяется, а повторный с тем же значением
  /// пропускается. Иначе окно пряталось и показывалось на каждой правке
  /// настроек — см. SetTaskbarButtonVisible.
  std::optional<bool> taskbar_button_visible_;

  void ForwardToPanel(
      const std::string& method,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      flutter::EncodableValue fallback);
  NOTIFYICONDATAW tray_data_ = {};
  bool tray_installed_ = false;
  HICON recording_icon_ = nullptr;
  HHOOK keyboard_hook_ = nullptr;

  // Состояние хоткеев
  struct HotkeySpec {
    std::set<std::string> mods;
    std::set<int> keys;
    int taps = 1;
    bool is_empty = true;

    bool is_double() const { return taps >= 2; }
  };

  /// Что происходит с одним сочетанием.
  ///
  /// Память о нажатии нужна затем же, зачем и на macOS: без неё каждое
  /// событие, где набор снова совпал, считалось бы новым нажатием — и
  /// у переключателя это стоило бы записи.
  ///
  /// Двойное нажатие живёт здесь же: первый короткий стук ничего
  /// не включает, он только взводит; включает второе нажатие, если оно
  /// пришло вовремя. Для «держать и говорить» это привычный жест
  /// «стук, стук-и-держать».
  struct TapState {
    bool active = false;
    bool suppressed = false;
    ULONGLONG pressed_at = 0;
    ULONGLONG armed_at = 0;

    /// true, когда «сочетание работает» изменилось на этом событии.
    bool Update(bool raw, bool is_double, bool base_held, ULONGLONG now);
    void SuppressUntilRelease();
  };

  /// За сколько должен уложиться второй стук, и с какого мгновения
  /// нажатие считается удержанием, а не стуком. Числа те же, что
  /// на macOS: короче — не успеть, длиннее — два независимых нажатия
  /// начнут слипаться в одно двойное.
  static constexpr ULONGLONG kDoubleTapWindowMs = 400;
  static constexpr ULONGLONG kTapMaxHoldMs = 250;

  HotkeySpec hold_spec_;
  HotkeySpec toggle_spec_;

  /// Обычные клавиши, которые сейчас физически зажаты. Нужны для строгого
  /// совпадения: один Ctrl перестаёт быть одиночным хоткеем в ту же
  /// миллисекунду, когда рядом нажали C или любую другую клавишу.
  std::set<int> held_keys_;

  /// «Бросить начатое». Может остаться пустым: это единственное сочетание,
  /// которое разрешено не назначать вовсе.
  HotkeySpec cancel_spec_;
  bool is_capturing_ = false;
  std::set<std::string> captured_mods_;
  std::set<int> captured_keys_;
  ULONGLONG capture_started_at_ = 0;

  /// Набор, отпущенный коротким стуком и ждущий второго. Дождались —
  /// это двойное нажатие; не дождались — по таймеру назначаем одиночным.
  bool has_pending_capture_ = false;
  std::set<std::string> pending_mods_;
  std::vector<std::string> pending_keys_;

  void FinishCapture(const std::set<std::string>& mods,
                     const std::vector<std::string>& keys, int taps);
  void OnCaptureTimeout();
  TapState hold_state_;
  TapState toggle_state_;
  TapState cancel_state_;

  // Аудио запись
  void* ma_device_ = nullptr;
  void* ma_encoder_ = nullptr;
  /// Первый блок звука уже записан. Короткое нажатие может отпуститься
  /// раньше первого вызова WASAPI; тогда перед закрытием устройства ждём
  /// этот сигнал и не оставляем один пустой WAV-заголовок.
  std::atomic<HANDLE> audio_ready_event_{nullptr};
  std::string current_record_path_;

  /// Готовый уровень индикатора, 0…1, и внутренности его расчёта:
  /// оценка фона комнаты в децибелах и сглаженный уровень. Смысл каждого
  /// числа разобран у PushAudioFrames в .cpp — там же, где формулы.
  float current_level_ = 0.0f;
  float meter_level_ = 0.0f;
  float noise_floor_db_ = -50.0f;
  bool has_noise_floor_ = false;
  bool is_recording_ = false;
};
