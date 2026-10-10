import 'dart:async';
import 'dart:io';
import 'dart:collection';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../platform/bridge.dart';
import '../../core/logger.dart';
import '../../core/whisper_server.dart';
import 'dictation_state.dart';
import 'dictation_history.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/recognition.dart';
import '../../core/whisper.dart';
import '../../platform/os.dart';
import '../../core/settings.dart';
import '../../core/text_commands.dart';
import '../../core/vocabulary.dart';
import '../../core/app_locale.dart';
import '../../core/labels.dart';
import '../../core/wakeword/wakeword_service.dart';
import '../../core/wakeword/speaker_profile.dart';
import '../../core/wakeword/speech_verifier.dart';
import '../../core/wakeword/keyword_tokenizer.dart' show stripTrailingCloseWord;

/// Диктовка целиком: перехват клавиш, запись, сервер с моделью, вставка
/// текста и то, что из этого видно в панели.
///
/// Cubit, а не Bloc с событиями: взаимодействия здесь прямые — нажали
/// клавишу, значит начать запись. Заводить под каждое действие класс
/// события было бы церемонией без выгоды. Полный Bloc припасён для
/// очереди распознавания, где события действительно нужны.
///
/// Службы (`WhisperServer`, `NativeBridge`, таймеры) — поля этого класса;
/// наружу уходит только [DictationState], в котором одни значения.
class DictationCubit extends Cubit<DictationState> {
  static DictationState _initialState(List<DictationEntry>? initialHistory) {
    try {
      final history = initialHistory ?? DictationHistory.load();
      return DictationState(
        history: history,
        last: history.isNotEmpty ? history.first.text : '',
      );
    } catch (e, st) {
      Log.warn(
        'Dictation',
        'Не удалось инициализировать историю диктовок: $e',
        e,
        st,
      );
      return const DictationState();
    }
  }

  /// [server] подменяют только тесты: настоящий поднимает whisper-server
  /// и читает в память полтора гигабайта, а проверять надо не это.
  DictationCubit(
    this.bridge, {
    WhisperServer? server,
    WakeWordService? wakeWordService,
    List<DictationEntry>? initialHistory,
    Future<void> Function(List<DictationEntry>)? historyWriter,
  }) : super(_initialState(initialHistory)) {
    _writeHistory = historyWriter ?? _storeHistory;
    _server =
        server ??
        WhisperServer(idleTimeout: Duration(seconds: _settings.idleSeconds));
    _server.onChanged = _onServerChanged;
    _wakeWordService = wakeWordService;
    _setupWakeWordCallbacks();

    bridge.events.listen(_onHotkey);
    // Кнопки плавающей панели — те же действия, что и клавишами, плюс
    // отмена уже идущего распознавания, которой у клавиш нет.
    bridge.hudActions.listen(
      (a) => switch (a) {
        'cancel' => cancel(),
        'abort' => abortTranscription(),
        'clearQueue' => clearPending(),
        'record' => start(),
        _ => stop(),
      },
    );
    bridge.hudModes.listen((value) {
      final settings = DictationSettings.load();
      settings.indicatorMode = IndicatorMode.fromValue(value);
      settings.save();
      unawaited(bridge.settingsChanged());
      unawaited(_reloadSettings());
    });
    bridge.panelShown.listen((_) => _onPanelShown());
    bridge.panelHidden.listen((_) => _onPanelHidden());
    // Очередь спрашивает, можно ли забрать модель. Отвечаем мы: диктовка
    // главнее — она короткая, а очередь подождёт и продолжит сама.
    bridge.onStatusAsked = _statusForQueue;
    bridge.onReleaseAsked = _releaseModel;
    bridge.onCalibrationActive = (active) async {
      _calibrating = active;
      if (active) {
        await _wakeWordService?.stop();
        if (state.recording) await stop();
      } else {
        await _reloadSettings();
      }
    };
    bridge.onWakeDiagnostics = _handleWakeDiagnostics;
    // Те же настройки правит окно настроек — там они и живут.
    bridge.settingsReloaded.listen((_) => _reloadSettings());
    bridge.systemSleep.listen((_) => unawaited(_onSystemSleep()));
    bridge.systemWake.listen((_) => unawaited(_onSystemWake()));

    unawaited(_apply());
    unawaited(_ensureVad());
    // Сервер мог пережить падение приложения: полтора гигабайта, которые
    // иначе не вернёт никто. Ищем по метке в аргументах — pid-файла после
    // падения может не быть вовсе. Не синхронно на старте, а фоном: `ps`
    // и добивание процессов задерживали первый кадр панели на полсекунды.
    _sweeping = _sweepOrphans();

    // Подписки и таймер живут ровно столько же, сколько само приложение:
    // движок панели не выгружается никогда, отменять их негде и незачем.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    os.onTerminate(_bye);
  }

  final NativeBridge bridge;

  /// Службы живут дольше одного снимка и отвечают когда угодно: процесс
  /// сервера может умереть уже после того, как кубит закрыли. В приложении
  /// он не закрывается никогда, а в тестах — на каждом шаге.
  void _emit(DictationState next) {
    if (!isClosed) emit(next);
  }

  late final WhisperServer _server;
  WakeWordService? _wakeWordService;
  bool _calibrating = false;
  String? _lastDiagnosticsPath;

