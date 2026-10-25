import 'dart:io';

import 'package:equatable/equatable.dart';

import '../../core/app_locale.dart';
import '../../core/indicator_mode.dart';
import '../../core/models.dart';
import '../../core/skill_install.dart';
import '../../core/text_commands.dart';
import '../../core/vocabulary.dart';
import '../../core/whisper_server.dart' show Hotkey, PhraseCompletionMode;

/// Сколько потоков предложить на выбор.
///
/// Список — чётные до числа ядер, но нынешнее значение в нём обязано быть
/// всегда, даже если оно из этого ряда выпадает. Иначе выпадающий список
/// macos_ui падает с «нет пункта с таким значением», и окно настроек
/// не открывается вовсе.
///
/// Выпасть значение может запросто: настройки переехали с машины,
/// где ядер было больше, или их правили руками в файле.
List<int> threadChoices(int current) {
  final out = <int>{
    for (var t = 2; t <= Platform.numberOfProcessors; t += 2) t,
    if (current > 0) current,
  }.toList()..sort();
  return out;
}

/// Всё, что видно в окне настроек, — одним неизменяемым снимком.
///
/// От `DictationSettings` здесь лежат разобранные значения, а не сам
/// объект: он меняется внутри себя, и сравнение снимков такую правку
/// не заметило бы — окно замирало бы на устаревшем виде.
class SettingsState extends Equatable {
  /// Не `const`: сочетания по умолчанию у каждой системы свои, а `const`
  /// про систему знать не может.
  SettingsState({
    this.tab = 'transcriber',
    this.models = const [],
    this.vad,
    this.downloadTitle,
    this.downloadProgress,
    this.downloadPercent = 0,
    this.problem,
    this.allowed = true,
    // диктовка
    this.skillResult = const {},
    Hotkey? hold,
    Hotkey? toggle,
    Hotkey? cancel,
    this.dictationModel = '',
    this.queueModel = '',
    this.transcriberUsesDictationModel = false,
    this.threads = 4,
    this.punctuate = true,
    this.prompt = '',
    this.textCommands = const [],
    this.dictationCommandsEnabled = true,
    this.transcriberCommandsEnabled = true,
    this.vocabulary = const [],
    this.vocabularyDictationEnabled = true,
    this.vocabularyTranscriberEnabled = true,
    this.idleSeconds = 180,
    this.insert = true,
    this.hud = true,
    this.indicatorMode = IndicatorMode.panel,
    this.wakeWordEnabled = false,
    this.wakeWord = 'Джеф',
    this.closeWord = '',
    this.completionMode = PhraseCompletionMode.hybrid,
    this.voiceCalibrationEnabled = false,
    this.speakerProfileExists = false,
    this.wakeProfileExists = false,
    this.closeProfileExists = false,
    this.speakerThreshold = 0.60,
    this.ownVoiceOnly = false,
    this.ownVoiceThreshold = 0.45,
    this.ownVoiceRecordedAt,
    this.ownVoiceSpeechMs = 0,
    // приложение
    this.toLibrary = true,
    this.saveNextToSource = false,
    this.diarizeDefault = false,
    this.timestamps = true,
    this.dockIcon = true,
    this.loginItem = false,
    this.libraryPath = '',
    this.libraryFormats = const ['txt'],
    this.copyFormat = 'txt',
    this.saveFormat = 'txt',
    this.locale = '',
    this.theme = '',
    this.loggingEnabled = true,
    this.apiEnabled = false,
    this.apiKey = '',
    this.apiPort = 0,
    this.apiError = '',
  }) : hold = hold ?? Hotkey.holdDefault,
       toggle = toggle ?? Hotkey.toggleDefault,
       cancel = cancel ?? Hotkey.none;

  /// Какая вкладка открыта. Приходит и снаружи: окно могут попросить
  /// открыться сразу на «Моделях».
  final String tab;

  /// Что лежит на диске: со своим размером и с отметкой, цел ли файл.
  final List<InstalledModel> models;

  /// Модель распознавания пауз, если она загружена. Речью не занимается,
  /// поэтому в общем списке ей не место — но и молчать о ней нельзя.
  final InstalledModel? vad;

  /// Пути годных моделей — для выпадающих списков.
  List<String> get usable => [
    for (final m in models)
      if (!m.broken) m.path,
  ];

  /// Модель по умолчанию для новых расшифровок. Открытая запись может
  /// иметь собственную, поэтому выбор здесь не переписывает её задним числом.
  final String queueModel;

