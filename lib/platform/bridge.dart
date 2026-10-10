import 'dart:async';
import 'dart:io' show stderr;
import 'dart:math' show max;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../core/app_locale.dart';
import '../core/whisper_server.dart';

/// Мост к родному коду приложения: перехват клавиш, запись с микрофона,
/// вставка текста, окна и панель у строки меню.
///
/// Этот файл платформы не знает: он весь — один MethodChannel, и на любой
/// системе выглядит одинаково. Разница живёт на той стороне канала:
/// сейчас это Swift (`macos/Runner`), на Windows будет C++ (`windows/runner`),
/// который должен отвечать на те же имена методов и слать те же события.
/// Отдельных реализаций в Dart для этого не нужно — и раньше здесь стояли
/// четыре абстрактных класса, у которых была ровно одна реализация и ни
/// одного места, где они использовались бы как типы.
///
/// То, что по-разному делается в самом Dart — пути, процессы, звук, —
/// живёт не здесь, а за границей `os.dart`.

/// Что случилось с назначенной клавишей.
enum HotkeyEdge { down, up }

class HotkeyEvent {
  const HotkeyEvent(this.id, this.edge, {this.cancel = false});

  /// 'hold', 'toggle' или 'cancel' — какое из сочетаний сработало.
  final String id;
  final HotkeyEdge edge;

  /// Сочетание разошлось не отпусканием, а лишней клавишей поверх:
  /// начатое надо не заканчивать, а отменять.
  final bool cancel;
}

/// Что показывает плавающая панель записи.
///
/// [failed] — записи не стало текстом, и она спасена в файл. [copied] —
/// текст есть, но вставить его в чужое окно не вышло, и он ждёт в буфере
/// обмена. [cancelled] — распознавание прервали сами, запись сохранена.
/// [silent] — записывать было нечего: клавишу отпустили раньше, чем
/// микрофон отдал первый отсчёт. Разные исходы, и подпись у них разная:
/// «не вставилось, текст в буфере» после пустой записи было бы прямой
/// неправдой, а молчание — обещанием, что всё вышло.
enum HudState {
  hidden,
  recording,
  transcribing,
  done,
  failed,
  copied,
  cancelled,
  silent,
}

/// Диктовки перед текущей записью; при распознавании сама текущая не считается.
int hudBacklogCount(HudState state, int pending, bool processing) {
  final outstanding = max(0, pending) + (processing ? 1 : 0);
  return max(0, outstanding - (state == HudState.recording ? 0 : 1));
}