  Future<Map<String, dynamic>> _handleWakeDiagnostics(
    Map<String, dynamic> request,
  ) async {
    final action = request['action'];
    final service = _wakeWordService;
    switch (action) {
      case 'status':
        return {
          'recording': service?.isDiagnosing ?? false,
          'path': service?.diagnosticsPath ?? _lastDiagnosticsPath,
        };
      case 'start':
        if (!_settings.wakeWordEnabled || _calibrating) {
          return {'recording': false, 'error': 'wake_disabled'};
        }
        if (!(SpeakerProfile.load()?.hasPersonalKeywordsFor(
              _settings.wakeWord,
              _settings.closeWord,
            ) ??
            false)) {
          return {'recording': false, 'error': 'profile'};
        }
        final active = _getOrCreateWakeWordService();
        if (!active.isRunning && !await active.start(settings: _settings)) {
          return {'recording': false, 'error': 'detector_unavailable'};
        }
        final path = active.startDiagnostics();
        _lastDiagnosticsPath = path;
        return {'recording': path != null, 'path': path};
      case 'mark':
        service?.markDiagnostics(request['word'] as String? ?? '');
        return {
          'recording': service?.isDiagnosing ?? false,
          'path': service?.diagnosticsPath ?? _lastDiagnosticsPath,
        };
      case 'stop':
        final path = await service?.stopDiagnostics();
        _lastDiagnosticsPath = path ?? _lastDiagnosticsPath;
        return {'recording': false, 'path': _lastDiagnosticsPath};
      default:
        return {'recording': false, 'error': 'unknown_action'};
    }
  }

  DictationSettings _settings = DictationSettings.load();
  List<VocabularyItem> _vocabulary = const [];
  bool _commandsEnabled = true;

  WakeWordService _getOrCreateWakeWordService() {
    if (_wakeWordService == null) {
      _wakeWordService = WakeWordService(verifier: SpeechVerifier());
      _setupWakeWordCallbacks();
    }
    return _wakeWordService!;
  }

  void _setupWakeWordCallbacks() {
    final s = _wakeWordService;
    if (s == null) return;
    s.canTriggerWakeWord = () =>
        !state.recording &&
        _startingRecording == null &&
        _finishingRecording == null;
    s.onWakeWordTriggered = () {
      if (!state.recording) {
        start(startedByVoice: true);
      }
    };
    s.onCloseWordTriggered = () {
      if (state.recording) {
        stop();
      }
    };
    s.onSilenceTimeoutTriggered = () {
      if (state.recording) {
        stop();
      }
    };
  }

  Timer? _ticker;
  Timer? _meter;

  /// Поповер на экране. Всё, что считается только для него, — уровень
  /// сигнала и память сервера, — пока он закрыт, не считается вовсе.
  bool _panelVisible = false;

  /// Сколько раз подряд система ответила «разрешения нет».
  int _denied = 0;

  /// Сколько тиков прошло с прошлого замера памяти.
  int _sinceFootprint = 0;

  List<String> _models = findModels();
  Download? _vadDownload;
  String? _wav;
  String _clipboardResults = '';
  DateTime? _startedAt;

  /// Распознавание прервали крестиком. Отличать это от неудачи обязательно:
  /// «не получилось» и «я сам передумал» — разные новости.
  final Queue<_DictationJob> _pending = Queue();
  _DictationJob? _active;
  Future<void>? _finishingRecording;
  Future<void>? _worker;

  Phase get _restingPhase =>
      _active != null || _pending.isNotEmpty ? Phase.transcribing : Phase.idle;

  void _syncQueue() {
    _emit(
      state.copyWith(
        phase: state.recording ? Phase.recording : _restingPhase,
        pendingCount: _pending.length,
        processing: _active != null,
      ),
    );
  }

  Future<void> _showActivity([HudState fallback = HudState.hidden]) =>
      bridge.hud(
        state.recording
            ? HudState.recording
            : _active != null || _pending.isNotEmpty
            ? HudState.transcribing
            : fallback,
        pending: _pending.length,
        processing: _active != null,
        mode: _settings.indicatorMode,
      );

  /// Идущий подбор сирот и идущий подъём сервера под нынешнюю запись.
  Future<void>? _sweeping;
  Future<void>? _bringingUp;

  /// Начало записи в полёте и просьба остановиться, пришедшая раньше,
  /// чем оно закончилось.
  ///
  /// Между «нажали клавишу» и «микрофон пишет» проходит время: система
  /// спрашивает разрешение, `AVAudioRecorder` заводится. Короткое нажатие
  /// успевало отпуститься в этом промежутке — `stop` видел фазу «покой»
  /// и выходил ни с чем, а `start` следом ставил «запись». Панель после
  /// этого писала «Записываю» вечно, хотя микрофон уже молчал.
  Future<void>? _startingRecording;

  /// Чем кончить запись, которую попросили кончить, пока заводился
  /// микрофон: [stop] или [cancel]. Раньше это был один флаг «просили
  /// прекратить», и отмена на нём превращалась в обычную остановку —
  /// фраза уходила распознаваться и ложилась в «не удалось». Успеть
  /// нетрудно: fn+ctrl+opt разом не нажать, и отмена приходит через
  /// миллисекунды после начала.
  Future<void> Function()? _finishAfterStart;

  // ── настройки распознавания ────────────────────────────────────────────────