  /// В поле расшифровщика пустое значение означает ссылку на диктовку,
  /// но [queueModel] всегда содержит уже разрешённый конкретный путь.
  final bool transcriberUsesDictationModel;
  String get transcriberModelSelection =>
      transcriberUsesDictationModel ? '' : queueModel;

  /// Какой моделью распознаётся диктовка на самом деле — с учётом того,
  /// что пустой выбор означает «взять у расшифровщика».
  String get dictationModelInUse =>
      dictationModel.isNotEmpty ? dictationModel : queueModel;

  /// Кому служит модель [path]: подпись для строки списка. Пусто — никому.
  String? userOf(String path) {
    final forDictation = path == dictationModelInUse;
    final forQueue = path == queueModel;
    final l10n = currentL10n();
    if (forDictation && forQueue) return l10n.usedByBoth;
    if (forQueue) return l10n.usedByTranscription;
    if (forDictation) return l10n.usedByDictation;
    return null;
  }

  /// Идущая загрузка модели: подпись, ход строкой и процент. Самого
  /// загрузчика здесь нет — он меняется внутри себя.
  final String? downloadTitle, downloadProgress;
  final int downloadPercent;

  /// Почему выбранный руками файл не годится в модель. Пусто — годится.
  final String? problem;

  /// Выдано ли разрешение на перехват клавиш и вставку текста.
  final bool allowed;

  // ── диктовка ──────────────────────────────────────────────────────────────

  final Hotkey hold, toggle;

  /// «Бросить начатое». По умолчанию не назначено: действие редкое,
  /// а занятое сочетание отнимается у чужих программ навсегда.
  final Hotkey cancel;

  /// То из двух сочетаний, которое лежит на дороге ко второму, — или null,
  /// если такой беды нет.
  ///
  /// Клавиши нажимаются по одной, и сочетание, целиком входящее в другое,
  /// срабатывает раньше: «Ctrl+Alt» на «держать» вместе с «Ctrl+Alt+Пробел»
  /// на «включить» начинали запись, не дожидаясь пробела. Умолчания такой
  /// пары больше не дают, но назначить её руками никто не мешает — значит
  /// об этом надо сказать. Считается из самого состояния, а не в миг
  /// назначения: беда живёт, пока стоит эта пара, а не одно мгновение.
  Hotkey? get shadowingHotkey {
    for (final a in [hold, toggle, cancel]) {
      for (final b in [hold, toggle, cancel]) {
        if (identical(a, b)) continue;
        if (a.isPrefixOf(b)) return a;
      }
    }
    return null;
  }

  /// Второе из пары, на дороге к которому лежит [shadowingHotkey].
  Hotkey? get shadowedHotkey {
    final early = shadowingHotkey;
    if (early == null) return null;
    for (final b in [hold, toggle, cancel]) {
      if (!identical(early, b) && early.isPrefixOf(b)) return b;
    }
    return null;
  }

  /// Модель диктовки. Пусто — «та же, что у расшифровщика».
  final String dictationModel;

  final int threads;
  final bool punctuate;
  final String prompt;
  final List<TextCommand> textCommands;
  final bool dictationCommandsEnabled, transcriberCommandsEnabled;
  final List<VocabularyItem> vocabulary;
  final bool vocabularyDictationEnabled, vocabularyTranscriberEnabled;
  final int idleSeconds;
  final bool insert, hud;
  final IndicatorMode indicatorMode;
  final bool wakeWordEnabled;
  final String wakeWord;
  final String closeWord;
  final PhraseCompletionMode completionMode;
  final bool voiceCalibrationEnabled;
  final bool speakerProfileExists;
  final bool wakeProfileExists;
  final bool closeProfileExists;
  final double speakerThreshold;

  /// «Только мой голос» в диктовке и записанный образец голоса. Нет даты —
  /// образца нет, и включать фильтр не по чему.
  final bool ownVoiceOnly;
  final double ownVoiceThreshold;
  final DateTime? ownVoiceRecordedAt;
  final int ownVoiceSpeechMs;

  // ── приложение ────────────────────────────────────────────────────────────

  final bool toLibrary, saveNextToSource, timestamps, dockIcon;

  /// «Несколько голосов» в новых расшифровках — то же значение, что
  /// инспектор главного окна правит, когда в очереди ничего не выбрано.
  final bool diarizeDefault;


  /// Автозапуск живёт в системе, а не в settings.json: его можно выключить
  /// в системных настройках мимо нас.
  final bool loginItem;

  final String libraryPath;
  final List<String> libraryFormats;