/// Один канал на всё приложение.
///
/// Экземпляр должен быть один на изолят: конструктор вешает обработчик
/// на общий канал, и второй экземпляр молча отобрал бы его у первого.
class NativeBridge {
  NativeBridge() {
    assert(() {
      if (_installed) {
        throw StateError(
          'NativeBridge создан дважды в одном изоляте: '
          'второй экземпляр отбирает обработчик канала у первого.',
        );
      }
      _installed = true;
      return true;
    }());
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('tsukiko/dictation');

  /// Только для проверки в отладке — см. конструктор.
  static bool _installed = false;

  /// Забыть, что мост уже создавали. Нужно тестам: каждый берёт свежий
  /// мост, а в приложении он один на изолят и на весь запуск.
  @visibleForTesting
  static void debugReset() => _installed = false;

  final _hotkeys = StreamController<HotkeyEvent>.broadcast();
  final _shown = StreamController<void>.broadcast();
  final _hidden = StreamController<void>.broadcast();
  final _hudActions = StreamController<String>.broadcast();
  final _systemSleep = StreamController<void>.broadcast();
  final _systemWake = StreamController<void>.broadcast();

  /// Состояние плавающей панели записи. Слушает её собственный изолят —
  /// тот, что её рисует. На macOS панель нарисована на SwiftUI, и этот
  /// поток там пуст: состояние ей передаёт родная сторона напрямую.
  final _hudStates = StreamController<HudState>.broadcast();
  final _hudModes = StreamController<String>.broadcast();
  Stream<String> get hudModes => _hudModes.stream;
  final _hudLayout = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get hudLayout => _hudLayout.stream;
  Future<Map<String, dynamic>> currentHudLayout() async =>
      await _channel.invokeMapMethod<String, dynamic>('getHudLayout') ?? {};
  Future<void> configureHud(Map<String, String> labels) =>
      _channel.invokeMethod('configureHud', labels);
  Future<void> resetHud() => _channel.invokeMethod('resetHud');
  Future<void> changeHudLayout(Map<String, dynamic> changes) =>
      _channel.invokeMethod('hudLayout', changes);

  final _hudQueue = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get hudQueue => _hudQueue.stream;
  Future<Map<String, dynamic>> currentHudQueue() async =>
      await _channel.invokeMapMethod<String, dynamic>('getHudQueue') ?? {};

  final _reload = StreamController<void>.broadcast();
  final _tab = StreamController<String>.broadcast();
  Completer<Hotkey?>? _capture;

  /// Спросили, чем занята диктовка, и попросили освободить память.
  /// Отвечает сторона диктовки: только она знает, говорит ли человек
  /// прямо сейчас. Нет обработчика — значит это не она, и отвечать некому.
  String Function()? onStatusAsked;
  Future<void> Function()? onReleaseAsked;
  Future<void> Function(bool active)? onCalibrationActive;
  Future<Map<String, dynamic>> Function(Map<String, dynamic> request)?
  onWakeDiagnostics;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'hotkey':
        final a = (call.arguments as Map).cast<String, dynamic>();
        _hotkeys.add(
          HotkeyEvent(
            a['id'] as String,
            a['down'] as bool ? HotkeyEdge.down : HotkeyEdge.up,
            cancel: (a['cancel'] as bool?) ?? false,
          ),
        );
      case 'captured':
        final a = (call.arguments as Map).cast<String, dynamic>();
        _capture?.complete(
          Hotkey(
            (a['mods'] as List).map((e) => '$e').toList(),
            keys: ((a['keys'] as List?) ?? const []).map((e) => '$e').toList(),
            taps: (a['taps'] as num?)?.toInt() ?? 1,
          ),
        );
        _capture = null;
      case 'panelShown':
        _shown.add(null);
      case 'panelHidden':
        _hidden.add(null);
      case 'hud':
        _hudActions.add(call.arguments as String);
      case 'hudMode':
        _hudModes.add(call.arguments as String);
      case 'hudLayout':
        _hudLayout.add((call.arguments as Map).cast<String, dynamic>());
      case 'hudQueue':
        _hudQueue.add((call.arguments as Map).cast<String, dynamic>());
      case 'hudState':
        final name = call.arguments as String;
        _hudStates.add(
          HudState.values.firstWhere(
            (s) => s.name == name,
            orElse: () => HudState.hidden,
          ),
        );
      case 'reload':
        // Язык интерфейса перечитываем здесь, а не в каждом блоке: окон
        // три, а правит настройки одно, и переключиться должны все сразу.
        refreshLocale();
        _reload.add(null);
      case 'tab':
        _tab.add(call.arguments as String);
      case 'dictationStatus':
        return onStatusAsked?.call() ?? 'away';
      case 'releaseModel':
        await onReleaseAsked?.call();
      case 'calibrationActive':
        await onCalibrationActive?.call(call.arguments == true);
      case 'wakeDiagnostics':
        return await onWakeDiagnostics?.call(
          (call.arguments as Map).cast<String, dynamic>(),
        );
      case 'systemSleep':
        _systemSleep.add(null);
      case 'systemWake':
        _systemWake.add(null);
    }
    return null;
  }

  Stream<HotkeyEvent> get events => _hotkeys.stream;

  Stream<void> get panelShown => _shown.stream;

  Stream<void> get panelHidden => _hidden.stream;

  Stream<void> get systemSleep => _systemSleep.stream;

  Stream<void> get systemWake => _systemWake.stream;

  /// Убрать файл в Корзину, а не стереть насовсем. Промах по кнопке
  /// «Удалить» после часа речи иначе стоил бы этого часа: из Корзины
  /// запись возвращается средствами самой системы.
  ///
  /// С ограничением по времени. Ответ приходит из completion-обработчика
  /// системы, и однажды он уже приходил не с того потока — канал после
  /// такого замолкает, а окно, ждущее ответа, каменеет без единого следа.
  /// Пусть лучше действие честно не удастся, чем повиснет навсегда.
  Future<bool> trash(String path) async {
    try {
      return await _channel
              .invokeMethod<bool>('trash', {'path': path})
              .timeout(const Duration(seconds: 10)) ??
          false;
    } catch (e) {
      stderr.writeln('tsukiko: Корзина не ответила — $e');
      return false;
    }
  }

  Stream<String> get hudActions => _hudActions.stream;

  Stream<HudState> get hudStates => _hudStates.stream;

  /// Нажали кнопку на плавающей панели. Родная сторона переправит это
  /// диктовке: панель рисуется своим изолятом и до неё не достаёт.
  Future<void> showHudQueueMenu(Map<String, String> labels) =>
      _channel.invokeMethod('hudQueueMenu', labels);

  Future<void> hudAction(String action) =>
      _channel.invokeMethod('hudAction', action);

  Future<void> hud(
    HudState state, {
    int pending = 0,
    bool processing = false,
    IndicatorMode mode = IndicatorMode.panel,
  }) {
    final l10n = currentL10n();
    return _channel.invokeMethod('hud', {
      'state': state.name,
      'mode': mode.name,
      'pending': pending,
      'processing': processing,
      'labels': {
        'queueTitle': l10n.hudQueueCount(
          hudBacklogCount(state, pending, processing),
        ),
        'record': l10n.hudRecordNext,
        'abort': l10n.hudAbortCurrent,
        'clearQueue': l10n.hudClearQueue,
      },
    });
  }

  /// Пустое сочетание значит «не назначено»: родная сторона такое
  /// не перехватывает вовсе.
  Future<void> bind({
    required Hotkey hold,
    required Hotkey toggle,
    required Hotkey cancel,
  }) => _channel.invokeMethod('bind', {
    'hold': hold.toJson(),
    'toggle': toggle.toJson(),
    'cancel': cancel.toJson(),
  });

  Future<Hotkey?> capture() {
    // Прошлый захват мог уже завершиться по времени: его completer тогда
    // так и остался незакрытым, и второе `complete` бросило бы исключение.
    final previous = _capture;
    if (previous != null && !previous.isCompleted) previous.complete(null);

    final c = _capture = Completer<Hotkey?>();
    _channel.invokeMethod<void>('capture');
    // Ждать вечно нельзя: пользователь может передумать и уйти.
    return c.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _channel.invokeMethod<void>('cancelCapture');
        // Только своё: пока мы ждали, человек мог щёлкнуть по чипу ещё раз,
        // и в поле уже лежит новый completer. Обнулив его здесь, мы оставили
        // бы второй захват висеть навсегда.
        if (identical(_capture, c)) _capture = null;
        return null;
      },
    );
  }

  Future<bool> permission() async =>
      await _channel.invokeMethod<bool>('permissions') ?? false;

  Future<void> requestPermission() =>
      _channel.invokeMethod('requestPermission');

  Future<void> openPermissionSettings() =>
      _channel.invokeMethod('openPermissionSettings');

  /// Спросить у диктовки, чем она занята. Отвечает изолят панели — только
  /// он и знает; без панели отвечать некому, и это «свободно».
  Future<String> dictationStatus() async =>
      await _channel.invokeMethod<String>('dictationStatus') ?? 'away';

  /// Попросить диктовку выгрузить модель из памяти.
  Future<void> releaseModel() => _channel.invokeMethod('releaseModel');

  /// Настройки диктовки правит и главное окно — панели надо перечитать файл.
  Future<void> settingsChanged() => _channel.invokeMethod('settingsChanged');

  /// Reserve the microphone for voice calibration across Flutter engines.
  Future<void> setCalibrationActive(bool active) =>
      _channel.invokeMethod('calibrationActive', active);

  Future<Map<String, dynamic>> wakeDiagnostics(
    String action, [
    String? word,
  ]) async {
    final request = <String, dynamic>{'action': action};
    if (word != null) request['word'] = word;
    return (await _channel.invokeMapMethod<String, dynamic>(
          'wakeDiagnostics',
          request,
        )) ??
        <String, dynamic>{};
  }

  Stream<void> get settingsReloaded => _reload.stream;

  Future<void> quit() => _channel.invokeMethod('quit');

  /// Сказать родной стороне, по каким признакам узнаётся наш whisper-server.
  ///
  /// На выходе из приложения сирот добивает именно она (обычное «Завершить»
  /// сигнала в Dart не шлёт), и признаки ей нужны те же самые. Раньше они
  /// были записаны в двух местах на двух языках и могли разойтись; теперь
  /// источник один — `ourServerMarks` в dictation.dart.
  Future<void> setServerMarks(List<String> marks) =>
      _channel.invokeMethod('serverMarks', {'marks': marks});

  Future<String?> startRecording() => _channel.invokeMethod<String>('record');

  Future<String?> stopRecording() =>
      _channel.invokeMethod<String>('stopRecord');

  Future<double> level() async =>
      await _channel.invokeMethod<double>('level') ?? 0;

  Future<void>? _pasteReady;

  /// Wait before changing the clipboard again, rather than blocking ASR after
  /// each paste. The receiving application reads it after the key event, and
  /// macOS restores the previous clipboard after 400 ms.
  Future<void> waitForPaste() => _pasteReady ?? Future<void>.value();

  Future<void> copyText(String text) async {
    final previous = _pasteReady;
    final ready = Completer<void>();
    _pasteReady = ready.future;
    if (previous != null) await previous;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } finally {
      ready.complete();
    }
  }

  Future<bool> insert(String text) async {
    final previous = _pasteReady;
    final ready = Completer<void>();
    _pasteReady = ready.future;
    if (previous != null) await previous;
    var sent = false;
    try {
      sent =
          await _channel.invokeMethod<bool>('paste', {'text': text}) ?? false;
      return sent;
    } finally {
      if (sent) {
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 450),
          ).then((_) => ready.complete()),
        );
      } else {
        ready.complete();
      }
    }
  }

  /// Значок в Dock. Выключенный переводит приложение в .accessory: оно
  /// пропадает и из Dock, и из ⌘Tab, а строка меню остаётся. Меняется
  /// на лету, перезапуск не нужен.
  Future<void> setDockIcon(bool visible) =>
      _channel.invokeMethod('dockIcon', {'visible': visible});

  /// Автозапуск при входе в систему. Состояние хранит сама macOS, поэтому
  /// и спрашиваем его у неё: автозапуск можно выключить в Системных
  /// настройках, и своя запись в settings.json об этом бы не узнала.
  /// Без аргумента — только спросить, с аргументом — переключить.
  Future<bool> loginItem([bool? enabled]) async =>
      await _channel.invokeMethod<bool>(
        'loginItem',
        enabled == null ? null : {'enabled': enabled},
      ) ??
      false;

  Future<void> setPanelHeight(double height) =>
      _channel.invokeMethod('panelHeight', {'height': height});

  Future<void> openMainWindow() => _channel.invokeMethod('openMainWindow');

  Future<void> openSettings([String tab = 'dictation']) =>
      _channel.invokeMethod('openSettings', {'tab': tab});

  /// Какую вкладку показать при открытии. Окно настроек спрашивает это
  /// само: сообщение об открытии приходит раньше, чем его изолят успевает
  /// подписаться на канал.
  Future<String> initialTab() async =>
      await _channel.invokeMethod<String>('initialTab') ?? 'dictation';

  /// Окно настроек уже открыто, и попросили другую вкладку.
  Stream<String> get settingsTab => _tab.stream;

  MethodChannel get channel => _channel;

  /// Спросить текущее состояние плавающей панели записи.
  /// Нужно на старте hudMain, чтобы не пропустить начальное состояние.
  Future<HudState?> currentHudState() async {
    final state = await _channel.invokeMethod<String>('getHudState');
    if (state == null) return null;
    return HudState.values.firstWhere(
      (s) => s.name == state,
      orElse: () => HudState.hidden,
    );
  }
}