  /// Настройки диктовки — свои целиком, не общие с очередью: диктуют не то
  /// же, что расшифровывают, и одни значения на две стороны устраивали бы
  /// плохо обе. Из настроек очереди берётся одно — модель, и то лишь пока
  /// своя не выбрана: «как у расшифровщика» это и обещает.
  ///
  /// Язык всегда «авто»: диктуют на разных языках вперемешку, и выбирать
  /// его руками каждый раз некому. VAD включён всегда, независимо от галки
  /// в очереди: фразы короткие, и на секундах тишины whisper сочиняет
  /// «Продолжение следует…».
  RunOptions get _options {
    final options = RunOptions(
      model: state.chosenModel,
      lang: 'auto',
      threads: _settings.threads,
      prompt: _settings.prompt,
      punctuate: _settings.punctuate,
      vad: _hasVad,
      vadModel: _hasVad ? vadModelPath : '',
    );
    return _commandsEnabled
        ? options.copyWith(
            prompt: promptWithVocabulary(
              options.effectivePrompt,
              _vocabulary,
              maxEstimatedTokens:
                  engineForModel(options.model) == RecognitionEngine.whisperCpp
                  ? vocabularyPromptBudget
                  : 9999,
            ),
          )
        : options;
  }

  bool _hasVad = false;

  /// Перечитать с диска то, что меняется редко, и отдать в состояние.
  ///
  /// Именно здесь, а не в геттерах: раньше `options` читал settings.json
  /// и проверял файл VAD, а звали его из `build` панели — во время записи
  /// это выходило десять чтений диска в секунду.
  DictationState _withSnapshots(DictationState from) {
    _hasVad = File(vadModelPath).existsSync();
    final app = Settings.load();
    final queueModel = (app['model'] as String?) ?? '';
    _vocabulary = loadAndMigrateVocabulary(app);
    _commandsEnabled =
        (app[vocabularyDictationEnabledSetting] as bool?) ??
        (app[dictationCommandsEnabledSetting] as bool?) ??
        true;
    return from.copyWith(
      enabled: _settings.enabled,
      holdLabel: _settings.hold.label,
      toggleLabel: _settings.toggle.label,
      ownModel: _settings.model.isNotEmpty,
      chosenModel: _settings.model.isNotEmpty ? _settings.model : queueModel,
      models: _models,
    );
  }

  // ── жизненный цикл ─────────────────────────────────────────────────────────

  Future<Never> _bye() async {
    _ticker?.cancel();
    await _wakeWordService?.dispose();
    await _server.shutdown();
    // Свой сервер мы только что погасили; этот проход — на случай, если
    // рядом остался ещё один, о котором мы не знаем.
    await sweepOurServers();
    exit(0);
  }

  Future<void> _sweepOrphans() async {
    final freed = await sweepOurServers();
    if (freed > 0) _emit(state.copyWith(sweptMb: freed));
  }

  Future<void> _onSystemSleep() async {
    Log.info('Dictation', 'System sleep detected; pausing audio and wake word');
    if (state.recording) {
      await cancel();
    }
    await _wakeWordService?.pauseForSleep();
  }

  Future<void> _onSystemWake() async {
    Log.info('Dictation', 'System wake detected; resuming wake word');
    await _wakeWordService?.resumeFromSleep();
  }

  Future<void> _apply({bool rebind = true}) async {
    // Родная сторона гасит сирот на выходе из приложения — признаки
    // «наш сервер» она должна брать у нас, а не держать свою копию.
    await bridge.setServerMarks(ourServerMarks);
    // Приложение всегда стартует со значком в Dock: LSUIElement в Info.plist
    // спрятал бы его навсегда, а настройка должна переключаться на лету.
    // Значит спрятать его может только Dart, и как можно раньше.
    await bridge.setDockIcon((Settings.load()['dockIcon'] as bool?) ?? true);
    // Rebinding resets native key latches. Appearance changes must preserve
    // a held recording shortcut so its eventual release still stops recording.
    if (rebind) {
      await bridge.bind(
        hold: _settings.hold,
        toggle: _settings.toggle,
        cancel: _settings.cancel,
      );
    }
    _emit(_withSnapshots(state));
    await _checkPermission();
    if (_settings.wakeWordEnabled && !_calibrating) {
      final ww = _getOrCreateWakeWordService();
      unawaited(ww.start(settings: _settings));
    } else {
      await _wakeWordService?.stop();
    }
  }

  Future<void> _reloadSettings() async {
    final was = _settings;
    _settings = DictationSettings.load();
    // Модель в главном окне могли сменить — снимок обязан это увидеть
    // до сравнения ниже, иначе сервер останется на прежней.
    _models = findModels();
    _emit(_withSnapshots(state));
    _server.idleTimeout = Duration(seconds: _settings.idleSeconds);
    // Всё, с чем сервер запускается, он читает один раз — значит новое
    // увидит только с новым запуском. Память отдаём сразу, поднимется
    // он снова на следующей фразе.
    //
    // Модель сравниваем не по своей настройке, а по той, с которой сервер
    // поднят: при «как у расшифровщика» своя настройка пуста и до и после,
    // а модель под ней сменилась в главном окне — и диктовка молча
    // продолжала бы говорить старой.
    if (_active == null &&
        _pending.isEmpty &&
        (was.prompt != _settings.prompt ||
            was.punctuate != _settings.punctuate ||
            was.threads != _settings.threads ||
            (_server.up && _server.model != _options.model))) {
      unawaited(_server.shutdown());
    }
    await _apply(
      rebind:
          !was.hold.sameAs(_settings.hold) ||
          !was.toggle.sameAs(_settings.toggle) ||
          !was.cancel.sameAs(_settings.cancel),
    );
    if (was.indicatorMode != _settings.indicatorMode) await _showActivity();
  }

