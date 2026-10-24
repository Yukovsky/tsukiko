import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'package:bloc/bloc.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/app_locale.dart';
import '../../core/app_theme.dart';
import '../../core/labels.dart';
import '../../core/library.dart';
import '../../core/logger.dart';
import '../../core/models.dart';
import '../../core/settings.dart';
import '../../core/text_commands.dart';
import '../../core/transcript.dart';
import '../../core/vocabulary.dart';
import '../../core/whisper_server.dart';
import '../api/api_server.dart';
import '../../core/skill_install.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import '../../core/wakeword/speaker_profile.dart';
import 'settings_state.dart';

/// Окно настроек: расшифровщик, диктовка, склад моделей и приложение.
///
/// Вкладки разложены по хозяину настройки, и кубит повторяет ту же
/// раскладку: одна половина его значений принадлежит диктовке и лежит
/// в `dictation.json`, другая — расшифровщику и приложению и лежит
/// в `settings.json`. Модель расшифровщика меняется и здесь, и в главном
/// окне через один ключ и после записи рассылается всем окнам.
///
/// Cubit, а не Bloc: каждое действие здесь — «поставить галку» или
/// «выбрать значение», отбрасывать и переупорядочивать нечего.
///
/// Настройки хранятся в двух файлах. Диктовка — в своём (`dictation.json`),
/// и правит его только это окно. Общие настройки лежат в `settings.json`,
/// который правят и главное окно тоже, — поэтому после каждой записи
/// соседним изолятам говорят перечитать файл. Без этого половина правок
/// доходила бы только до следующего запуска.
class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this.bridge) : super(SettingsState()) {
    _dictation = DictationSettings.load();
    _subs.add(bridge.settingsReloaded.listen((_) => _reloadSettings()));
    _subs.add(bridge.settingsTab.listen((t) => _emit(state.copyWith(tab: t))));
    _reloadSettings();
    // Вкладку окно спрашивает само: сообщение об открытии приходит раньше,
    // чем этот изолят успевает подписаться на канал.
    unawaited(bridge.initialTab().then((t) => _emit(state.copyWith(tab: t))));
    unawaited(checkPermission());
  }

  final NativeBridge bridge;

  late DictationSettings _dictation;
  final _subs = <StreamSubscription<void>>[];
  Timer? _timer;
  Download? _download;

  /// Сколько раз подряд система ответила «разрешения нет».
  int _denied = 0;

  void _emit(SettingsState next) {
    if (!isClosed) emit(next);
  }

  // ── чтение с диска ────────────────────────────────────────────────────────

  void _reloadSettings() {
    _dictation = DictationSettings.load();
    // _readApp разрешает связь «расшифровщик как у диктовки» через
    // свежую модель диктовки и при необходимости чинит старое состояние.
    _readApp();
    _readDictation();
  }

  void _readApp() {
    final s = Settings.load();
    var queueModel = (s['model'] as String?) ?? '';
    final linked = (s[transcriberUsesDictationModelSetting] as bool?) ?? false;
    if (linked) {
      // Старое или вручную исправленное состояние могло оставить обе
      // стороны без собственного выбора. Материализуем уже сохранённый
      // путь у диктовки, чтобы ссылка никогда не стала циклом.
      if (_dictation.model.isEmpty && queueModel.isNotEmpty) {
        _dictation.model = queueModel;
        _dictation.save();
      }
      if (_dictation.model.isNotEmpty) queueModel = _dictation.model;
    }
    // Раньше форматы хранились расширениями («.txt») — переводим в имена.
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    final loggingEnabled = (s['loggingEnabled'] as bool?) ?? true;
    Log.enabled = loggingEnabled;
    _emit(
      state.copyWith(
        models: scanModels(),
        vad: findVadModel(),
        clearVadModel: findVadModel() == null,
        queueModel: queueModel,
        transcriberUsesDictationModel: linked,
        toLibrary: (s['toLibrary'] as bool?) ?? true,
        saveNextToSource: (s['saveNextToSource'] as bool?) ?? false,
        diarizeDefault: (s['diarize'] as bool?) ?? false,
        diarizationEmbedder: (s[diarizationEmbedderSetting] as String?) ?? '',
        timestamps: (s['timestamps'] as bool?) ?? true,
        dockIcon: (s['dockIcon'] as bool?) ?? true,
        loggingEnabled: loggingEnabled,
        libraryPath: (s['libraryPath'] as String?) ?? defaultLibraryPath,
        locale: (s[localeSetting] as String?) ?? '',
        theme: themeModeId(parseThemeMode(s[themeSetting] as String?)),
        apiEnabled: (s[apiEnabledSetting] as bool?) ?? false,
        apiKey: (s[apiKeySetting] as String?) ?? '',
        apiPort: (s[apiPortSetting] as int?) ?? apiPort,
        apiError: (s[apiErrorSetting] as String?) ?? '',
        libraryFormats: formats != null && formats.isNotEmpty
            ? formats
            : state.libraryFormats,
        copyFormat: _knownFormat(s['copyFormat']),
        saveFormat: _knownFormat(s['saveFormat']),
        vocabulary: loadAndMigrateVocabulary(s),
        vocabularyDictationEnabled:
            (s[vocabularyDictationEnabledSetting] as bool?) ??
            (s[dictationCommandsEnabledSetting] as bool?) ??
            true,
        vocabularyTranscriberEnabled:
            (s[vocabularyTranscriberEnabledSetting] as bool?) ??
            (s[transcriberCommandsEnabledSetting] as bool?) ??
            true,
        textCommands: textCommandsFromJson(s[textCommandsSetting]),
        dictationCommandsEnabled:
            (s[dictationCommandsEnabledSetting] as bool?) ??
            (s[vocabularyDictationEnabledSetting] as bool?) ??
            true,
        transcriberCommandsEnabled:
            (s[transcriberCommandsEnabledSetting] as bool?) ??
            (s[vocabularyTranscriberEnabledSetting] as bool?) ??
            true,
      ),
    );
    // Автозапуск держит система, а не наш файл: его можно выключить
    // и в системных настройках, и галка обязана это показывать.
    unawaited(
      bridge.loginItem().then((on) => _emit(state.copyWith(loginItem: on))),
    );
  }

  void _readDictation() {
    final profile = SpeakerProfile.load();
    final wakeExists =
        profile?.hasWakeTemplatesFor(_dictation.wakeWord) ?? false;
    final closeExists =
        profile?.hasCloseTemplatesFor(_dictation.closeWord) ?? false;
    final profileExists =
        wakeExists && (_dictation.closeWord.trim().isEmpty || closeExists);
    _emit(
      state.copyWith(
        hold: _dictation.hold,
        toggle: _dictation.toggle,
        cancel: _dictation.cancel,
        dictationModel: _dictation.model,
        threads: _dictation.threads,
        punctuate: _dictation.punctuate,
        prompt: _dictation.prompt,
        idleSeconds: _dictation.idleSeconds,
        insert: _dictation.insert,
        hud: _dictation.hud,
        indicatorMode: _dictation.indicatorMode,
        wakeWordEnabled: _dictation.wakeWordEnabled,
        wakeWord: _dictation.wakeWord,
        closeWord: _dictation.closeWord,
        completionMode: _dictation.completionMode,
        voiceCalibrationEnabled: _dictation.voiceCalibrationEnabled,
        speakerThreshold: _dictation.speakerThreshold,
        speakerProfileExists: profileExists,
        wakeProfileExists: wakeExists,
        closeProfileExists: closeExists,
      ),
    );
  }

  // ── запись на диск ────────────────────────────────────────────────────────

  /// Записи дожидаемся: соседи по «перечитать» тут же читают файл, и
  /// сказать им об этом раньше, чем правка на диске, значит послать их
  /// за старым значением.
  Future<void> _saveApp(Map<String, dynamic> data) async {
    await Settings.save(data);
    await bridge.settingsChanged();
  }

  Future<void> _saveAppSetting(String key, dynamic value) =>
      _saveApp({key: value});

  void _saveDictation(void Function(DictationSettings) change) {
    change(_dictation);
    _dictation.save();
    _readDictation();
    unawaited(bridge.settingsChanged());
  }

  // ── разрешения ────────────────────────────────────────────────────────────

  /// Окно настроек закрывается, а не размонтируется — движок живёт дальше
  /// (см. SettingsWindow.swift). Поэтому опрос заводится и глушится по
  /// видимости: иначе он тикал бы до выхода из приложения.
  void setVisible(bool visible) {
    if (visible == (_timer != null)) return;
    if (!visible) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    // Разрешение выдают в другом приложении и возвращаются к этому окну:
    // спрашивать надо самим, уведомления об этом нет.
    unawaited(checkPermission());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => checkPermission(),
    );
  }

  /// Тот же счёт отказов, что и в панели: сразу после запуска система
  /// отвечает «нет» и тем, у кого разрешение выдано, — верить одному
  /// ответу нельзя, иначе предупреждение мигает на ровном месте.
  @visibleForTesting
  Future<void> checkPermission() async {
    final now = await bridge.permission();
    if (now) {
      _denied = 0;
      return _emit(state.copyWith(allowed: true));
    }
    if (++_denied < 3) return;
    _emit(state.copyWith(allowed: false));
  }

  Future<void> requestPermission() => bridge.requestPermission();

  Future<void> openPermissionSettings() => bridge.openPermissionSettings();

  // ── диктовка ──────────────────────────────────────────────────────────────

  void setTab(String tab) => _emit(state.copyWith(tab: tab));

  /// Назначение сочетания: следующая нажатая комбинация становится новой.
  ///
  /// Одно и то же сочетание на оба действия назначить нельзя: «держать
  /// и говорить» и «нажать, ещё раз — остановить» тогда сработали бы
  /// вместе, и что из этого получится, не знает никто.
  Future<void> reassign(
    String id, {
    Future<bool> Function(Hotkey hotkey)? confirmExclusive,
  }) async {
    if (os.needsAccessibilityPermission && !await bridge.permission()) {
      _denied = 3;
      _emit(
        state.copyWith(
          allowed: false,
          problem: currentL10n().permissionMissing(
            os.accessibilityName,
            appName,
          ),
        ),
      );
      await bridge.requestPermission();
      return;
    }
    final hk = await bridge.capture();
    if (hk == null) return;
    final taken = {
      'hold': _dictation.hold,
      'toggle': _dictation.toggle,
      'cancel': _dictation.cancel,
    }..remove(id);
    if (taken.values.any((other) => !other.empty && hk.sameAs(other))) {
      return _emit(
        state.copyWith(problem: currentL10n().hotkeyTakenProblem(hk.label)),
      );
    }
    if (hk.requiresExclusiveConsent &&
        !(await confirmExclusive?.call(hk) ?? false)) {
      return;
    }
    _emit(state.copyWith(clearProblem: true));
    _saveDictation(
      (d) => switch (id) {
        'hold' => d.hold = hk,
        'cancel' => d.cancel = hk,
        _ => d.toggle = hk,
      },
    );
  }

  /// Снять сочетание совсем. Есть только у «бросить»: без «держать
  /// и говорить» и «включить» диктовки нет вовсе, а бросать начатое можно
  /// и мышью — по крестику на плавающей панели.
  void clearCancelHotkey() => _saveDictation((d) => d.cancel = Hotkey.none);

  Future<void> setDictationModel(String path) async {
    if (path.isEmpty && state.transcriberUsesDictationModel) {
      // Меняем направление связи: нынешняя общая модель становится
      // конкретной у расшифровщика, а диктовка начинает следовать ей.
      _emit(state.copyWith(transcriberUsesDictationModel: false));
      await _saveApp({
        'model': state.queueModel,
        transcriberUsesDictationModelSetting: false,
      });
    }
    _saveDictation((d) => d.model = path);
    if (path.isNotEmpty && state.transcriberUsesDictationModel) {
      _emit(state.copyWith(queueModel: path));
      await _saveApp({'model': path});
    }
  }

  /// Модель для всех новых расшифровок. Открытая запись по-прежнему хранит
  /// собственный выбор, но главное окно перечитает это значение как новое
  /// умолчание через тот же канал настроек.
  Future<void> setQueueModel(String path) async {
    if (path.isEmpty) {
      var anchor = _dictation.model;
      if (anchor.isEmpty) {
        anchor = state.queueModel;
        if (anchor.isEmpty) return;
        _saveDictation((d) => d.model = anchor);
      }
      _emit(
        state.copyWith(queueModel: anchor, transcriberUsesDictationModel: true),
      );
      await _saveApp({
        'model': anchor,
        transcriberUsesDictationModelSetting: true,
      });
      return;
    }
    _emit(
      state.copyWith(queueModel: path, transcriberUsesDictationModel: false),
    );
    await _saveApp({
      'model': path,
      transcriberUsesDictationModelSetting: false,
    });
  }

  void setThreads(int n) => _saveDictation((d) => d.threads = n);

  void setPunctuate(bool v) => _saveDictation((d) => d.punctuate = v);

  void setPrompt(String v) => _saveDictation((d) => d.prompt = v);

  void setIdleSeconds(int v) => _saveDictation((d) => d.idleSeconds = v);

  void setInsert(bool v) => _saveDictation((d) => d.insert = v);

  void setHud(bool v) => _saveDictation((d) => d.hud = v);

  void setWakeWordEnabled(bool v) => _saveDictation((d) {
    d.wakeWordEnabled = v;
    if (v && state.speakerProfileExists) d.voiceCalibrationEnabled = true;
  });

  void setWakeWord(String v) =>
      _saveDictation((d) => d.wakeWord = v.trim().isEmpty ? 'Джеф' : v);

  void setCloseWord(String v) => _saveDictation((d) => d.closeWord = v);

  void setCompletionMode(PhraseCompletionMode mode) =>
      _saveDictation((d) => d.completionMode = mode);

  void setVoiceCalibrationEnabled(bool v) =>
      _saveDictation((d) => d.voiceCalibrationEnabled = v);

  void setSpeakerThreshold(double v) =>
      _saveDictation((d) => d.speakerThreshold = v);

  void deleteSpeakerProfile() {
    SpeakerProfile.delete();
    _saveDictation((d) => d.voiceCalibrationEnabled = false);
  }

  void deleteWakeProfile() {
    final profile = SpeakerProfile.load();
    profile?.clearWakeCalibration();
    _saveDictation((d) {
      final remaining = SpeakerProfile.load();
      if (remaining == null || !remaining.hasWakeTemplatesFor(d.wakeWord)) {
        d.voiceCalibrationEnabled = false;
      }
    });
  }

  void deleteCloseProfile() {
    final profile = SpeakerProfile.load();
    profile?.clearCloseCalibration();
    _saveDictation((d) {});
  }

  void refreshSpeakerProfile() {
    _saveDictation((d) => d.voiceCalibrationEnabled = true);
  }

  void setDictationCommandsEnabled(bool value) =>
      setVocabularyDictationEnabled(value);

  // ── модели ────────────────────────────────────────────────────────────────

  /// Взять своим файлом модель диктовки.
  ///
  /// Именно диктовки: у расшифровщика такой же выбор есть в инспекторе
  /// главного окна, и кнопка на эту сторону стоит рядом с моделью
  /// диктовки, а не в общем списке моделей — там было непонятно, кому
  /// достаётся выбранный файл.
  ///
  /// Выбранный руками файл проверяем: «.bin» бывает чем угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры.
  void pickModel(String path) {
    final problem = modelFileProblem(path);
    if (problem != null) return _emit(state.copyWith(problem: problem));
    // Файл мог лежать за пределами обеих наших папок — тогда обход его
    // не найдёт, и в списке он появится только так.
    final known = state.models.any((m) => m.path == path);
    _emit(
      state.copyWith(
        clearProblem: true,
        models: known
            ? state.models
            : [
                ...state.models,
                InstalledModel(
                  path: path,
                  sizeBytes: File(path).existsSync()
                      ? File(path).lengthSync()
                      : 0,
                  problem: null,
                  ours: false,
                ),
              ],
      ),
    );
    setDictationModel(path);
  }

  /// Одна загрузка на окно: два полуторагиговых файла разом только мешают
  /// друг другу.
  Future<String?> download(ModelOffer m) async {
    if (_download != null) return null;
    final d = Download(m.url, m.path, title: m.title);
    _download = d;
    _emit(
      state.copyWith(
        downloadTitle: d.title,
        downloadProgress: d.progressLabel,
        downloadPercent: d.percent,
      ),
    );
    final path = await d.run(
      onProgress: () {
        _emit(
          state.copyWith(
            downloadProgress: d.progressLabel,
            downloadPercent: d.percent,
          ),
        );
      },
    );
    _download = null;
    _emit(
      state.copyWith(
        clearDownload: true,
        models: path != null ? scanModels() : null,
        vad: findVadModel(),
        clearVadModel: findVadModel() == null,
      ),
    );
    // Список моделей стал другим — соседним окнам надо его перечитать.
    if (path != null) unawaited(bridge.settingsChanged());
    return path;
  }

  /// Выбор пункта из выпадающего списка — одно действие: недостающий файл
  /// сначала приезжает, затем именно он становится активным. Раньше после
  /// загрузки список обновлялся, но продолжала работать прежняя модель.
  Future<void> downloadForTranscription(ModelOffer m) async {
    final path = await download(m);
    if (path != null) setQueueModel(path);
  }

  Future<void> downloadForDictation(ModelOffer m) async {
    final path = await download(m);
    if (path != null) setDictationModel(path);
  }

  void cancelDownload() => _download?.cancel();

  // ── расшифровщик и приложение ─────────────────────────────────────────────

  void setToLibrary(bool v) {
    _emit(state.copyWith(toLibrary: v));
    unawaited(_saveApp({'toLibrary': v}));
  }

  void setSaveNextToSource(bool v) {
    _emit(state.copyWith(saveNextToSource: v));
    unawaited(_saveApp({'saveNextToSource': v}));
  }

  /// Ключ тот же, что у общих настроек распознавания (`RunOptions.diarize`):
  /// главное окно перечитает его и поставит в свои умолчания.
  void setDiarizeDefault(bool v) {
    _emit(state.copyWith(diarizeDefault: v));
    unawaited(_saveApp({'diarize': v}));
  }

  void setDiarizationEmbedder(String id) {
    _emit(state.copyWith(diarizationEmbedder: id));
    unawaited(_saveApp({diarizationEmbedderSetting: id}));
  }

  void setTimestamps(bool v) {
    _emit(state.copyWith(timestamps: v));
    unawaited(_saveApp({'timestamps': v}));
  }

  void setVocabularyDictationEnabled(bool value) {
    _emit(
      state.copyWith(
        vocabularyDictationEnabled: value,
        dictationCommandsEnabled: value,
      ),
    );
    unawaited(
      _saveApp({
        vocabularyDictationEnabledSetting: value,
        dictationCommandsEnabledSetting: value,
      }),
    );
  }

  void setVocabularyTranscriberEnabled(bool value) {
    _emit(
      state.copyWith(
        vocabularyTranscriberEnabled: value,
        transcriberCommandsEnabled: value,
      ),
    );
    unawaited(
      _saveApp({
        vocabularyTranscriberEnabledSetting: value,
        transcriberCommandsEnabledSetting: value,
      }),
    );
  }

  void setTranscriberCommandsEnabled(bool value) =>
      setVocabularyTranscriberEnabled(value);

  VocabularyItem? _lastDeletedItem;
  int? _lastDeletedIndex;

  VocabularyItem? get lastDeletedItem => _lastDeletedItem;

  void addVocabularyItem(String phrase, [String replacement = '']) {
    if (phrase.trim().isEmpty) return;
    _saveVocabulary(
      upsertVocabulary(state.vocabulary, phrase, replacement: replacement),
    );
  }

  void updateVocabularyItem(int index, VocabularyItem item) {
    if (index < 0 || index >= state.vocabulary.length) return;
    final items = [...state.vocabulary]..[index] = item;
    _saveVocabulary(items);
  }

  void removeVocabularyItem(int index) {
    if (index < 0 || index >= state.vocabulary.length) return;
    _lastDeletedIndex = index;
    _lastDeletedItem = state.vocabulary[index];
    final items = [...state.vocabulary]..removeAt(index);
    _saveVocabulary(items);
  }

  void toggleVocabularyItem(int index, bool enabled) {
    if (index < 0 || index >= state.vocabulary.length) return;
    final updated = state.vocabulary[index].copyWith(enabled: enabled);
    updateVocabularyItem(index, updated);
  }

  void setAllVocabularyEnabled(bool enabled) {
    if (state.vocabulary.isEmpty) return;
    final items = state.vocabulary
        .map((i) => i.copyWith(enabled: enabled))
        .toList();
    _saveVocabulary(items);
  }

  void clearAllVocabularyPriorities() {
    if (state.vocabulary.isEmpty) return;
    final items = state.vocabulary
        .map((i) => i.copyWith(isPriority: false))
        .toList();
    _saveVocabulary(items);
  }

  void undoDeleteVocabularyItem() {
    final item = _lastDeletedItem;
    if (item == null) return;
    final index = _lastDeletedIndex ?? state.vocabulary.length;
    final items = [...state.vocabulary];
    if (index >= 0 && index <= items.length) {
      items.insert(index, item);
    } else {
      items.add(item);
    }
    _lastDeletedItem = null;
    _lastDeletedIndex = null;
    _saveVocabulary(items);
  }

  void addTextCommand() {
    final item = VocabularyItem(
      id: 'cmd_${DateTime.now().microsecondsSinceEpoch}',
      phrase: '',
      replacement: '',
      enabled: true,
      createdAt: DateTime.now(),
    );
    _saveVocabulary([...state.vocabulary, item]);
  }

  void updateTextCommand(int index, TextCommand command) {
    if (index < 0 || index >= state.vocabulary.length) return;
    final prev = state.vocabulary[index];
    final updated = prev.copyWith(
      phrase: command.phrase,
      replacement: command.replacement,
    );
    updateVocabularyItem(index, updated);
  }

  void removeTextCommand(int index) => removeVocabularyItem(index);

  void _saveVocabulary(List<VocabularyItem> items) {
    final textCommands = items
        .where((i) => i.isReplacement)
        .map((i) => i.toTextCommand())
        .toList();
    _emit(state.copyWith(vocabulary: items, textCommands: textCommands));
    unawaited(
      _saveApp({
        vocabularySetting: items.map((i) => i.toJson()).toList(),
        textCommandsSetting: textCommands.map((c) => c.toJson()).toList(),
      }),
    );
  }

  /// Язык интерфейса. Своё окно перерисовываем сразу, соседние узнают
  /// из общего файла: [refreshLocale] вызывается у всех на «reload».
  void setLocale(String v) {
    _emit(state.copyWith(locale: v));
    appLocale.value = v.isEmpty ? null : Locale(v);
    unawaited(_saveApp({localeSetting: v}));
  }

  /// Тема окон. Как и язык: своё окно сразу, соседние — по «reload».
  ///
  /// Системе — раньше Flutter: на macOS она вешает на окна затухание, и
  /// перерисовка Flutter должна попасть уже внутрь него.
  void setTheme(String v) {
    final mode = parseThemeMode(v);
    final id = themeModeId(mode);
    _emit(state.copyWith(theme: id));
    unawaited(NativeBridge.setWindowTheme(id)
        .whenComplete(() => appThemeMode.value = mode));
    unawaited(_saveApp({themeSetting: id}));
  }

  /// Включить или выключить местное API.
  ///
  /// Ключ рождается здесь же, при включении, и умирает при выключении.
  /// Отдельной кнопки «сменить ключ» поэтому нет: выключил-включил — ключ
  /// новый, старый не работает. Сам сервер поднимает главное окно: оно
  /// узнает о правке из общего файла настроек.
  void setApiEnabled(bool v) {
    final key = v ? newApiKey() : '';
    _emit(state.copyWith(apiEnabled: v, apiKey: key, apiError: ''));
    unawaited(
      _saveApp({apiEnabledSetting: v, apiKeySetting: key, apiErrorSetting: ''}),
    );
  }

  /// Поставить скилл найденным агентам.
  ///
  /// Пишем в чужие настройки — в `~/.claude/skills` и соседние, — поэтому
  /// только по нажатию и только тем, кто действительно стоит. Текст берём
  /// из самого приложения: скилл зовёт `tsukiko-transcribe`, который лежит
  /// рядом, и разъехаться их версии не должны.
  Future<void> installSkillToAgents(List<AgentTarget> targets) async {
    if (targets.isEmpty) return;
    try {
      final text = await rootBundle.loadString('skills/tsukiko/SKILL.md');
      _emit(state.copyWith(skillResult: installSkill(targets, text)));
    } catch (e) {
      stderr.writeln('tsukiko: скилл не поставился — $e');
      _emit(
        state.copyWith(
          skillResult: {for (final t in targets) t.id: SkillOutcome.failed},
        ),
      );
    }
  }

  void setDockIcon(bool v) {
    _emit(state.copyWith(dockIcon: v));
    unawaited(_saveApp({'dockIcon': v}));
    unawaited(bridge.setDockIcon(v));
  }

  void setLoggingEnabled(bool v) {
    Log.enabled = v;
    _emit(state.copyWith(loggingEnabled: v));
    unawaited(_saveAppSetting('loggingEnabled', v));
  }

  /// Ответ берём у системы, а не у себя: она могла и отказать.
  Future<void> setLoginItem(bool v) async {
    final on = await bridge.loginItem(v);
    _emit(state.copyWith(loginItem: on));
  }

  void setLibraryPath(String dir) {
    final trimmed = dir.trim();
    if (trimmed.isEmpty) return;
    _emit(state.copyWith(libraryPath: trimmed));
    unawaited(_saveApp({'libraryPath': trimmed}));
  }

  /// Пустой набор при включённом сохранении означал бы тишину, поэтому
  /// последний формат снять нельзя.
  void toggleFormat(String id, bool on) {
    final next = [...state.libraryFormats];
    on ? next.add(id) : next.remove(id);
    final formats = next.isEmpty ? [id] : next;
    _emit(state.copyWith(libraryFormats: formats));
    unawaited(_saveApp({'libraryFormats': formats}));
  }

  void setCopyFormat(String id) {
    final format = _knownFormat(id);
    _emit(state.copyWith(copyFormat: format));
    unawaited(_saveApp({'copyFormat': format}));
  }

  void setSaveFormat(String id) {
    final format = _knownFormat(id);
    _emit(state.copyWith(saveFormat: format));
    unawaited(_saveApp({'saveFormat': format}));
  }

  static String _knownFormat(Object? id) =>
      exportFormats.any((format) => format.id == id)
      ? id as String
      : formatPlainText.id;

  /// Убрать модель в Корзину.
  ///
  /// Не `unlink`: полтора гигабайта, стёртые по промаху, качать заново.
  /// Из Корзины файл возвращается средствами самой системы.
  ///
  /// Спрашивать здесь нечего — вопрос задаёт окно, кубит получает уже
  /// принятое решение.
  Future<void> deleteModel(String path) async {
    final gone = await bridge.trash(path);
    if (!gone) {
      return _emit(
        state.copyWith(problem: currentL10n().modelTrashFailed(path)),
      );
    }
    final models = scanModels();
    final usable = [
      for (final model in models)
        if (!model.broken) model.path,
    ];
    // Выбранной эта модель быть больше не может.
    if (state.transcriberUsesDictationModel &&
        (_dictation.model == path || state.queueModel == path)) {
      final replacement = usable.isEmpty ? '' : usable.first;
      _saveDictation((d) => d.model = replacement);
      _emit(
        state.copyWith(
          queueModel: replacement,
          transcriberUsesDictationModel: replacement.isNotEmpty,
        ),
      );
      await _saveApp({
        'model': replacement,
        transcriberUsesDictationModelSetting: replacement.isNotEmpty,
      });
    } else if (_dictation.model == path) {
      _saveDictation((d) => d.model = '');
    }
    if (!state.transcriberUsesDictationModel && state.queueModel == path) {
      _emit(
        state.copyWith(queueModel: '', transcriberUsesDictationModel: false),
      );
      await _saveApp({
        'model': '',
        transcriberUsesDictationModelSetting: false,
      });
    }
    _emit(
      state.copyWith(
        clearProblem: true,
        models: models,
        vad: findVadModel(),
        clearVadModel: findVadModel() == null,
      ),
    );
    // Список моделей стал другим — соседним окнам надо его перечитать.
    unawaited(bridge.settingsChanged());
  }

  /// Показать папку моделей в проводнике: где они лежат, из интерфейса
  /// иначе не узнать. Папки может ещё не быть — заводим.
  Future<void> revealModelsFolder() =>
      revealInFinder(os.modelsDir, createIfMissing: true);

  /// Папку библиотеки человек мог ещё ни разу не наполнить.
  Future<void> revealLibrary(String path) =>
      revealInFinder(path, createIfMissing: true);

  /// Показать файл модели. Файл мог исчезнуть мимо приложения — тогда
  /// говорим об этом и обновляем список, а не открываем пустоту.
  Future<void> revealModel(String path) async {
    if (await revealInFinder(path)) return;
    _emit(
      state.copyWith(
        problem: currentL10n().modelFileGone(os.basename(path)),
        models: scanModels(),
        vad: findVadModel(),
        clearVadModel: findVadModel() == null,
      ),
    );
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    return super.close();
  }
}