  /// Форматы двух явных действий в главном окне. Набор автоматического
  /// сохранения выше — отдельная настройка: там файлов может быть несколько,
  /// а одно нажатие «Копировать» или «Сохранить» всегда выбирает один.
  final String copyFormat, saveFormat;

  /// Язык интерфейса: 'ru', 'en' или пусто — «как в системе». Язык речи
  /// это не задаёт: его выбирают отдельно, в инспекторе записи.
  final String locale;

  /// Тема окон: 'light', 'dark' или пусто — «как в системе».
  final String theme;
  final bool loggingEnabled;

  // ── местное API ───────────────────────────────────────────────────────────

  /// Слушает ли приложение 127.0.0.1 и с каким ключом. Сервер поднимает
  /// не это окно, а изолят главного окна — здесь галка и ключ только
  /// хранятся и показываются.
  final bool apiEnabled;
  final String apiKey;

  /// Чем кончилась последняя установка скилла: агент → что с ним стало.
  /// Пусто — ещё не ставили. Держим в состоянии, а не в окне: окно
  /// перерисовывается, а сказанное человеку пропадать не должно.
  final Map<String, SkillOutcome> skillResult;

  /// На каком порту приложение слушает. В окне его не меняют, но назвать
  /// обязаны: без номера порта подсказка «обратитесь к 127.0.0.1» ничего
  /// не значит.
  final int apiPort;

  /// Почему API не поднялось. Пусто — поднялось. Пишет сюда главное окно:
  /// занятый порт видно только оттуда, а сказать о нём надо тому, кто
  /// щёлкнул галку.
  final String apiError;

  bool get downloading => downloadProgress != null;