  @visibleForTesting
  Future<void> reloadSettingsForTesting() => _reloadSettings();

  @visibleForTesting
  RunOptions get optionsForTesting => _options;

  @visibleForTesting
  Future<void>? get bringingUpForTesting => _bringingUp;

  /// «Разрешения нет» — вывод не с первой попытки. Сразу после запуска
  /// система отвечает «нет» и тем, кто всё давно разрешил: процесс ещё
  /// не осел. Плашка на пустом месте пугает зря, поэтому верим только
  /// нескольким отказам подряд, а любому «да» — сразу.
  @visibleForTesting
  Future<void> checkPermission() => _checkPermission();

  Future<void> _checkPermission() async {
    final now = await bridge.permission();
    if (now) {
      _denied = 0;
      _emit(state.copyWith(allowed: true));
      return;
    }
    if (++_denied < 3) return;
    _emit(state.copyWith(allowed: false));
  }

  Future<void> _onPanelShown() async {
    _panelVisible = true;
    _forgetGoneRecording();
    _models = findModels();
    _emit(_withSnapshots(state));
    _syncMeter();
    await _checkPermission();
  }

  void _onPanelHidden() {
    _panelVisible = false;
    _syncMeter();
  }

  void _onServerChanged() => _emit(
    state.copyWith(
      serverUp: _server.up,
      memoryMb: _server.up ? state.memoryMb : 0,
      untilUnload: _server.untilUnload,
      clearUnload: _server.untilUnload == null,
    ),
  );

  Future<void> _tick() async {
    // Спрашиваем о разрешении каждую секунду: человек уходит выдавать его
    // в другое приложение и возвращается к открытой панели. Тот же вопрос
    // заново создаёт перехват клавиш — без перезапуска. Стоит это одного
    // обращения к системе, подпроцессов не запускает.
    await _checkPermission();
    if (isClosed) return;

    if (!_server.up) {
      _sinceFootprint = 0;
      return;
    }

    // Обратный отсчёт — простая арифметика, и считать её надо всегда.
    // Раньше он был за тем же гейтом, что и замер памяти: панель открывали
    // и видели «освободится через 2:35», застывшее с прошлого раза, — а во
    // время диктовки модель вообще никуда не освобождается, её держит аренда.
    _emit(
      state.copyWith(
        untilUnload: _server.untilUnload,
        clearUnload: _server.untilUnload == null,
      ),
    );

    // А вот память сервера считает отдельная утилита, то есть целый процесс
    // на каждый замер. Вот его и придерживаем: число видно только в панели.
    if (!_panelVisible) {
      _sinceFootprint = 0;
      return;
    }

    // Обратный отсчёт до выгрузки идёт на экране и обязан тикать каждую
    // секунду. Раньше он замирал: тик обновлял экран только когда менялось
    // число мегабайт, а память между замерами стоит на месте.
    _emit(state.copyWith(untilUnload: _server.untilUnload));

    // Память сервера считает отдельная утилита, то есть целый процесс
    // на каждый замер. Раз в секунду это была самая дорогая мелочь
    // в простое, поэтому раз в пять и только при открытом поповере.
    if (_sinceFootprint++ % 5 != 0) return;
    final mb = await _server.footprintMb();
    if (!isClosed) _emit(state.copyWith(memoryMb: mb));
  }

  /// Модель тишины весит меньше мегабайта и качается один раз. Не вышло —
  /// диктуем без неё: галлюцинации на тишине хуже, чем ничего, но молчащая
  /// диктовка хуже вдвойне.
  Future<void> _ensureVad() async {
    if (File(vadModelPath).existsSync() || _vadDownload != null) return;
    final d = Download(vadModelUrl, vadModelPath);
    _vadDownload = d;
    _emit(state.copyWith(vadProgress: d.progressLabel, clearVad: true));
    final path = await d.run(
      onProgress: () {
        if (!isClosed) _emit(state.copyWith(vadProgress: d.progressLabel));
      },
    );
    _vadDownload = null;
    _hasVad = path != null;
    if (isClosed) return;
    _emit(
      state.copyWith(clearVad: true, vadError: path == null ? d.error : null),
    );
  }

  /// Повтор после неудачи. Недокачанное лежит в «.part», так что второй
  /// заход продолжит с того же места, а не начнёт сначала.
  Future<void> retryVad() => _ensureVad();

  // ── запись ─────────────────────────────────────────────────────────────────

  void _onHotkey(HotkeyEvent e) {
    if (!_settings.enabled) return;
    // Поверх сочетания набрали лишнее — значит целили не в диктовку.
    // Начатое выбрасываем, и панель уходит сразу.
    if (e.cancel) {
      cancel();
      return;
    }
    // Бросить начатое. Отдельным сочетанием затем, что «Остановить»
    // и «Передумал» — разные намерения, а у клавиш второго не было вовсе:
    // отменить начатое можно было только мышью, по крестику на плавающей
    // панели, которую человек мог и выключить. Записи в этом случае
    // не остаётся ни в тексте, ни в буфере — на то и «без вставки».
    if (e.id == 'cancel') {
      if (e.edge == HotkeyEdge.down) {
        state.recording || _startingRecording != null
            ? cancel()
            : abortTranscription();
      }
      return;
    }
    if (e.id == 'hold') {
      e.edge == HotkeyEdge.down ? start() : stop();
      return;
    }
    if (e.edge == HotkeyEdge.down) {
      state.recording ? stop() : start();
    }
  }

  Future<void> start({bool startedByVoice = false}) async {
    if (_finishingRecording != null) await _finishingRecording;
    if (isClosed || state.recording || _startingRecording != null) return;
    if (state.phase == Phase.idle) _clipboardResults = '';
    _finishAfterStart = null;
    _startingRecording = _beginRecording(startedByVoice: startedByVoice);
    try {
      await _startingRecording;
    } finally {
      _startingRecording = null;
    }
    // Пока заводился микрофон, клавишу успели отпустить — или набрать
    // поверх лишнюю, и тогда это была не остановка, а отмена.
    final finish = _finishAfterStart;
    _finishAfterStart = null;
    if (finish != null) await finish();
  }

  Future<void> _beginRecording({bool startedByVoice = false}) async {
    // Реакция на клавишу должна быть мгновенной. На Windows один только
    // подъём WASAPI занимает заметное время; прежде всё это время панель
    // молчала и казалось, что хоткей не сработал. Запуск микрофона всё ещё
    // ждём ниже, но состояние и HUD показываем сразу.
    _startedAt = DateTime.now();
    Log.info('Dictation', 'Recording started (model: ${_options.model})');
    _emit(
      state.copyWith(
        phase: Phase.recording,
        elapsed: Duration.zero,
        clearFailure: true,
      ),
    );
    unawaited(_showActivity());
    _syncMeter();
    _wakeWordService?.notifyRecordingStarted(startedByVoice: startedByVoice);

    // Сервер поднимается параллельно записи: пока человек говорит, модель
    // успевает загрузиться, и после отпускания клавиши ждать уже нечего.
    // Аренда держит его живым всю запись: без неё таймер простоя выгружал
    // модель посреди длинной фразы, и распознавать было уже нечем.
    _server.hold();
    // Подъём держим отдельным фьючером и ждём его перед распознаванием:
    // подметание сирот сдвигает `ensureUp` на своё время, и без этого
    // ожидания короткая фраза успевала кончиться раньше, чем сервер
    // вообще начинал подниматься, — и считалась нераспознанной.
    _bringingUp = () async {
      // Подметание идёт фоном, а наш сервер несёт те же метки: подняться
      // раньше, чем оно кончится, — значит быть убитым им же.
      try {
        await _sweeping;
        if (_active == null && _pending.isEmpty) {
          await _server.ensureUp(_options);
        }
      } catch (e, st) {
        Log.error('Dictation', 'Engine bringup failed: $e', e, st);
      }
    }();
    unawaited(_bringingUp);

    String? path;
    try {
      path = await bridge.startRecording();
    } catch (e, st) {
      Log.error('Dictation', 'Microphone failed', e, st);
    }
    if (path == null || path.isEmpty) {
      Log.error('Dictation', 'Recording failed to start');
      _stopMeter();
      _server.release();
      _wakeWordService?.notifyRecordingStopped();
      _emit(
        state.copyWith(
          phase: _restingPhase,
          failure: currentL10n().errorRecordingStart,
        ),
      );
      unawaited(_showActivity(HudState.failed));
      return;
    }
    _wav = path;
  }