  SettingsState copyWith({
    Map<String, SkillOutcome>? skillResult,
    String? tab,
    List<InstalledModel>? models,
    InstalledModel? vad,
    bool clearVadModel = false,
    String? downloadTitle,
    String? downloadProgress,
    int? downloadPercent,
    String? problem,
    bool? allowed,
    Hotkey? hold,
    Hotkey? toggle,
    Hotkey? cancel,
    String? dictationModel,
    String? queueModel,
    bool? transcriberUsesDictationModel,
    int? threads,
    bool? punctuate,
    String? prompt,
    List<TextCommand>? textCommands,
    bool? dictationCommandsEnabled,
    bool? transcriberCommandsEnabled,
    List<VocabularyItem>? vocabulary,
    bool? vocabularyDictationEnabled,
    bool? vocabularyTranscriberEnabled,
    int? idleSeconds,
    bool? insert,
    bool? hud,
    IndicatorMode? indicatorMode,
    bool? wakeWordEnabled,
    String? wakeWord,
    String? closeWord,
    PhraseCompletionMode? completionMode,
    bool? voiceCalibrationEnabled,
    bool? speakerProfileExists,
    bool? wakeProfileExists,
    bool? closeProfileExists,
    double? speakerThreshold,
    bool? ownVoiceOnly,
    double? ownVoiceThreshold,
    DateTime? ownVoiceRecordedAt,
    int? ownVoiceSpeechMs,
    bool clearOwnVoice = false,
    bool? toLibrary,
    bool? saveNextToSource,
    bool? diarizeDefault,
    bool? timestamps,
    bool? dockIcon,
    bool? loginItem,
    String? libraryPath,
    List<String>? libraryFormats,
    String? copyFormat,
    String? saveFormat,
    String? locale,
    String? theme,
    bool? loggingEnabled,
    bool? apiEnabled,
    String? apiKey,
    int? apiPort,
    String? apiError,
    // Обнулять поля иначе нечем: `null` в именованном параметре
    // не отличить от «не передали».
    bool clearDownload = false,
    bool clearProblem = false,
  }) => SettingsState(
    tab: tab ?? this.tab,
    models: models ?? this.models,
    vad: clearVadModel ? null : (vad ?? this.vad),
    downloadTitle: clearDownload ? null : (downloadTitle ?? this.downloadTitle),
    downloadProgress: clearDownload
        ? null
        : (downloadProgress ?? this.downloadProgress),
    downloadPercent: clearDownload
        ? 0
        : (downloadPercent ?? this.downloadPercent),
    problem: clearProblem ? null : (problem ?? this.problem),
    allowed: allowed ?? this.allowed,
    hold: hold ?? this.hold,
    toggle: toggle ?? this.toggle,
    cancel: cancel ?? this.cancel,
    dictationModel: dictationModel ?? this.dictationModel,
    queueModel: queueModel ?? this.queueModel,
    transcriberUsesDictationModel:
        transcriberUsesDictationModel ?? this.transcriberUsesDictationModel,
    threads: threads ?? this.threads,
    punctuate: punctuate ?? this.punctuate,
    prompt: prompt ?? this.prompt,
    textCommands: textCommands ?? this.textCommands,
    dictationCommandsEnabled:
        dictationCommandsEnabled ?? this.dictationCommandsEnabled,
    transcriberCommandsEnabled:
        transcriberCommandsEnabled ?? this.transcriberCommandsEnabled,
    vocabulary: vocabulary ?? this.vocabulary,
    vocabularyDictationEnabled:
        vocabularyDictationEnabled ?? this.vocabularyDictationEnabled,
    vocabularyTranscriberEnabled:
        vocabularyTranscriberEnabled ?? this.vocabularyTranscriberEnabled,
    idleSeconds: idleSeconds ?? this.idleSeconds,
    insert: insert ?? this.insert,
    hud: hud ?? this.hud,
    indicatorMode: indicatorMode ?? this.indicatorMode,
    wakeWordEnabled: wakeWordEnabled ?? this.wakeWordEnabled,
    wakeWord: wakeWord ?? this.wakeWord,
    closeWord: closeWord ?? this.closeWord,
    completionMode: completionMode ?? this.completionMode,
    voiceCalibrationEnabled:
        voiceCalibrationEnabled ?? this.voiceCalibrationEnabled,
    speakerProfileExists: speakerProfileExists ?? this.speakerProfileExists,
    wakeProfileExists: wakeProfileExists ?? this.wakeProfileExists,
    closeProfileExists: closeProfileExists ?? this.closeProfileExists,
    speakerThreshold: speakerThreshold ?? this.speakerThreshold,
    ownVoiceOnly: ownVoiceOnly ?? this.ownVoiceOnly,
    ownVoiceThreshold: ownVoiceThreshold ?? this.ownVoiceThreshold,
    ownVoiceRecordedAt: clearOwnVoice
        ? null
        : (ownVoiceRecordedAt ?? this.ownVoiceRecordedAt),
    ownVoiceSpeechMs: clearOwnVoice
        ? 0
        : (ownVoiceSpeechMs ?? this.ownVoiceSpeechMs),
    toLibrary: toLibrary ?? this.toLibrary,
    saveNextToSource: saveNextToSource ?? this.saveNextToSource,
    diarizeDefault: diarizeDefault ?? this.diarizeDefault,
    timestamps: timestamps ?? this.timestamps,
    dockIcon: dockIcon ?? this.dockIcon,
    loginItem: loginItem ?? this.loginItem,
    libraryPath: libraryPath ?? this.libraryPath,
    libraryFormats: libraryFormats ?? this.libraryFormats,
    copyFormat: copyFormat ?? this.copyFormat,
    saveFormat: saveFormat ?? this.saveFormat,
    locale: locale ?? this.locale,
    theme: theme ?? this.theme,
    loggingEnabled: loggingEnabled ?? this.loggingEnabled,
    apiEnabled: apiEnabled ?? this.apiEnabled,
    apiKey: apiKey ?? this.apiKey,
    skillResult: skillResult ?? this.skillResult,
    apiPort: apiPort ?? this.apiPort,
    apiError: apiError ?? this.apiError,
  );

  @override
  List<Object?> get props => [
    tab,
    models,
    vad,
    downloadTitle,
    downloadProgress,
    downloadPercent,
    problem,
    allowed,
    hold.label,
    toggle.label,
    cancel.label,
    dictationModel,
    queueModel,
    transcriberUsesDictationModel,
    threads,
    punctuate,
    prompt,
    textCommands.map((command) => command.toJson()).toList(),
    dictationCommandsEnabled,
    transcriberCommandsEnabled,
    vocabulary.map((item) => item.toJson()).toList(),
    vocabularyDictationEnabled,
    vocabularyTranscriberEnabled,
    idleSeconds,
    insert,
    hud,
    indicatorMode,
    wakeWordEnabled,
    wakeWord,
    closeWord,
    completionMode,
    voiceCalibrationEnabled,
    speakerProfileExists,
    wakeProfileExists,
    closeProfileExists,
    speakerThreshold,
    ownVoiceOnly,
    ownVoiceThreshold,
    ownVoiceRecordedAt,
    ownVoiceSpeechMs,
    toLibrary,
    saveNextToSource,
    diarizeDefault,
    timestamps,
    dockIcon,
    loginItem,
    libraryPath,
    libraryFormats,
    copyFormat,
    saveFormat,
    locale,
    theme,
    loggingEnabled,
    apiEnabled,
    apiKey,
    skillResult,
    apiPort,
    apiError,
  ];
}