  Future<void> stop() async {
    if (_startingRecording != null) {
      _finishAfterStart ??= stop;
      return;
    }
    if (_finishingRecording != null || !state.recording) return;
    final finished = Completer<void>();
    _finishingRecording = finished.future;
    _DictationJob? job;
    try {
      _wakeWordService?.notifyRecordingStopped();
      _stopMeter();
      final path = await bridge.stopRecording() ?? _wav;
      _wav = null;
      if (path != null && path.isNotEmpty) {
        job = _DictationJob(
          path,
          _options,
          _settings.closeWord,
          _settings.insert,
          _commandsEnabled,
          List.of(_vocabulary),
        );
        _pending.add(job);
      }
      _emit(state.copyWith(phase: _restingPhase));
      _syncQueue();
      unawaited(_showActivity());
      if (job == null) _server.release();
      if (job != null) _worker ??= _drain();
    } catch (e, st) {
      Log.error('Dictation', 'Stopping microphone failed', e, st);
      final path = _wav;
      _wav = null;
      final saved = path == null ? null : rescueRecording(path) ?? path;
      _server.release();
      _emit(
        state.copyWith(
          phase: _restingPhase,
          failure: currentL10n().errorRecordingStart,
          failurePath: saved,
        ),
      );
      unawaited(_showActivity(HudState.failed));
    } finally {
      _finishingRecording = null;
      finished.complete();
    }
    // Callers may await this particular result; the microphone is already free.
    await job?.done.future;
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty && !isClosed) {
        final job = _active = _pending.removeFirst();
        _syncQueue();
        unawaited(_showActivity());
        try {
          await _transcribeJob(job);
        } finally {
          _active = null;
          _syncQueue();
          job.done.complete();
        }
      }
    } finally {
      _worker = null;
    }
  }

  Future<void> _transcribeJob(_DictationJob job) async {
    final path = job.path;
    var ok = false, silent = false;
    String? failure;
    String? failurePath;
    try {
      // Записать не успели: клавишу отпустили раньше, чем микрофон отдал
      // первый отсчёт. Такой файл спасать нечего и незачем — в нём
      // заголовок и ноль данных, — а движок на нём говорит невнятное
      // (см. wavHasAudio). Стираем и говорим прямо.
      if (!wavHasAudio(path)) {
        _discard(path);
        silent = true;
        failure = currentL10n().errorSilentRecording;
      } else {
        // Сервер поднимался параллельно записи — дожидаемся, иначе фраза
        // короче подъёма уйдёт в «не удалось» при живой модели.
        if (_bringingUp != null) {
          try {
            await _bringingUp;
          } catch (e, st) {
            Log.error(
              'Dictation',
              'Waiting for engine bringup failed: $e',
              e,
              st,
            );
          }
        }
        Log.info(
          'Dictation',
          'Transcribing dictation audio ($path) with model: ${_options.model}, lang: ${_options.lang}',
        );
        if (!job.aborted) await _server.ensureUp(job.options);
        final recognized = job.aborted
            ? null
            : await _server.transcribe(path, lang: job.options.lang);
        if (job.aborted) await job.cancelling;
        if (recognized == null || job.aborted) {
          Log.warn('Dictation', 'Dictation transcribe returned null');
          // Распознать не удалось — или мы сами прервали счёт. Запись
          // в обоих случаях единственный экземпляр сказанного, и удалять
          // её здесь было бы потерей данных.
          final saved = rescueRecording(path);
          failurePath = saved ?? path;
          failure = job.aborted
              ? saved == null
                    ? currentL10n().dictationAbortedNoSave(path)
                    : currentL10n().dictationAbortedSaved
              : saved == null
              ? currentL10n().dictationFailedNoSave(path)
              : currentL10n().dictationFailedSaved(saved);
        } else {
          _discard(path);
          var text = recognized;
          if (job.closeWord.trim().isNotEmpty) {
            text = stripTrailingCloseWord(text, job.closeWord);
          }
          if (job.commandsEnabled) {
            text = applyVocabularyReplacements(text, job.vocabulary).text;
          }
          Log.info('Dictation', 'Dictation transcribed: ${text.length} chars');
          if (text.isNotEmpty) {
            job.delivering = true;
            _remember(text);
            // «Только в буфер» — для тех, кто вставит сам и туда, куда решит.
            if (!job.insert) {
              await _copyResult(text);
              ok = true;
            } else {
              ok = await bridge.insert(text);
              if (!ok) {
                // Вставка не состоялась — почти всегда это отозванный
                // «Универсальный доступ». Текст при этом уже распознан,
                // и терять его нельзя: кладём в буфер и говорим вслух.
                await _copyResult(text);
                failure = currentL10n().insertFailed(os.accessibilityName);
              }
            }
          }
        }
      }
    } catch (e, st) {
      Log.error(
        'Dictation',
        'Unexpected error during stop/transcription: $e',
        e,
        st,
      );
      if (failurePath == null && !silent) {
        final saved = rescueRecording(path);
        failurePath = saved ?? path;
        failure = saved == null
            ? currentL10n().dictationFailedNoSave(path)
            : currentL10n().dictationFailedSaved(saved);
      }
    } finally {
      _server.release();
    }

    // Панель уходит с подтверждением, только если было что вставлять:
    // галочка после тишины была бы неправдой. А неудача не должна уходить
    // молча — иначе человек так и не узнает, что записи он лишился.
    // Исходы разные: пропала запись, пропала только вставка, или мы сами
    // прервали счёт, — и говорить о них одним и тем же нельзя.
    final outcome = ok
        ? HudState.done
        : silent
        ? HudState.silent
        : job.aborted
        ? HudState.cancelled
        : failurePath != null
        ? HudState.failed
        : failure != null
        ? HudState.copied
        : HudState.hidden;
    if (isClosed) return;
    _emit(
      state.copyWith(
        failure: failure,
        failurePath: failurePath,
        clearFailure: failure == null,
      ),
    );
    await bridge.hud(
      state.recording
          ? HudState.recording
          : _pending.isNotEmpty
          ? HudState.transcribing
          : outcome,
      pending: _pending.length,
      processing: _pending.isNotEmpty,
      mode: _settings.indicatorMode,
    );
  }

  /// Передумал. Записанное выбрасываем, ничего не распознаём и не
  /// вставляем — молча, как будто ничего и не начиналось.
  Future<void> cancel() async {
    if (_startingRecording != null) {
      _finishAfterStart = cancel;
      return;
    }
    if (_finishingRecording != null || !state.recording) return;
    final finished = Completer<void>();
    _finishingRecording = finished.future;
    try {
      _wakeWordService?.notifyRecordingStopped();
      _stopMeter();
      _discard(await bridge.stopRecording() ?? _wav);
      _wav = null;
    } finally {
      _server.release();
      _emit(state.copyWith(phase: _restingPhase));
      _finishingRecording = null;
      finished.complete();
      unawaited(_showActivity());
    }
  }

  /// Cancels only the active recognition, even while another recording runs.
  Future<void> abortTranscription() async {
    final job = _active;
    if (job == null || job.aborted || job.delivering) return;
    job.aborted = true;
    job.cancelling = () async {
      await _bringingUp;
      await _server.ready;
      await _server.shutdown();
    }();
    await job.cancelling;
  }

  /// Waiting recordings are preserved in the recovery library.
  Future<void> clearPending() async {
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      final saved = rescueRecording(job.path) ?? job.path;
      _emit(
        state.copyWith(
          failurePath: saved,
          failure: currentL10n().dictationAbortedSaved,
        ),
      );
      _server.release();
      job.done.complete();
    }
    _syncQueue();
    await _showActivity();
  }

  /// Уровень сигнала и время записи.
  ///
  /// Считается всю запись, независимо от того, открыт ли поповер. Была
  /// попытка сэкономить и заводить таймер только при открытом — и она
  /// стоила и бегущего времени, и полоски громкости: признак «поповер
  /// на экране» оказался ненадёжным, а десять вызовов канала в секунду
  /// не стоят того, чтобы на них экономить.
  void _syncMeter() {
    final needed = state.recording;
    if (needed == (_meter != null)) return;
    if (!needed) {
      _stopMeter();
      return;
    }
    _meter = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final level = await bridge.level();
      if (isClosed || !state.recording || _meter == null) return;
      _emit(
        state.copyWith(
          level: level,
          elapsed: DateTime.now().difference(_startedAt ?? DateTime.now()),
        ),
      );
    });
  }

  void _stopMeter() {
    _meter?.cancel();
    _meter = null;
    if (!isClosed) _emit(state.copyWith(level: 0));
  }

  void _discard(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  // ── действия из панели ─────────────────────────────────────────────────────

  void setEnabled(bool v) {
    _settings.enabled = v;
    if (!v && state.recording) cancel();
    _settings.save();
    _emit(_withSnapshots(state));
    unawaited(bridge.settingsChanged());
    if (v && state.chosenModel.isNotEmpty) {
      _bringingUp = () async {
        try {
          await _sweeping;
          if (_active == null && _pending.isEmpty) {
            await _server.ensureUp(_options);
          }
        } catch (e, st) {
          Log.error('Dictation', 'Engine prewarm failed: $e', e, st);
        }
      }();
      unawaited(_bringingUp);
    }
  }

  void setModel(String path) {
    _settings.model = path;
    _settings.save();
    _emit(_withSnapshots(state));
    unawaited(bridge.settingsChanged());
    if (_active == null &&
        _pending.isEmpty &&
        _server.up &&
        _server.model != path) {
      unawaited(_server.shutdown());
    }
    if (_settings.enabled && path.isNotEmpty) {
      _bringingUp = () async {
        try {
          await _sweeping;
          if (_active == null && _pending.isEmpty) {
            await _server.ensureUp(_options);
          }
        } catch (e, st) {
          Log.error('Dictation', 'Engine prewarm failed: $e', e, st);
        }
      }();
      unawaited(_bringingUp);
    }
  }

  Future<void> _copyResult(String text) async {
    _clipboardResults = _clipboardResults.isEmpty
        ? text
        : '$_clipboardResults\n$text';
    _emit(state.copyWith(last: _clipboardResults));
    await bridge.copyText(_clipboardResults);
  }

  Future<void> copyLast() async {
    if (state.last.isEmpty) return;
    await bridge.copyText(state.last);
  }

  late final Future<void> Function(List<DictationEntry>) _writeHistory;
  Future<void>? _historyWrites;

  static Future<void> _storeHistory(List<DictationEntry> history) =>
      history.isEmpty
      ? DictationHistory.remove()
      : DictationHistory.write(history);

  @visibleForTesting
  Future<void> flushHistoryForTesting() async {
    await _historyWrites;
  }

  int _historySequence = 0;

  void _remember(String text) {
    final now = DateTime.now();
    final entry = DictationEntry(
      id: '${now.microsecondsSinceEpoch}-${_historySequence++}',
      text: text,
      createdAt: now,
    );
    final history = List<DictationEntry>.unmodifiable(
      [entry, ...state.history].take(DictationHistory.maxEntries),
    );
    _emit(state.copyWith(last: text, history: history));
    unawaited(_persistHistory(history));
  }

  Future<bool> _persistHistory(List<DictationEntry> history) {
    final result = Completer<bool>();
    final previous = _historyWrites;
    _historyWrites = () async {
      if (previous != null) await previous;
      try {
        await _writeHistory(history);
        if (!isClosed) _emit(state.copyWith(clearHistoryError: true));
        result.complete(true);
      } catch (e, st) {
        Log.warn('DictationHistory', 'History update failed: $e', e, st);
        if (!isClosed) {
          _emit(state.copyWith(historyError: currentL10n().historySaveFailed));
        }
        result.complete(false);
      }
    }();
    final writing = _historyWrites;
    unawaited(
      writing!.then((_) {
        if (identical(_historyWrites, writing)) _historyWrites = null;
      }),
    );
    return result.future;
  }

  /// Copies one transcript, rather than the accumulated clipboard queue.
  /// NativeBridge serializes this operation with automatic pastes.
  Future<bool> copyEntry(String id) async {
    final entry = state.history.where((e) => e.id == id).firstOrNull;
    if (entry == null || entry.text.trim().isEmpty) return false;
    try {
      await bridge.copyText(entry.text);
      return true;
    } catch (e, st) {
      Log.warn('Dictation', 'Could not copy history entry: $e', e, st);
      return false;
    }
  }

  Future<void> clearHistory() => _deleteHistory(null);
  Future<void> deleteHistoryEntry(String id) => _deleteHistory(id);

  Future<void> _deleteHistory(String? id) async {
    final previous = state;
    final updated = List<DictationEntry>.unmodifiable(
      id == null ? [] : state.history.where((e) => e.id != id),
    );
    if (id != null && updated.length == state.history.length) return;
    _emit(
      state.copyWith(
        history: updated,
        last: updated.isNotEmpty ? updated.first.text : '',
      ),
    );
    final saved = await _persistHistory(updated);
    // Roll back only if no later dictation or deletion has changed the list.
    if (!saved && !isClosed && identical(state.history, updated)) {
      _emit(state.copyWith(history: previous.history, last: previous.last));
    }
  }

  void unload() {
    if (state.phase == Phase.idle) unawaited(_server.shutdown());
  }

  void forgetSweep() => _emit(state.copyWith(sweptMb: 0));

  /// Убрать сохранённую запись в Корзину. Не `unlink`: промах по кнопке
  /// после часа речи иначе стоил бы этого часа, а из Корзины файл
  /// возвращается средствами самой системы.
  Future<void> discardFailure() async {
    final path = state.failurePath;
    if (path == null) return;
    final gone = await bridge.trash(path);
    if (isClosed) return;
    _emit(
      gone
          ? state.copyWith(clearFailure: true)
          : state.copyWith(failure: currentL10n().recordingTrashFailed(path)),
    );
  }

  /// Показать спасённую запись в проводнике — оттуда её перетаскивают
  /// в очередь главного окна и распознают вручную.
  ///
  /// Запись могли убрать мимо приложения. Тогда показывать нечего,
  /// и вместо подделки говорим правду.
  Future<void> revealFailure() async {
    final p = state.failurePath;
    if (p == null) return;
    if (await revealInFinder(p)) return;
    _reportGone();
  }

  /// Записи больше нет. Кнопок к ней не остаётся — ни одна ничего не
  /// исправит, — и само сообщение тоже не вечное: сказали и убрали,
  /// иначе панель так и стоит с надписью о том, чего уже не вернуть.
  void _reportGone() {
    _emit(
      state.copyWith(
        failure: currentL10n().recordingGoneExternally,
        clearFailurePath: true,
      ),
    );
    Future.delayed(const Duration(seconds: 6), () {
      if (isClosed || state.failurePath != null) return;
      if (state.failure == currentL10n().recordingGoneExternally) {
        _emit(state.copyWith(clearFailure: true));
      }
    });
  }

  /// Убедиться, что спасённая запись всё ещё на месте. Панель открывают
  /// спустя время, и предлагать кнопку к исчезнувшему файлу нечестно.
  void _forgetGoneRecording() {
    final p = state.failurePath;
    if (p == null || File(p).existsSync()) return;
    _reportGone();
  }

  /// Чем занята диктовка — для очереди.
  ///
  /// Сама память ничего не решает: важно, идёт ли прямо сейчас запись или
  /// распознавание фразы. Фраза длится секунды, и прерванная пропадает
  /// совсем — переговорить её нельзя, в отличие от записи в очереди.
  String _statusForQueue() {
    if (state.phase != Phase.idle) return 'busy';
    return _server.up ? 'resting' : 'away';
  }

  /// Отдать память. Спрашивают только в покое и только с согласия человека:
  /// держать полтора гигабайта ради возможной следующей фразы дороже,
  /// чем поднять сервер заново за 0,6 с.
  Future<void> _releaseModel() async {
    if (state.phase == Phase.idle) await _server.shutdown();
  }

  /// Высота содержимого панели: окно подгоняется под неё, как системный
  /// поповер, — иначе внизу остаётся пустота на всё, чего сейчас нет.
  Future<void> reportHeight(double height) => bridge.setPanelHeight(height);

  Future<void> openMainWindow() => bridge.openMainWindow();

  /// Настройки диктовки живут в своём окне. Без значка в Dock строки меню
  /// у приложения нет, и эта кнопка — единственная дорога туда.
  Future<void> openSettings([String tab = 'dictation']) =>
      bridge.openSettings(tab);

  Future<void> requestPermission() => bridge.requestPermission();

  Future<void> openPermissionSettings() => bridge.openPermissionSettings();

  Future<void> quit() async {
    await _historyWrites;
    await bridge.quit();
  }

  @visibleForTesting
  WakeWordService? get wakeWordServiceForTesting => _wakeWordService;

  @override
  Future<void> close() {
    _ticker?.cancel();
    _meter?.cancel();
    _wakeWordService?.dispose();
    final closed = super.close();
    final writing = _historyWrites;
    return writing == null
        ? closed
        : Future.wait([closed, writing]).then((_) {});
  }
}

class _DictationJob {
  _DictationJob(
    this.path,
    this.options,
    this.closeWord,
    this.insert,
    this.commandsEnabled,
    this.vocabulary,
  );
  final String path;
  final RunOptions options;
  final String closeWord;
  final bool insert, commandsEnabled;
  final List<VocabularyItem> vocabulary;
  final done = Completer<void>();
  bool aborted = false;
  bool delivering = false;
  Future<void>? cancelling;
}
