import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' show IsolateNameServer;

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/app_locale.dart';
import '../../core/diarization/diarization_models.dart';
import '../../core/diarization/diarizer.dart';
import '../../core/diarization/wav_samples.dart';
import '../../core/library.dart';
import '../../core/logger.dart';
import '../../core/models.dart';
import '../../core/recognition.dart';
import '../../core/settings.dart';
import '../../core/text.dart';
import '../../core/text_commands.dart';
import '../../core/transcript.dart';
import '../../core/vocabulary.dart';
import '../../core/whisper.dart';
import '../../core/whisper_server.dart'
    show forgetRecognizerPid, rememberRecognizerPid;
import '../api/api_server.dart';
import '../dictation/dictation_repository.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'job.dart';
import 'queue_event.dart';
import 'queue_state.dart';
import '../../core/labels.dart';

/// Очередь распознавания: что в списке, что из него выбрано, что сейчас
/// считается и куда ложится результат.
///
/// Полный Bloc, а не Cubit: «Распознать» при уже идущей очереди отбрасывает
/// трансформер, а не проверка внутри обработчика, и по журналу событий
/// видно, что происходило перед сбоем.
///
/// Диалогов здесь нет: блок не знает, что такое окно. Когда нужен ответ
/// человека, он кладёт вопрос в состояние ([QueueState.ask]), а ответ
/// приходит обратно событием.
class QueueBloc extends Bloc<QueueEvent, QueueState> {
  QueueBloc(this.bridge, {DictationRepository? dictation})
    : dictation = dictation ?? DictationRepository(bridge),
      super(_loaded()) {
    on<FilesAdded>(_onFilesAdded);
    on<TranscriptOpened>(_onTranscriptOpened);
    on<SourceOpened>(_onSourceOpened);
    on<SelectedRemoved>(_onSelectedRemoved);
    on<FinishedCleared>(_onFinishedCleared);

    on<JobSelected>((e, emit) => emit(_select(state, e.job)));
    on<JobToggled>(_onToggled);
    on<SelectionExtended>(_onExtended);
    on<SelectionStepped>(_onStepped);
    on<AllSelected>(_onAllSelected);
    on<SelectionCleared>(
      (e, emit) => emit(state.copyWith(selected: const {}, clearLead: true)),
    );

    // Пока очередь идёт, повторное «Распознать» отбрасывается целиком.
    // Раньше это была проверка `if (_running) return` внутри — теперь
    // событие просто не доходит, и в журнале видно, что его отбросили.
    on<RunRequested>(_onRun, transformer: droppable());
    on<RunConfirmed>(_onRunConfirmed);
    on<RetryRequested>(_onRetry);
    on<StopRequested>(_onStop);
    on<PauseRequested>(_onPause);
    on<JobsReordered>(_onReordered);
    on<ResumeRequested>(_onResume, transformer: droppable());
    on<JobAdvanced>(_onJobAdvanced);
    on<CommandReplacementUndone>(_onCommandReplacementUndone);

    on<SpeakerRenamed>(_onSpeakerRenamed);
    on<SpeakersMerged>(_onSpeakersMerged);
    on<SegmentSpeakerChanged>(_onSegmentSpeakerChanged);
    on<DiarizationToggled>(
      (e, emit) => _onOptionsEdited(
        OptionsEdited((x) => x.copyWith(diarize: e.enabled)),
        emit,
      ),
    );
    on<DiarizationRequested>(
      _onDiarizationRequested,
      transformer: droppable(),
    );
    on<JobOptionsEdited>(_onJobOptionsEdited);
    on<ConversationReceived>(_onConversationReceived);

    on<OptionsEdited>(_onOptionsEdited);
    on<OverridesReset>(_onOverridesReset);
    on<LeadOptionsMadeDefault>(_onMakeDefault);
    on<VocabularyReplacementAdded>(_onVocabularyReplacementAdded);

    on<ModelChosen>(_onModelChosen);
    on<ModelDownloadRequested>(_onDownload, transformer: droppable());
    on<DownloadCancelled>((e, emit) => _download?.cancel());
    // Только пока загрузка идёт. Проценты приходят событиями, и
    // последние из них стоят в очереди блока ещё тогда, когда файл уже
    // скачан и `clearDownload` выполнен: обработанные после, они
    // возвращали ползунок на экран — и он оставался там навсегда,
    // потому что двигать его было уже некому.
    on<DownloadAdvanced>((e, emit) {
      if (_download == null) return;
      emit(
        state.copyWith(
          downloadProgress: e.progress,
          downloadPercent: e.percent,
          status: currentL10n().statusLoadingProgress(e.progress),
        ),
      );
    });
    on<VadRequested>(_onVad, transformer: droppable());
    on<VadModelChosen>(_onVadModelChosen);

    on<DictationPolled>(_onDictationPolled, transformer: droppable());
    on<WindowVisibilityChanged>(_onVisibility);
    on<SettingsReloaded>(_onSettingsReloaded);
    on<LegacyPromptMigrated>(
      (e, emit) => emit(
        state.copyWith(
          defaults: state.defaults.copyWith(prompt: ''),
          vocabulary: e.vocabulary,
        ),
      ),
    );
    on<TimestampsToggled>(_onTimestampsToggled);
    on<RecentCleared>(_onRecentCleared);

    on<CopyRequested>(_onCopy);
    on<SaveRequested>(_onSave);
    on<SaveFormatChosen>((e, emit) {
      emit(
        state.copyWith(
          saveFormat: e.format.id,
          status: currentL10n().statusSaveFormatChosen(
            e.format.label.toLowerCase(),
          ),
        ),
      );
      _persist();
    });
    on<ExportRequested>(_onExport);
    on<AskDismissed>((e, emit) => emit(state.copyWith(clearAsk: true)));
    on<StatusReported>((e, emit) => emit(state.copyWith(status: e.text)));

    _settingsSub = bridge.settingsReloaded.listen(
      (_) => add(const SettingsReloaded()),
    );
    _openConversationInbox();
    _loadTextCommands();
    _syncPolling();
    // Местное API поднимается здесь и нигде больше: оно кладёт файлы
    // в эту же очередь, а очередь живёт в изоляте главного окна.
    unawaited(api.sync());
  }

  /// Единственный, кто может держать модель занятой, — своя же диктовка.
  final DictationRepository dictation;

  /// Местное API. Само по себе выключено — включается галкой в настройках.
  late final api = ApiServer(this);

  /// Что прочитано с диска к самому первому кадру.
  ///
  /// Именно к первому: когда это делалось событием, окно успевало
  /// нарисоваться на пустом состоянии — и модель в инспекторе показывалась
  /// как «Не выбрана», хотя выбрана была.
  static QueueState _loaded() {
    var threads = (Platform.numberOfProcessors ~/ 2).clamp(2, 16);
    if (threads.isOdd) threads -= 1;

    final s = Settings.load();
    final models = findModels();
    var defaults = RunOptions.fromJson(
      s,
      RunOptions(
        model: models.isNotEmpty ? models.first : '',
        lang: 'auto',
        threads: threads,
      ),
    );
    // Настройки могли не пережить переустановку, а подсказка живёт ещё и
    // рядом с расшифровками — оттуда её и возвращаем. Только если в
    // настройках пусто: стёртая руками подсказка должна остаться стёртой.
    if (defaults.prompt.isEmpty &&
        s['transcriberPromptMigratedToVocabulary'] != true) {
      defaults = defaults.copyWith(prompt: Prompts.read(Prompts.transcriber));
    }
    // Раньше форматы хранились расширениями («.txt») — переводим в имена.
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .map((v) => v.startsWith('.') ? v.substring(1) : v)
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();

    return QueueState(
      jobs: _unfinished(),
      models: _withOwn(models, defaults.model),
      defaults: defaults,
      whisperFound: anyRecognitionEngineFound,
      timestamps: (s['timestamps'] as bool?) ?? true,
      saveNextToSource: (s['saveNextToSource'] as bool?) ?? false,
      toLibrary: (s['toLibrary'] as bool?) ?? true,
      libraryPath: (s['libraryPath'] as String?) ?? defaultLibraryPath,
      libraryFormats: formats != null && formats.isNotEmpty
          ? formats
          : const ['txt'],
      copyFormat: _knownFormat(s['copyFormat']),
      saveFormat: _knownFormat(s['saveFormat']),
      recent: ((s['recent'] as List?)?.cast<String>() ?? const [])
          .where((p) => File(p).existsSync())
          .toList(),
      vocabulary: loadAndMigrateVocabulary(s),
    );
  }

  /// Файл с недосчитанным. Очередь между запусками не переживает — и не
  /// должна, — но брошенная посреди работа это не «очередь», а начатое
  /// дело: половина часовой записи стоит десятков минут счёта, и терять
  /// её на выходе из приложения нельзя.
  static File get _unfinishedFile =>
      File(os.join(os.supportDir, 'unfinished.json'));

  /// Вернуть недосчитанное с прошлого запуска — если запись всё ещё на
  /// месте. Нет файла — нечего и продолжать.
  static List<Job> _unfinished() {
    try {
      final j =
          jsonDecode(_unfinishedFile.readAsStringSync())
              as Map<String, dynamic>;
      final path = j['path'] as String;
      if (!File(path).existsSync()) return const [];
      final at = (j['resumeFrom'] as num).toInt();
      return [
        Job(
          File(path),
          state: JobState.paused,
          resumeFrom: at,
          progress: (j['progress'] as num?)?.toDouble() ?? 0,
          detail: currentL10n().jobDetailPausedAt(humanDuration(at)),
          live: [
            for (final seg in (j['segments'] as List? ?? const []))
              Segment(
                (seg[0] as num).toInt(),
                (seg[1] as num).toInt(),
                seg[2] as String,
                replacements: seg.length > 3
                    ? textReplacementsFromJson(seg[3])
                    : const [],
              ),
          ],
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Записать недосчитанное на диск. Пусто — файл убираем: доделанному
  /// незачем возвращаться при следующем запуске.
  void _persistPaused() {
    final job = state.jobs.where((j) => j.paused).firstOrNull;
    try {
      if (job == null) {
        if (_unfinishedFile.existsSync()) _unfinishedFile.deleteSync();
        return;
      }
      _unfinishedFile.writeAsStringSync(
        jsonEncode({
          'path': job.path,
          'resumeFrom': job.resumeFrom,
          'progress': job.progress,
          'segments': [
            for (final seg in job.live)
              [
                seg.from,
                seg.to,
                seg.text,
                [
                  for (final replacement in seg.replacements)
                    replacement.toJson(),
                ],
              ],
          ],
        }),
      );
    } catch (e) {
      stderr.writeln('tsukiko: недосчитанное не сохранилось — $e');
    }
  }

  final NativeBridge bridge;

  static const _promptMigratedSetting = 'transcriberPromptMigratedToVocabulary';

  StreamSubscription<void>? _settingsSub;
  Timer? _pollTimer, _saveTimer;
  bool _windowVisible = true;

  List<VocabularyItem> _vocabulary = const [];
  VocabularyMatcher _vocabularyMatcher = VocabularyMatcher(const []);

  void _setVocabulary(List<VocabularyItem> items) {
    _vocabulary = items;
    _vocabularyMatcher = VocabularyMatcher(items);
  }
  bool _commandsEnabled = true;

  void _loadTextCommands() {
    final settings = Settings.load();
    _setVocabulary(loadAndMigrateVocabulary(settings));
    // Прежняя подсказка расшифровщика была отдельным списком слов.
    // Переносим его в общий словарь и больше не читаем запасную копию.
    final legacyPrompt = state.defaults.prompt.trim();
    if (legacyPrompt.isNotEmpty && settings[_promptMigratedSetting] != true) {
      for (final raw in legacyPrompt.split(RegExp(r'[,;\n]+'))) {
        final phrase = raw.trim();
        if (phrase.isEmpty ||
            _vocabulary.any(
              (item) =>
                  item.phrase.trim().toLowerCase() == phrase.toLowerCase(),
            )) {
          continue;
        }
        _setVocabulary(upsertVocabulary(_vocabulary, phrase));
      }
      add(LegacyPromptMigrated(_vocabulary));
      unawaited(
        Settings.save({
          vocabularySetting: _vocabulary.map((item) => item.toJson()).toList(),
          'prompt': '',
          _promptMigratedSetting: true,
        }).then((_) async {
          Prompts.write(Prompts.transcriber, '');
          await bridge.settingsChanged();
        }),
      );
    }
    _commandsEnabled =
        (settings[vocabularyTranscriberEnabledSetting] as bool?) ??
        (settings[transcriberCommandsEnabledSetting] as bool?) ??
        true;
  }

  Segment _applyCommands(Segment segment) {
    if (!_commandsEnabled) return segment;
    final result = _vocabularyMatcher.apply(segment.text);
    return segment.withText(result.text, result.replacements);
  }

  /// Работающий whisper-cli и его временная папка.
  Process? _proc;
  Directory? _tmp;
  bool _stopRequested = false;

  /// Распознавание прервали не насовсем: его продолжат с той же секунды.
  /// [_pauseWanted] ставит человек кнопкой, [_dictationTookOver] — начатая
  /// диктовка. Разница только в том, продолжится ли оно само.
  bool _pauseWanted = false;
  bool _dictationTookOver = false;

  bool get _pausing => _pauseWanted || _dictationTookOver;

  /// Паузу нажали, пока размечались голоса: шаг доходит до конца, а
  /// следующая запись не начинается.
  bool _pauseAfterStep = false;

  /// Идущая разметка голосов — чтобы «Стоп» мог её отменить.
  Diarizer? _diarizer;

  /// Номер следующего запуска: имена временных файлов должны быть новыми
  /// даже после правки очереди.
  int _runSeq = 0;

  Download? _download;

  // ── запуск ────────────────────────────────────────────────────────────────

  static String _knownFormat(Object? id) =>
      exportFormats.any((f) => f.id == id) ? id as String : formatPlainText.id;

  /// Список моделей с диска. Выбранный вручную файл из чужой папки
  /// дописываем — иначе он исчез бы из списка. Пропавший файл не дописываем:
  /// список из одной мёртвой строки выглядит так, будто модель есть.
  static List<String> _withOwn(List<String> found, String own) =>
      own.isEmpty || found.contains(own) || !File(own).existsSync()
      ? found
      : [...found, own];

  // ── очередь ───────────────────────────────────────────────────────────────

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  List<String> _remember(List<String> recent, String path) =>
      [path, ...recent.where((p) => p != path)].take(10).toList();

  /// Нормализация пути к файлу: обрезка пробелов, кавычек, спецсимволов и разбор file://
  static String normalizePath(String raw) {
    var s = raw.trim();

    // Очистка от нуль-байтов и управляющих символов.
    s = s
        .replaceAll('\x00', '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();

    // Снятие обрамляющих кавычек (одинарных или двойных).
    while ((s.startsWith('"') && s.endsWith('"')) ||
        (s.startsWith("'") && s.endsWith("'"))) {
      if (s.length >= 2) {
        s = s.substring(1, s.length - 1).trim();
      } else {
        s = '';
        break;
      }
    }

    // Обработка file:// URI с преобразованием в путь локальной файловой системы.
    if (s.startsWith('file://')) {
      try {
        var uriStr = s;
        // На Windows пути вида file://C:\... или file://C:/... парсер Uri считает
        // хостом authority 'c:', что приводит к UNC-пути вида \\c\...
        // Превращаем в стандартный file:///C:/...
        final driveMatch = RegExp(
          r'^file://([a-zA-Z]:[\\/])',
        ).firstMatch(uriStr);
        if (driveMatch != null) {
          uriStr = 'file:///${uriStr.substring(7)}';
        }
        uriStr = uriStr.replaceAll(r'\', '/');
        final uri = Uri.parse(uriStr);
        if (uri.hasAuthority && uri.host == 'localhost') {
          s = Uri(
            scheme: 'file',
            path: uri.path,
          ).toFilePath(windows: Platform.isWindows);
        } else {
          s = uri.toFilePath(windows: Platform.isWindows);
        }
      } catch (err) {
        Log.warn('Queue', 'Failed to convert file URI to path: $s ($err)');
      }
    }

    // Повторное снятие кавычек, если URI был в кавычках.
    while ((s.startsWith('"') && s.endsWith('"')) ||
        (s.startsWith("'") && s.endsWith("'"))) {
      if (s.length >= 2) {
        s = s.substring(1, s.length - 1).trim();
      } else {
        s = '';
        break;
      }
    }

    // Финальная очистка от нуль-байтов и управляющих символов.
    s = s
        .replaceAll('\x00', '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();

    if (Platform.isWindows && RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(s)) {
      s = s.replaceAll('/', r'\');
    }

    return s;
  }

  Future<void> _onFilesAdded(FilesAdded e, Emitter<QueueState> emit) async {
    var next = state;
    var added = 0, duplicates = 0, skipped = 0;
    Job? last;

    Future<void> take(Iterable<String> paths) async {
      for (final raw in paths) {
        final p = normalizePath(raw);
        if (p.isEmpty) {
          skipped++;
          continue;
        }

        bool isDir = false;
        try {
          isDir = FileSystemEntity.isDirectorySync(p);
        } catch (err) {
          Log.warn('Queue', 'Could not check directory status for "$p": $err');
          skipped++;
          continue;
        }

        if (isDir) {
          List<String> entries = [];
          try {
            entries =
                Directory(p)
                    .listSync()
                    .whereType<File>()
                    .map((f) => f.path)
                    .where((f) => audioExt.contains(_ext(f)))
                    .toList()
                  ..sort();
          } catch (err) {
            Log.warn('Queue', 'Could not list directory "$p": $err');
            skipped++;
            continue;
          }
          await take(entries);
          continue;
        }

        // Готовую расшифровку тоже принимаем перетаскиванием.
        if (transcriptExt.contains(_ext(p))) {
          try {
            next = await _openTranscript(next, p);
          } catch (err) {
            Log.warn('Queue', 'Could not open transcript "$p": $err');
            skipped++;
          }
          continue;
        }
        if (!audioExt.contains(_ext(p))) {
          skipped++;
          continue;
        }
        if (next.jobs.any((j) => j.path == p)) {
          duplicates++;
          continue;
        }
        try {
          final file = File(p);
          last = Job(file);
          Log.info('Queue', 'Job queued: $p');
          next = next.copyWith(
            jobs: [...next.jobs, last!],
            recent: _remember(next.recent, p),
          );
          added++;
        } catch (err) {
          Log.warn('Queue', 'Could not queue file "$p": $err');
          skipped++;
        }
      }
    }

    await take(e.paths);

    // Молчаливый отказ — худший вид отказа: файл не появился, и непонятно,
    // почему. Говорим про каждый случай.
    final l10n = currentL10n();
    final status = added > 0
        ? (added == 1
              ? l10n.statusFileAdded
              : l10n.statusFilesAdded(filesLabel(added)))
        : duplicates > 0
        ? (duplicates == 1
              ? l10n.statusFileAlreadyQueued
              : l10n.statusFilesAlreadyQueued)
        : skipped > 0
        ? l10n.statusUnsupportedFiles
        : next.status;
    next = next.copyWith(status: status);
    // Добавленная запись — новая точка работы. Переводим на неё
    // инспектор и центральную часть, даже если до этого была открыта
    // другая расшифровка.
    if (last != null) next = _select(next, last!);
    emit(next);
    _persist();
  }

  Future<void> _onTranscriptOpened(
    TranscriptOpened e,
    Emitter<QueueState> emit,
  ) async {
    emit(await _openTranscript(state, e.path));
    _persist();
  }

  /// Открыть готовую расшифровку как запись очереди.
  ///
  /// JSON, субтитры и наш «текст с таймкодами» разбираются в сегменты —
  /// такую расшифровку можно пересохранить в любой другой формат.
  Future<QueueState> _openTranscript(QueueState from, String path) async {
    if (from.jobs.any((j) => j.path == path)) {
      return from.copyWith(status: currentL10n().statusTranscriptAlreadyOpen);
    }
    final String text;
    try {
      text = await File(path).readAsString();
    } catch (err) {
      // Двоичный файл, чужая кодировка, исчез из-под рук.
      stderr.writeln('tsukiko: «$path» не открылся — $err');
      return from.copyWith(
        status: currentL10n().errorNotTextFile(os.basename(path)),
      );
    }

    final read = readTranscript(path, text);
    final parsed = read.parsed;

    final job = Job(
      File(path),
      imported: true,
      state: JobState.done,
      transcript: parsed,
      raw: read.raw,
      detail: parsed != null
          ? currentL10n().statusOpenedSegments(
              segmentsLabel(parsed.segments.length),
            )
          : currentL10n().statusOpenedText,
    );
    return _select(
      from.copyWith(
        jobs: [...from.jobs, job],
        recent: _remember(from.recent, path),
      ),
      job,
    );
  }

  /// Запись плюс её готовая расшифровка.
  ///
  /// Уже лежит в очереди — просто выбираем: второй копии одной записи
  /// в очереди не бывает.
  Future<void> _onSourceOpened(SourceOpened e, Emitter<QueueState> emit) async {
    final already = state.jobs.where((j) => j.path == e.audio).firstOrNull;
    if (already != null) return emit(_select(state, already));

    Transcript? parsed;
    String? raw;
    try {
      final read = readTranscript(
        e.transcript,
        await File(e.transcript).readAsString(),
      );
      parsed = read.parsed;
      raw = read.raw;
    } catch (err) {
      // Расшифровку могли убрать между открытием обзора и нажатием.
      // Запись от этого никуда не делась — берём её как обычную.
      stderr.writeln('tsukiko: «${e.transcript}» не прочиталась — $err');
    }

    final job = Job(
      File(e.audio),
      state: parsed != null || raw != null ? JobState.done : JobState.queued,
      transcript: parsed,
      raw: raw,
      detail: parsed == null
          ? null
          : currentL10n().jobDetailLangSegments(
              languageName(parsed.lang),
              segmentsLabel(parsed.segments.length),
            ),
    );
    emit(
      _select(
        state.copyWith(
          jobs: [...state.jobs, job],
          recent: _remember(state.recent, e.audio),
        ),
        job,
      ),
    );
    _persist();
  }

  void _onSelectedRemoved(SelectedRemoved e, Emitter<QueueState> emit) {
    final doomed = state.targets.where((j) => !j.active).toSet();
    if (doomed.isEmpty) return;
    final at = state.jobs.indexOf(doomed.first);
    final jobs = state.jobs.where((j) => !doomed.contains(j)).toList();
    final selected = state.selected.where((j) => !doomed.contains(j)).toSet();

    var lead = state.lead;
    if (lead != null && doomed.contains(lead)) {
      lead = jobs.isEmpty ? null : jobs[at.clamp(0, jobs.length - 1)];
    }
    emit(
      state.copyWith(
        jobs: jobs,
        selected: selected.isEmpty && lead != null ? {lead} : selected,
        lead: lead,
        clearLead: lead == null,
        status: doomed.length == 1
            ? currentL10n().statusRecordingRemoved
            : currentL10n().statusRecordingsRemoved(
                recordsLabel(doomed.length),
              ),
      ),
    );
  }

  void _onFinishedCleared(FinishedCleared e, Emitter<QueueState> emit) {
    final doomed = state.jobs.where((j) => j.done).toSet();
    if (doomed.isEmpty) return;
    final jobs = state.jobs.where((j) => !doomed.contains(j)).toList();
    final lead = doomed.contains(state.lead)
        ? (jobs.isEmpty ? null : jobs.first)
        : state.lead;
    emit(
      state.copyWith(
        jobs: jobs,
        selected: state.selected.where((j) => !doomed.contains(j)).toSet(),
        lead: lead,
        clearLead: lead == null,
        status: currentL10n().statusFinishedRemoved,
      ),
    );
  }

  // ── выделение ─────────────────────────────────────────────────────────────

  QueueState _select(QueueState from, Job job) =>
      from.copyWith(selected: {job}, lead: job);

  void _onToggled(JobToggled e, Emitter<QueueState> emit) {
    final selected = {...state.selected};
    if (!selected.remove(e.job)) selected.add(e.job);
    final lead = selected.contains(e.job)
        ? e.job
        : (selected.isEmpty ? null : selected.last);
    emit(
      state.copyWith(selected: selected, lead: lead, clearLead: lead == null),
    );
  }

  void _onExtended(SelectionExtended e, Emitter<QueueState> emit) {
    final lead = state.lead;
    if (lead == null) return emit(_select(state, e.job));
    final a = state.jobs.indexOf(lead), b = state.jobs.indexOf(e.job);
    if (a < 0 || b < 0) return emit(_select(state, e.job));
    emit(
      state.copyWith(
        selected: {
          ...state.selected,
          ...state.jobs.sublist(a < b ? a : b, (a < b ? b : a) + 1),
        },
        lead: e.job,
      ),
    );
  }

  void _onStepped(SelectionStepped e, Emitter<QueueState> emit) {
    if (state.jobs.isEmpty) return;
    final from = state.lead == null ? -1 : state.jobs.indexOf(state.lead!);
    final next = (from + e.delta).clamp(0, state.jobs.length - 1);
    final job = state.jobs[next];
    if (!e.extend) return emit(_select(state, job));
    _onExtended(SelectionExtended(job), emit);
  }

  void _onAllSelected(AllSelected e, Emitter<QueueState> emit) {
    if (state.jobs.isEmpty) return;
    emit(
      state.copyWith(
        selected: state.jobs.toSet(),
        lead: state.lead ?? state.jobs.first,
      ),
    );
  }

  // ── настройки распознавания ───────────────────────────────────────────────

  void _onOptionsEdited(OptionsEdited e, Emitter<QueueState> emit) {
    if (state.selected.isEmpty) {
      emit(state.copyWith(defaults: e.change(state.defaults)));
    } else {
      emit(
        _replaceAll(
          state.selected,
          (j) => j.copyWith(overrides: e.change(j.overrides ?? state.defaults)),
        ),
      );
    }
    _persist();
  }

  void _onOverridesReset(OverridesReset e, Emitter<QueueState> emit) {
    emit(
      _replaceAll(
        state.selected,
        (j) => j.copyWith(clearOverrides: true),
      ).copyWith(status: currentL10n().statusOverridesReset),
    );
  }

  void _onMakeDefault(LeadOptionsMadeDefault e, Emitter<QueueState> emit) {
    final own = state.lead?.overrides;
    if (own == null) return;
    emit(
      state.copyWith(
        defaults: own,
        status: currentL10n().statusSettingsMadeDefault,
      ),
    );
    _persist();
  }

  Future<void> _onVocabularyReplacementAdded(
    VocabularyReplacementAdded e,
    Emitter<QueueState> emit,
  ) async {
    final phrase = e.phrase.trim();
    final replacement = e.replacement.trim();
    if (phrase.isEmpty) return;

    final s = Settings.load();
    final vocab = loadAndMigrateVocabulary(s);
    final updated = upsertVocabulary(vocab, phrase, replacement: replacement);
    final textCommands = updated
        .where((i) => i.isReplacement)
        .map((i) => i.toTextCommand())
        .toList();
    await Settings.save({
      vocabularySetting: updated.map((i) => i.toJson()).toList(),
      textCommandsSetting: textCommands.map((c) => c.toJson()).toList(),
    });
    _setVocabulary(updated);

    if (e.removeFromPrompt) {
      final currentPrompt = state.shown.prompt;
      final terms = currentPrompt.split(RegExp(r',\s*'));
      final lower = phrase.toLowerCase();
      final filtered = terms.where((t) => t.trim().toLowerCase() != lower);
      final newPrompt = filtered.join(', ');
      if (newPrompt != currentPrompt) {
        add(OptionsEdited((x) => x.copyWith(prompt: newPrompt)));
      }
    }

    emit(
      state.copyWith(
        vocabulary: _vocabulary,
        status: replacement.isEmpty
            ? currentL10n().statusWordAddedToPrompt(phrase)
            : currentL10n().statusReplacementAdded(phrase, replacement),
      ),
    );
    await bridge.settingsChanged();
  }

  /// Заменить записи по правилу, сохранив выделение и ведущую.
  QueueState _replaceAll(Set<Job> which, Job Function(Job) change) {
    final map = <String, Job>{};
    final jobs = [
      for (final j in state.jobs)
        if (which.contains(j)) (map[j.path] = change(j)) else j,
    ];
    Job pick(Job j) => map[j.path] ?? j;
    return state.copyWith(
      jobs: jobs,
      selected: state.selected.map(pick).toSet(),
      lead: state.lead == null ? null : pick(state.lead!),
    );
  }

  /// Заменить одну запись, не трогая остальных.
  QueueState _replace(QueueState from, Job was, Job now) => from.copyWith(
    jobs: [
      for (final j in from.jobs)
        identical(j, was) || j.path == was.path ? now : j,
    ],
    selected: from.selected.map((j) => j.path == was.path ? now : j).toSet(),
    lead: from.lead?.path == was.path ? now : from.lead,
  );

  // ── распознавание ─────────────────────────────────────────────────────────

  Future<void> _onRetry(RetryRequested e, Emitter<QueueState> emit) async {
    final again = state.targets.where((j) => !j.imported).toSet();
    if (again.isEmpty || state.running) return;
    emit(
      _replaceAll(again, (j) => j.reset).copyWith(
        status: again.length == 1
            ? currentL10n().statusRetrying
            : currentL10n().statusRetryingRecords(recordsLabel(again.length)),
      ),
    );
    await _run(emit);
  }

  Future<void> _onRun(RunRequested e, Emitter<QueueState> emit) async {
    // Сначала «а есть ли что распознавать»: с пустой очередью говорить
    // про модель незачем — человек ещё ничего не просил.
    if (!state.hasPending) return;

    final l10n = currentL10n();
    if (!state.whisperFound) {
      return emit(
        state.copyWith(
          ask: Ask(
            l10n.askWhisperNotFoundTitle,
            l10n.askWhisperNotFoundBody(os.whisperInstallHint),
          ),
        ),
      );
    }
    if (state.defaults.model.isEmpty &&
        state.jobs.every((j) => state.optionsFor(j).model.isEmpty)) {
      // Моделей нет вовсе — говорить «выберите модель» некорректно:
      // выбирать не из чего, человека надо вести в загрузчик.
      return emit(
        state.copyWith(
          ask: Ask(
            state.models.isEmpty
                ? l10n.askNeedModelTitle
                : l10n.askModelNotSelectedTitle,
            state.models.isEmpty
                ? l10n.askNeedModelBody
                : l10n.askModelNotSelectedBody,
          ),
        ),
      );
    }

    // Диктовка главнее очереди, и спрашиваем о ней здесь, до запуска:
    // посреди работы такой вопрос застал бы человека врасплох.
    if (await dictation.status() == DictationStatus.resting) {
      return emit(
        state.copyWith(
          ask: Ask(
            l10n.askDictationHoldsModelTitle,
            l10n.askDictationHoldsModelBody,
            confirm: true,
          ),
        ),
      );
    }
    await _run(emit);
  }

  Future<void> _onRunConfirmed(RunConfirmed e, Emitter<QueueState> emit) async {
    emit(state.copyWith(clearAsk: true));
    if (!e.yes) return;
    // Согласились — освобождаем память и только потом начинаем: двух
    // копий модели сразу в памяти не бывает.
    if (await dictation.status() == DictationStatus.resting) {
      await dictation.release();
    }
    await _run(emit);
  }

  /// Проход по очереди. Всё, что может пойти не так внутри, оставляет
  /// очередь в состоянии покоя: без этого одно исключение подвешивало её
  /// в «идёт распознавание» до перезапуска.
  Future<void> _run(Emitter<QueueState> emit) async {
    emit(state.copyWith(running: true, clearAsk: true));
    _stopRequested = false;
    _pauseWanted = false;
    _pauseAfterStep = false;
    _dictationTookOver = false;
    _syncPolling();
    try {
      _tmp ??= await Directory.systemTemp.createTemp(appName);
      // По одной записи за раз, а не обходом по индексу: пока идёт
      // распознавание, файлы и добавляют, и убирают. Список взятого нужен,
      // чтобы неудачная запись не попалась второй раз.
      final attempted = <String>{};
      while (!_stopRequested) {
        Job? next;
        for (final job in state.jobs) {
          if (!job.done && !job.imported && !attempted.contains(job.path)) {
            next = job;
            break;
          }
        }
        if (next == null) break;
        attempted.add(next.path);
        if (!await _runOne(next, emit)) break;
        if (_pauseAfterStep) break;
      }
    } finally {
      _proc = null;
      emit(
        state.copyWith(
          running: false,
          // Приостановленное — не «Готово»: работа не кончилась, она ждёт.
          status: _stopRequested
              ? currentL10n().statusStopped
              : state.hasPaused
              ? currentL10n().statusPaused
              : currentL10n().statusIdle,
        ),
      );
      _syncPolling();
      _releaseTemp();
      unawaited(_persistNow());
      // Доделанное с диска убирается здесь же: файл недосчитанного живёт
      // ровно столько, сколько есть что досчитывать.
      _persistPaused();
    }
  }

  void _releaseTemp() {
    final dir = _tmp;
    if (dir == null) return;
    _tmp = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Одна запись от начала до конца. false — очередь надо остановить
  /// целиком; неудача самой записи это true: соседние файлы ни при чём.
  Future<bool> _runOne(Job job, Emitter<QueueState> emit) async {
    final selected = state.optionsFor(job);
    final opts = _commandsEnabled
        ? selected.copyWith(
            prompt: promptWithVocabulary(
              selected.effectivePrompt,
              _vocabulary,
              maxEstimatedTokens:
                  engineForModel(selected.model) == RecognitionEngine.whisperCpp
                      ? vocabularyPromptBudget
                      : 9999,
            ),
          )
        : selected;
    var it = job;
    if (opts.model.isEmpty) {
      emit(
        _replace(
          state,
          it,
          it.copyWith(
            state: JobState.failed,
            detail: currentL10n().jobDetailNoModelSelected,
          ),
        ),
      );
      return true;
    }

    if (!await _yieldToDictation(it, emit)) return false;
    it = _find(it) ?? it;

    it = it.copyWith(state: JobState.converting, startedAt: DateTime.now());
    Log.info('Queue', 'Converting audio: ${it.path}');
    emit(
      _replace(
        state,
        job,
        it,
      ).copyWith(lead: it, selected: state.selected.length <= 1 ? {it} : null),
    );

    final base = os.join(_tmp!.path, '${_runSeq++}');
    final jsonFile = File('$base.json');
    // Чистим на запись, а не на попытку: попыток у одной записи бывает
    // несколько (упавшую сборку вычёркиваем и берём следующую, начатое
    // досчитываем с места остановки), и сказанное первой из них — самое
    // важное, что есть.
    _engineLog.clear();
    var audioPrepared = false;
    try {
      final wav = await os.toWav(it.path, '$base.wav');
      audioPrepared = true;

      // Пустая запись — это не «плохой файл», а ничего: заголовок
      // и нулевой кусок данных. Движок на таком говорит «failed to read
      // the frames of the audio data» и валит следом полтора экрана про
      // тензоры и Metal, по которым не понять ни что случилось, ни что
      // делать. Случилось же ровно одно, и сказать это надо словами.
      if (!wavHasAudio(wav)) {
        emit(
          _replace(
            state,
            it,
            it.copyWith(
              state: JobState.failed,
              detail: currentL10n().jobDetailSilent,
              error: currentL10n().errorSilentRecording,
            ),
          ).copyWith(status: currentL10n().statusRecognitionFailed(it.name)),
        );
        return true;
      }

      // Путь, который до движка не доедет, виден заранее — и сказать
      // об этом надо заранее же. Сам движок скажет только «failed to
      // open», а по этой строке не догадаться ни что дело в пути, ни что
      // с ним делать.
      final stuck = [
        opts.model,
        wav,
        base,
        if (opts.vad) opts.vadModel,
      ].where(pathBeyondEngine).toSet();
      if (stuck.isNotEmpty) {
        _rememberEngineLine(currentL10n().enginePathNotAscii(stuck.join('\n')));
      }

      // Подготовка звука занимает секунды — за это время сосед мог начать
      // распознавать заново. Проверяем ещё раз вплотную к запуску.
      if (!await _yieldToDictation(it, emit)) return false;
      it = _find(it) ?? it;

      final engine = engineForModel(opts.model);
      if (findRecognitionEngine(engine) == null) {
        final name = engineTechnicalName(engine);
        emit(
          _replace(
            state,
            it,
            it.copyWith(
              state: JobState.failed,
              detail: currentL10n().jobDetailEngineMissing(name),
            ),
          ).copyWith(status: currentL10n().statusRecognitionFailed(it.name)),
        );
        return true;
      }

      // Whisper продолжает с последней готовой миллисекунды. NeMo выдаёт
      // результат одним JSON в конце, поэтому после вытеснения диктовкой
      // безопасно начинает файл заново и ничего не дублирует.
      var code = 0;
      while (true) {
        it = _find(it) ?? it;
        it = it.copyWith(state: JobState.transcribing, clearDetail: true);
        emit(_replace(state, job, it).copyWith(status: it.name));

        final args = engine == RecognitionEngine.whisperCpp
            ? buildArgs(opts, wav, base, from: it.resumeFrom)
            : buildNemoArgs(opts, wav, jsonFile.path);
        Log.info(
          'Queue',
          'Transcribing started: engine=${engineTechnicalName(engine)}, '
              'model=${opts.model}, threads=${opts.threads}, args=${args.join(" ")}',
        );
        code = await _runRecognizer(it, engine, args);
        it = _find(it) ?? it;
        if (!_pausing || _stopRequested) break;

        it = _pause(it, emit);
        // Своя пауза ждёт человека, а вытеснение диктовкой кончается само.
        if (_pauseWanted) return false;
        if (!await _yieldToDictation(it, emit)) return false;
        _dictationTookOver = false;
        // Диктовка кончилась, работа пошла — окошку о ней больше незачем
        // висеть, даже если его не закрыли.
        emit(state.copyWith(clearAsk: true));
        it = _find(it) ?? it;
      }

      if (_stopRequested) {
        emit(_replace(state, it, it.copyWith(state: JobState.cancelled)));
        return false;
      }
      if (code != 0 || !jsonFile.existsSync()) {
        Log.error(
          'Queue',
          'Job failed: ${it.name}, exitCode=$code'
              '${_engineErrorText.isNotEmpty ? ', error: $_engineErrorText' : ''}',
        );
        // Со словами движка, а не без них: «не справился с этим файлом»
        // не говорит человеку ничего, а строка от whisper — «failed to
        // load model», «unsupported sample rate» — говорит всё.
        emit(
          _replace(
            state,
            it,
            it.copyWith(
              state: JobState.failed,
              detail: _lastEngineError.isEmpty
                  ? currentL10n().jobDetailEngineFailed(
                      engineTechnicalName(engine),
                    )
                  : '${currentL10n().jobDetailEngineFailed(engineTechnicalName(engine))} · $_lastEngineError',
              // В подпись влезает начало одной строки, и выделить её
              // оттуда нельзя. Целиком вывод живёт здесь — его показывают
              // подсказкой и отдают в буфер обмена одним пунктом меню.
              error: _engineErrorText.isEmpty ? null : _engineErrorText,
            ),
          ).copyWith(status: currentL10n().statusRecognitionFailed(it.name)),
        );
        return true;
      }

      final recognized = await jsonFile.readAsString();
      final earlier = engine == RecognitionEngine.whisperCpp && it.resumeFrom > 0
          ? it.live.where((seg) => seg.from < it.resumeFrom).toList()
          : const <Segment>[];

      /// Текст из ответа движка. С разметкой голосов [turns] — тот же
      /// разбор, только фрагменты режутся на смене говорящего; без неё —
      /// ровно прежний.
      Transcript build([List<SpeakerTurn> turns = const []]) {
        var t = engine == RecognitionEngine.whisperCpp
            ? parseWhisperJson(recognized, turns: turns, finish: false)
            : parseNemoJson(recognized, turns: turns, finish: false);
        if (_commandsEnabled) {
          t = t.copyWith(segments: [
            for (final segment in t.segments) _applyCommands(segment),
          ]);
        }
        // Заход после паузы знает только свою половину записи. Начало
        // осталось в том, что уже показали на экране, — оттуда и берём.
        // Слов с таймкодами у него нет: время внутри фрагментов
        // раскладывается по доле символов.
        if (earlier.isNotEmpty) {
          t = t.copyWith(segments: [
            if (turns.isEmpty)
              ...earlier
            else
              ...splitAllBySpeakers([for (final seg in earlier) (seg, const [])], turns),
            ...t.segments,
          ]);
        }
        return t;
      }

      var t = build();
      var note = '';
      String? problem;
      if (opts.diarize) {
        final voiced = await _diarizeStep(it, opts, wav, t, emit, build);
        t = voiced.transcript;
        note = voiced.note;
        problem = voiced.problem;
        it = _find(it) ?? it;
      }
      final beside = state.saveNextToSource
          ? await _saveBesideSource(it, t)
          : (path: null, problem: null);
      final placed = state.toLibrary ? await _fileToLibrary(it, t) : null;

      final took = it.startedAt == null
          ? null
          : DateTime.now().difference(it.startedAt!);
      Log.info(
        'Queue',
        'Job completed: ${it.name}, duration: ${took?.inMilliseconds}ms, '
            'language: ${t.lang}, segments: ${t.segments.length}',
      );
      emit(
        _replace(
          state,
          it,
          it.copyWith(
            transcript: t,
            progress: 1,
            state: JobState.done,
            error: problem,
            besideSource: beside.path,
            took: took,
            detail: [
              currentL10n().jobDetailLangSegments(
                languageName(t.lang),
                segmentsLabel(t.segments.length),
              ),
              if (note.isNotEmpty) note,
            ].join(' · '),
          ),
        ).copyWith(status: beside.problem ?? placed ?? state.status),
      );
      return true;
    } catch (err, st) {
      // Битый JSON от whisper, файл исчез из-под рук, кончилось место.
      Log.error('Queue', 'Job failed with exception: ${it.name}', err, st);
      stderr.writeln('tsukiko: «${it.name}» не распозналась — $err');
      emit(
        _replace(
          state,
          it,
          it.copyWith(
            state: JobState.failed,
            detail: audioPrepared
                ? currentL10n().jobDetailParseFailed
                : currentL10n().jobDetailAudioConversionFailed,
            error: [
              if (_engineErrorText.isNotEmpty) _engineErrorText,
              '$err',
            ].join('\n'),
          ),
        ).copyWith(status: currentL10n().statusRecognitionFailed(it.name)),
      );
      return true;
    } finally {
      for (final ext in const ['.wav', '.json']) {
        try {
          final f = File('$base$ext');
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Отметить запись приостановленной на том месте, до которого досчитали.
  ///
  /// Место берём по последнему показанному фрагменту, а не по проценту:
  /// процент — оценка, а метка фрагмента — факт. Досчитанное остаётся
  /// на экране, и второй заход начнётся ровно оттуда.
  Job _pause(Job job, Emitter<QueueState> emit) {
    final at = job.live.isEmpty ? job.resumeFrom : job.live.last.to;
    final paused = job.copyWith(
      state: JobState.paused,
      resumeFrom: at,
      detail: currentL10n().jobDetailPausedAt(humanDuration(at)),
    );
    emit(
      _replace(state, job, paused).copyWith(
        status: _dictationTookOver
            ? currentL10n().statusPausedDictation
            : currentL10n().statusPaused,
        // Молча отнимать у человека работу нельзя: диктовка вытеснила
        // расшифровку, и об этом надо сказать — вместе с тем, что она
        // продолжится сама.
        ask: _dictationTookOver
            ? Ask(
                currentL10n().askDictationTookOverTitle,
                currentL10n().askDictationTookOverBody(humanDuration(at)),
              )
            : null,
      ),
    );
    _persistPaused();
    return paused;
  }

  /// Приостановить. Процесс гасим целиком, а не усыпляем: усыплённый
  /// держит в памяти полтора гигабайта модели — ровно то, ради чего паузу
  /// и жмут. Считанное при этом не пропадает.
  void _onPause(PauseRequested e, Emitter<QueueState> emit) {
    if (!state.running) return;
    _pauseWanted = true;
    _proc?.kill();
    // Разметку голосов посреди не прерываем: продолжить её с места нельзя,
    // она считается по всей записи сразу. Она доходит до конца, а очередь
    // встаёт перед следующей записью.
    if (state.jobs.any((j) => j.state == JobState.diarizing)) {
      _pauseAfterStep = true;
    }
  }

  /// Переставить строку. Место вставки список считает сам — уже с оглядкой
  /// на то, что перетащенную строку из него вынут.
  void _onReordered(JobsReordered e, Emitter<QueueState> emit) {
    final jobs = [...state.jobs];
    if (e.from < 0 || e.from >= jobs.length) return;
    jobs.insert(e.to.clamp(0, jobs.length - 1), jobs.removeAt(e.from));
    emit(
      state.copyWith(jobs: jobs, status: currentL10n().statusQueueReordered),
    );
  }

  Future<void> _onResume(ResumeRequested e, Emitter<QueueState> emit) async {
    if (state.running) return;
    _pauseWanted = false;
    final at = state.jobs.firstWhere(
      (j) => j.paused,
      orElse: () => state.jobs.first,
    );
    emit(
      state.copyWith(
        clearAsk: true,
        status: currentL10n().statusResumedFrom(humanDuration(at.resumeFrom)),
      ),
    );
    await _run(emit);
  }

  /// Нынешний вид записи: пока шёл шаг, состояние могло смениться.
  Job? _find(Job job) {
    for (final j in state.jobs) {
      if (j.path == job.path) return j;
    }
    return null;
  }

  /// Что движок наговорил помимо хода работы. Нужно, когда он не
  /// справился: «не справился с этим файлом» само по себе не говорит
  /// человеку ничего, а строки от whisper обычно говорят всё.
  ///
  /// Список, а не последняя строка: беда редко умещается в одну — за
  /// «failed to load model» идут путь, размер и причина, и без них
  /// в чужие руки передавать нечего. Строки хода работы (фрагменты,
  /// проценты) сюда не попадают: они вытеснили бы саму беду.
  final _engineLog = <String>[];

  /// Больше сорока строк не помним: длиннее этого движок не жалуется,
  /// а держать весь его вывод — это мегабайты на часовой записи.
  static const _engineLogLimit = 40;

  void _rememberEngineLine(String line) {
    _engineLog.add(line);
    if (_engineLog.length > _engineLogLimit) _engineLog.removeAt(0);
  }

  /// Последняя жалоба движка — для подписи под именем записи.
  String get _lastEngineError => _engineLog.isEmpty ? '' : _engineLog.last;

  /// Вся жалоба целиком — для подсказки, инспектора и буфера обмена.
  String get _engineErrorText => _engineLog.join('\n');

  /// Запуск выбранного нативного движка с разбором вывода на лету.
  ///
  /// Сборка движка может не запуститься вовсе — на Windows их две, и
  /// Vulkan-сборку роняет старый драйвер видеокарты. Тогда вычёркиваем
  /// её на весь сеанс и тут же перезапускаемся на процессорной: человек
  /// видит секундную задержку, а не «не справился» на каждой записи.
  Future<int> _runRecognizer(
    Job job,
    RecognitionEngine engine,
    List<String> args,
  ) async {
    final processName = recognitionExecutableName(engine);
    while (true) {
      final exe = findRecognitionEngine(engine);
      if (exe == null) return _noEngine;
      int code;
      try {
        code = await _runEngine(job, exe, args, processName);
      } catch (error) {
        _sawEngineOutput = false;
        _rememberEngineLine('$exe: $error');
        code = _noEngine;
      }
      // Не запустился — это когда процесс умер, не сказав ни слова о ходе
      // работы. Отличать по коду возврата нельзя: whisper и на негодном
      // звуке возвращает не ноль, а вычёркивать из-за одного битого файла
      // рабочую сборку — беда хуже исходной.
      if (code == 0 || _sawEngineOutput || _stopRequested || _pausing) {
        return code;
      }
      // Сборка, которая падает на запуске, не говорит вообще ничего:
      // Windows убивает её до первой строки кода, и в вывод не попадает
      // ни буквы. Тогда единственная улика — имя сборки и код возврата,
      // и записать его надо шестнадцатеричным: коды падений Windows
      // (0xC0000135 «нет библиотеки», 0xC0000005 «обращение не туда»)
      // только так и читаются. Без этой строки человеку нечего было бы
      // ни прочитать, ни переслать — а отчёты самой Windows лежат
      // в папке, куда его не пускает система.
      _rememberEngineLine(
        '$exe: код возврата $code '
        '(0x${(code & 0xFFFFFFFF).toRadixString(16).toUpperCase()}), '
        'ни строчки вывода',
      );
      if (!engineFailedToStart(exe, processName)) return code;
      stderr.writeln(
        'tsukiko: сборка движка $exe не запустилась — берём следующую',
      );
    }
  }

  /// Ни одной сборки движка не осталось.
  static const _noEngine = -1;

  /// Сказал ли движок хоть что-нибудь про ход работы. По этому признаку
  /// отличается «не справился с файлом» от «не поднялся вовсе».
  bool _sawEngineOutput = false;

  /// Когда в последний раз пропустили ход работы в состояние.
  ///
  /// Каждое слово движка о ходе работы — это новое состояние блока и
  /// полная перерисовка окна: очередь, расшифровка и весь инспектор
  /// с его списками и полями. Замер на трёхминутной записи показал
  /// девять таких строк, то есть примерно раз на десять процентов, —
  /// сама по себе это не беда. Но частота эта не наша: её выбирает
  /// движок и его настройки, и полагаться на «их и так мало» значит
  /// однажды получить сотню в секунду от чужой правки.
  ///
  /// Восьми раз в секунду глазу хватает с запасом.
  DateTime? _lastProgressAt;
  static const _progressEvery = Duration(milliseconds: 120);

  Future<int> _runEngine(
    Job job,
    String exe,
    List<String> args,
    String processName,
  ) async {
    _sawEngineOutput = false;
    _lastProgressAt = null;
    void onLine(String line) {
      final text = line.trim();
      if (text.isNotEmpty) _sawEngineOutput = true;
      final seg = parseSegmentLine(line);
      if (seg != null) {
        return add(JobAdvanced(job, segment: seg));
      }
      final p = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
      if (p != null) {
        final value = double.parse(p.group(1)!) / 100;
        final now = DateTime.now();
        final was = _lastProgressAt;
        // Сотый процент пропускаем всегда: на нём ползунок и
        // останавливается.
        if (value < 1 && was != null && now.difference(was) < _progressEvery) {
          return;
        }
        _lastProgressAt = now;
        return add(JobAdvanced(job, progress: value));
      }
      final l = RegExp(r'auto-detected language:\s*(\w+)').firstMatch(line);
      if (l != null) {
        add(JobAdvanced(job, language: l.group(1)));
      }
      if (text.isNotEmpty) _rememberEngineLine(text);
    }

    // Под своим именем: иначе в «Мониторинге системы» память числится
    // за безымянным whisper-cli, и чей он — не понять.
    final proc = await Process.start(
      runnableEngine(exe, processName)!,
      args,
      environment: await os.engineEnvironment(),
    );
    _proc = proc;
    os.bindToApp(proc.pid);
    Log.info(
      'Queue',
      'Recognizer process launched: PID=${proc.pid} ($processName)',
    );
    // Номер на диск: обычное «Завершить» до Dart не доходит, и погасить
    // движок вместе с приложением может только родная сторона — а найти
    // его она может лишь по этой записи.
    rememberRecognizerPid(proc.pid);
    // Диктовка главнее очереди, и спрашивать её раз в начале мало:
    // часовая запись считается минутами, а диктовать хотят посреди.
    // Заметили — гасим счёт немедленно, память достаётся диктовке
    // целиком, а досчитаем потом с той же секунды.
    var asking = false;
    final watch = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      // Вопрос уходит в чужой изолят и возвращается не мгновенно: без
      // этого сторожа их накопилась бы очередь.
      if (asking || _pausing || _stopRequested) return;
      asking = true;
      try {
        if (await dictation.status() != DictationStatus.busy) return;
        _dictationTookOver = true;
        proc.kill();
      } finally {
        asking = false;
      }
    });
    // whisper-cli и nemo-speech всегда отдают распознанный текст в stdout
    // в UTF-8. На русской Windows systemEncoding (CP1251) превращал этот
    // текст в «РџСЂРёРІРµС‚». При этом ошибки CRT могут приходить в stderr
    // в CP1251. [resilientLineDecoder] декодирует UTF-8, а при невалидных
    // байтах откатывается к systemEncoding.
    final out = proc.stdout.transform(resilientLineDecoder()).listen(onLine);
    final err = proc.stderr.transform(resilientLineDecoder()).listen(onLine);
    try {
      final exitCode = await proc.exitCode;
      Log.info(
        'Queue',
        'Recognizer process PID=${proc.pid} exited with code $exitCode',
      );
      return exitCode;
    } finally {
      watch.cancel();
      await out.cancel();
      await err.cancel();
      _proc = null;
      forgetRecognizerPid();
    }
  }

  void _onJobAdvanced(JobAdvanced e, Emitter<QueueState> emit) {
    final job = _find(e.job);
    if (job == null) return;
    if (e.segment != null) {
      return emit(
        _replace(state, job, job.withSegment(_applyCommands(e.segment!))),
      );
    }
    if (e.progress != null) {
      Log.debug(
        'Queue',
        'Progress for ${job.name}: ${(e.progress! * 100).toStringAsFixed(1)}%',
      );
      return emit(_replace(state, job, job.copyWith(progress: e.progress)));
    }
    if (e.language != null) {
      Log.info('Queue', 'Detected language for ${job.name}: ${e.language}');
      emit(
        state.copyWith(status: '${job.name} · ${languageName(e.language!)}'),
      );
    }
  }

  Future<void> _onCommandReplacementUndone(
    CommandReplacementUndone e,
    Emitter<QueueState> emit,
  ) async {
    final job = _find(e.job);
    if (job == null ||
        e.index < 0 ||
        e.index >= e.segment.replacements.length) {
      return;
    }
    final current = job.segments
        .where((s) => identical(s, e.segment))
        .firstOrNull;
    if (current == null) return;

    final changed = job.replaceSegment(
      current,
      current.undoReplacement(e.index),
    );
    emit(
      _replace(
        state,
        job,
        changed,
      ).copyWith(status: currentL10n().statusVoiceCommandUndone),
    );
    _persistPaused();
    await _rewriteStoredTranscript(changed);
  }

  /// Автосохранённый текст обязан следовать за тем, что человек уже
  /// поправил на экране. Новых файлов не создаём: обновляем только те,
  /// которые эта запись действительно успела сохранить.
  Future<void> _rewriteStoredTranscript(Job job) async {
    final transcript = job.transcript;
    if (transcript == null || job.imported) return;
    try {
      final beside = job.besideSource;
      if (beside != null && File(beside).existsSync()) {
        await File(beside).writeAsString(
          renderPlain(transcript.segments, false, speakers: transcript.speakers),
        );
      }
      for (final path in Sources.transcriptsFor(state.libraryPath, job.path)) {
        final format = formatOfFile(path);
        if (format == null) continue;
        await File(
          path,
        ).writeAsString(renderFor(format, transcript, name: job.name));
      }
    } catch (error) {
      stderr.writeln('tsukiko: отмена команды не записалась на диск — $error');
    }
  }

  // ── голоса ────────────────────────────────────────────────────────────────

  /// Дольше этого запись сама на голоса не размечается: память разметки
  /// растёт с длиной записи (около 1.3 ГБ на час, 2.4 ГБ на два с
  /// половиной — см. [diarizationPeakBytes]). Резать на куски нельзя —
  /// голоса разных кусков между собой не сопоставятся. Поэтому длинную запись не размечаем молча, а
  /// говорим, сколько памяти нужно, и оставляем кнопку «Всё равно
  /// определить голоса».
  static const _diarizeLimit = Duration(hours: 2);

  /// Шаг «Определяю голоса» после распознавания.
  ///
  /// Что бы ни случилось внутри, готовый текст не теряется: сбой,
  /// остановка, тишина или один голос возвращают расшифровку без голосов
  /// и объяснение в [note] (а сбой — ещё и причину в [problem]).
  ///
  /// [build] собирает расшифровку из ответа движка по разметке голосов —
  /// у whisper там слова с потокенным временем, точнее, чем раскладка по
  /// символам.
  Future<({Transcript transcript, String note, String? problem})>
  _diarizeStep(
    Job job,
    RunOptions opts,
    String wav,
    Transcript plain,
    Emitter<QueueState> emit,
    Transcript Function([List<SpeakerTurn> turns]) build, {
    bool manual = false,
  }) async {
    final l10n = currentL10n();
    ({Transcript transcript, String note, String? problem}) plainWith(
      String note, [
      String? problem,
    ]) => (transcript: plain, note: note, problem: problem);
    if (plain.segments.isEmpty) return plainWith('');

    final seconds = wavSecondsBySize(File(wav).lengthSync());
    if (!manual && seconds > _diarizeLimit.inSeconds) {
      return plainWith(
        l10n.speakersSkippedLong(
          humanDuration(_diarizeLimit.inMilliseconds),
          sizeLabelMb(diarizationPeakBytes(seconds) ~/ (1024 * 1024)),
        ),
      );
    }

    // Перед шагом диктовке уступаем, как перед распознаванием; посреди —
    // нет: разметка считается по всей записи сразу, и прерванную пришлось
    // бы начинать заново.
    if (!await _yieldToDictation(job, emit)) return plainWith(l10n.speakersStopped);
    var it = _find(job) ?? job;
    it = it.copyWith(
      state: JobState.diarizing,
      progress: 0,
      live: plain.segments,
      detail: l10n.jobDetailDiarizing,
    );
    emit(_replace(state, job, it).copyWith(status: l10n.statusDiarizing(it.name)));

    if (!DiarizationModels.isInstalled) {
      final mb = DiarizationModels.downloadMb();
      emit(
        _replace(
          state,
          it,
          it.copyWith(detail: l10n.jobDetailSpeakerModelsLoading(sizeLabelMb(mb))),
        ),
      );
      final problem = await DiarizationModels.ensureInstalled(
        cancelled: () => _stopRequested,
        onProgress: (share) => add(JobAdvanced(it, progress: share)),
      );
      if (_stopRequested) return plainWith(l10n.speakersStopped);
      if (problem != null) {
        Log.error('Diarization', 'Model not installed: $problem');
        return plainWith(l10n.speakersModelsFailed, problem);
      }
      it = _find(it) ?? it;
      emit(
        _replace(
          state,
          it,
          it.copyWith(progress: 0, detail: l10n.jobDetailDiarizing),
        ),
      );
    }

    final diarizer = _diarizer = Diarizer();
    final watch = Stopwatch()..start();
    try {
      Log.info(
        'Diarization',
        'Started: ${it.name}, model=${DiarizationModels.file}, '
            'audio=${seconds.round()}s',
      );
      // Хода работы nemo-speech не печатает, поэтому полоса идёт по
      // оценке времени: к 90 % она подходит за ожидаемый срок и дальше
      // почти стоит, пока не придёт ответ. Срок — десятая доля записи:
      // на Metal выходит быстрее (0.03–0.06), на процессоре — около 0.14.
      // ponytail: оценка, а не ход работы; заменить настоящим, если
      // движок начнёт печатать долю готового.
      final expectMs = math.max(5000.0, seconds * 100);
      final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final share = 0.9 * (1 - math.exp(-watch.elapsedMilliseconds / expectMs));
        add(JobAdvanced(it, progress: share));
      });
      final List<SpeakerTurn> raw;
      try {
        raw = await diarizer.run(wav, DiarizationModels.path);
      } finally {
        ticker.cancel();
      }
      final turns = relabelTurns(raw);
      Log.info(
        'Diarization',
        'Done: ${it.name}, ${turns.length} turns, '
            '${turns.map((t) => t.clusterId).toSet().length} voices, '
            '${watch.elapsedMilliseconds}ms',
      );
      // Речи не нашлось — это не сбой: в тишине голосов и не бывает.
      if (turns.isEmpty) return plainWith(l10n.speakersNoSpeech);
      final voiced = finishSpeakers(
        build(turns),
        info: const DiarizationInfo(
          model: DiarizationModels.file,
          detectedSpeakers: 0,
        ),
        defaultName: l10n.speakerDefaultName,
      );
      if (!voiced.hasSpeakers) {
        return (transcript: voiced, note: l10n.speakersSingle, problem: null);
      }
      return (
        transcript: voiced,
        note: l10n.speakersFound(voiced.speakers.length),
        problem: null,
      );
    } on DiarizationCancelled {
      return plainWith(l10n.speakersStopped);
    } catch (err, st) {
      Log.error('Diarization', 'Failed: ${it.name}', err, st);
      return plainWith(l10n.speakersFailed, '$err');
    } finally {
      _diarizer = null;
    }
  }

  /// Определить голоса в готовой расшифровке — по кнопке.
  ///
  /// Звук готовится заново: временный WAV распознавания к этому времени
  /// уже удалён. Слов с потокенным временем здесь тоже нет, поэтому
  /// фрагменты режутся по доле символов — чуть грубее, чем сразу после
  /// распознавания.
  Future<void> _onDiarizationRequested(
    DiarizationRequested e,
    Emitter<QueueState> emit,
  ) async {
    final job = _find(e.job);
    final t = job?.transcript;
    if (job == null || t == null || job.imported || state.running) return;
    emit(state.copyWith(running: true));
    _stopRequested = false;
    _pauseWanted = false;
    _pauseAfterStep = false;
    _syncPolling();
    final tmp = await Directory.systemTemp.createTemp(appName);
    try {
      final wav = await os.toWav(job.path, os.join(tmp.path, 'voices.wav'));
      final plain = t.copyWith(
        segments: [for (final s in t.segments) s.withSpeaker(null, overlap: false)],
        clearSpeakers: true,
      );
      Transcript build([List<SpeakerTurn> turns = const []]) => turns.isEmpty
          ? plain
          : plain.copyWith(
              segments: splitAllBySpeakers(
                [for (final s in plain.segments) (s, const [])],
                turns,
              ),
            );
      final opts = state.optionsFor(job);
      final voiced = await _diarizeStep(
        job,
        opts,
        wav,
        plain,
        emit,
        build,
        manual: true,
      );
      // Имена, которые уже дали голосам, переживают повторную разметку:
      // метки стабильны (порядок первого появления), и «Иван» остаётся
      // за тем же голосом, если разметка нашла его снова.
      final named = voiced.transcript.hasSpeakers
          ? voiced.transcript.copyWith(
              speakers: [
                for (final s in voiced.transcript.speakers)
                  s.copyWith(
                    name:
                        t.speakers
                            .where((old) => old.id == s.id)
                            .firstOrNull
                            ?.name ??
                        s.name,
                  ),
              ],
            )
          : voiced.transcript;
      final now = _find(job) ?? job;
      final done = now.copyWith(
        state: JobState.done,
        transcript: named,
        progress: 1,
        detail: [
          currentL10n().jobDetailLangSegments(
            languageName(named.lang),
            segmentsLabel(named.segments.length),
          ),
          if (voiced.note.isNotEmpty) voiced.note,
        ].join(' · '),
        error: voiced.problem,
      );
      emit(
        _replace(state, now, done).copyWith(
          status: voiced.note.isEmpty ? state.status : voiced.note,
        ),
      );
      await _rewriteStoredTranscript(done);
    } catch (err, st) {
      Log.error('Diarization', 'Manual run failed: ${job.name}', err, st);
      final now = _find(job) ?? job;
      emit(
        _replace(
          state,
          now,
          now.copyWith(state: JobState.done, error: '$err'),
        ).copyWith(status: currentL10n().speakersFailed),
      );
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      emit(state.copyWith(running: false));
      _syncPolling();
    }
  }

  /// Записать правку голосов: в очередь и в уже сохранённые копии
  /// (рядом с записью и в библиотеке) — так же, как отмена голосовой
  /// замены. Новых файлов не создаём.
  Future<void> _changeSpeakers(
    Job job,
    Transcript changed,
    Emitter<QueueState> emit,
    String status,
  ) async {
    final now = job.copyWith(transcript: changed);
    emit(_replace(state, job, now).copyWith(status: status));
    await _rewriteStoredTranscript(now);
  }

  Future<void> _onSpeakerRenamed(
    SpeakerRenamed e,
    Emitter<QueueState> emit,
  ) async {
    final job = _find(e.job);
    final t = job?.transcript;
    if (job == null || t == null) return;
    final l10n = currentL10n();
    final name = e.name.trim();
    final speakers = [
      for (final s in t.speakers)
        if (s.id == e.speaker)
          s.copyWith(
            name: name.isEmpty
                ? l10n.speakerDefaultName(speakerNumber(s.id))
                : name,
          )
        else
          s,
    ];
    await _changeSpeakers(
      job,
      t.copyWith(speakers: speakers),
      emit,
      l10n.statusSpeakerRenamed(
        speakers.where((s) => s.id == e.speaker).firstOrNull?.name ?? name,
      ),
    );
  }

  Future<void> _onSpeakersMerged(
    SpeakersMerged e,
    Emitter<QueueState> emit,
  ) async {
    final job = _find(e.job);
    final t = job?.transcript;
    if (job == null || t == null || e.from == e.into) return;
    final changed = finishSpeakers(
      t.copyWith(
        segments: [
          for (final s in t.segments)
            s.speaker == e.from ? s.withSpeaker(e.into) : s,
        ],
      ),
      info: t.diarization,
      defaultName: currentL10n().speakerDefaultName,
    );
    await _changeSpeakers(
      job,
      changed,
      emit,
      currentL10n().statusSpeakersMerged(
        t.speakerName(e.from),
        t.speakerName(e.into),
      ),
    );
  }

  Future<void> _onSegmentSpeakerChanged(
    SegmentSpeakerChanged e,
    Emitter<QueueState> emit,
  ) async {
    final job = _find(e.job);
    final t = job?.transcript;
    if (job == null || t == null) return;
    final current = t.segments.where((s) => identical(s, e.segment)).firstOrNull;
    if (current == null || current.speaker == e.speaker) return;
    final replaced = job.replaceSegment(current, current.withSpeaker(e.speaker));
    final changed = finishSpeakers(
      replaced.transcript!,
      info: t.diarization,
      defaultName: currentL10n().speakerDefaultName,
    );
    await _changeSpeakers(
      job,
      changed,
      emit,
      currentL10n().statusSegmentReassigned(t.speakerName(e.speaker)),
    );
  }

  /// Почтовый ящик для разговоров из диктовки. Диктовка живёт в изоляте
  /// панели, очередь — здесь; оба в одном процессе, и порт находится по
  /// имени. Прежнее имя могло остаться от закрытого окна — заменяем.
  final _conversationInbox = ReceivePort('conversation-inbox');

  void _openConversationInbox() {
    IsolateNameServer.removePortNameMapping(conversationInboxPort);
    IsolateNameServer.registerPortWithName(
      _conversationInbox.sendPort,
      conversationInboxPort,
    );
    _conversationInbox.listen((message) {
      if (message is Map && message['path'] is String && !isClosed) {
        add(ConversationReceived(message['path'] as String));
      }
    });
  }

  Future<void> _onConversationReceived(
    ConversationReceived e,
    Emitter<QueueState> emit,
  ) async {
    await _onFilesAdded(FilesAdded([e.path]), emit);
    final job = _find(Job(File(e.path)));
    if (job == null) return;
    // Разговор — это несколько голосов почти по определению: режим
    // включается для этой записи, что бы ни стояло в общих настройках.
    emit(
      _replace(
        state,
        job,
        job.copyWith(
          overrides: (job.overrides ?? state.defaults).copyWith(diarize: true),
        ),
      ),
    );
    if (!state.running) add(const RunRequested());
  }

  void _onJobOptionsEdited(JobOptionsEdited e, Emitter<QueueState> emit) {
    final job = state.jobs.where((j) => j.path == e.path).firstOrNull;
    if (job == null) return;
    emit(
      _replace(
        state,
        job,
        job.copyWith(overrides: e.change(job.overrides ?? state.defaults)),
      ),
    );
  }

  void _onStop(StopRequested e, Emitter<QueueState> emit) {
    if (!state.running) return;
    _stopRequested = true;
    _proc?.kill();
    _diarizer?.cancel();
    emit(state.copyWith(status: currentL10n().statusStopping));
  }

  /// Диктовка главнее очереди: одновременно две копии модели в память
  /// не помещаются, а фраза длится секунды и прерванная пропадает совсем.
  ///
  /// Ждём только настоящую работу — запись или распознавание фразы. Модель,
  /// которая просто лежит в памяти, забираем молча: согласие на это уже
  /// спросили перед запуском очереди.
  Future<bool> _yieldToDictation(Job job, Emitter<QueueState> emit) async {
    var paused = false;
    while (!_stopRequested) {
      final status = await dictation.status();
      if (status == DictationStatus.away) break;
      if (status == DictationStatus.resting) {
        await dictation.release();
        break;
      }
      if (!paused) {
        final now = _find(job);
        if (now != null) {
          emit(
            _replace(
              state,
              now,
              now.copyWith(state: JobState.waiting),
            ).copyWith(status: currentL10n().statusPausedDictation),
          );
        }
        paused = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (paused && !_stopRequested) {
      emit(state.copyWith(status: currentL10n().statusDictationDoneResuming));
    }
    return !_stopRequested;
  }

  // ── куда ложится результат ────────────────────────────────────────────────

  /// Копия текста рядом с исходной записью. Имя выбирается один раз и
  /// запоминается за записью: повторное распознавание обновит свой файл,
  /// а чужой `запись.txt`, лежавший рядом до нас, не тронет.
  Future<({String? path, String? problem})> _saveBesideSource(
    Job job,
    Transcript t,
  ) async {
    try {
      final dir = job.file.parent.path;
      final path =
          job.besideSource ??
          os.join(dir, '${freeStem(dir, _stem(job.name), '.txt')}.txt');
      await File(
        path,
      ).writeAsString(renderPlain(t.segments, false, speakers: t.speakers));
      return (path: path, problem: null);
    } catch (e) {
      stderr.writeln('tsukiko: копия рядом с записью не легла — $e');
      return (path: null, problem: currentL10n().errorCopyBesideFailed);
    }
  }

  /// Раскладка по месяцам; когда форматов больше одного — у записи своя
  /// папка. Возвращает строку для статуса или null.
  Future<String?> _fileToLibrary(Job job, Transcript t) async {
    if (state.libraryFormats.isEmpty) return null;
    try {
      final formats = state.libraryFormats.map(formatById).toList();
      final existing = Sources.transcriptsFor(state.libraryPath, job.path);
      if (existing.isNotEmpty) {
        final represented = <String>{};
        final written = <String>[];
        // Все форматы прежней расшифровки перезаписываются новым
        // результатом. Другая модель не рождает «Запись 2» — она улучшает
        // ту же запись. Если форматы в настройках расширили, недостающие
        // ложатся рядом, но уже имеющиеся не дублируются.
        for (final path in existing) {
          final format = formatOfFile(path);
          if (format == null) continue;
          await File(path).writeAsString(renderFor(format, t, name: job.name));
          represented.add(format.id);
          written.add(path);
        }
        final dir = os.dirname(existing.first);
        for (final format in formats.where(
          (f) => !represented.contains(f.id),
        )) {
          final stem = freeStem(dir, _stem(job.name), format.suffix);
          final path = os.join(dir, format.fileName(stem));
          await File(path).writeAsString(renderFor(format, t, name: job.name));
          written.add(path);
        }
        Sources.remember(state.libraryPath, written, job.path);
        return currentL10n().statusSavedInLibrary(
          dir.replaceFirst(state.libraryPath, appName),
        );
      }
      final plan = planPlacement(
        root: state.libraryPath,
        stem: _stem(job.name),
        formatCount: formats.length,
      );
      await Directory(plan.dir).create(recursive: true);
      final stem = formats.length == 1
          ? freeStem(plan.dir, plan.stem, formats.first.suffix)
          : plan.stem;
      final written = <String>[];
      for (final f in formats) {
        final path = os.join(plan.dir, f.fileName(stem));
        await File(path).writeAsString(renderFor(f, t, name: job.name));
        written.add(path);
      }
      // Расшифровка помнит, из какой записи вышла. Иначе через полгода
      // текст в библиотеке есть, а что с ним делать — непонятно:
      // ни распознать другой моделью, ни нарезать субтитры заново.
      Sources.remember(state.libraryPath, written, job.path);
      return currentL10n().statusSavedInLibrary(
        plan.dir.replaceFirst(state.libraryPath, appName),
      );
    } catch (e) {
      stderr.writeln('tsukiko: библиотека не приняла запись — $e');
      return currentL10n().errorLibrarySaveFailed;
    }
  }

  // ── экспорт ───────────────────────────────────────────────────────────────

  /// Импортированный текст без разметки отдаём как есть, всё остальное —
  /// в запрошенном формате.
  String _render(Job job, ExportFormat f) {
    final t = job.transcript;
    if (t == null) return job.raw ?? renderPlain(job.live, f.id == 'txt-ts');
    return renderFor(f, t, name: job.name);
  }

  Future<void> _onCopy(CopyRequested e, Emitter<QueueState> emit) async {
    final jobs = state.readyTargets;
    // Копировать нечего — но выбор формата это настройка, а не действие,
    // и запомнить её надо. Иначе список форматов оставался бы серым ровно
    // до первой готовой расшифровки, то есть до того мгновения, когда он
    // уже не нужен.
    if (jobs.isEmpty) {
      emit(
        state.copyWith(
          copyFormat: e.format.id,
          status: currentL10n().statusCopyFormatChosen(
            e.format.label.toLowerCase(),
          ),
        ),
      );
      _persist();
      return;
    }
    // Несколько записей склеиваются с заголовками — иначе в буфере стена
    // текста, в которой не видно, где кончилась одна запись.
    final text = jobs.length == 1
        ? _render(jobs.first, e.format)
        : jobs
              .map((j) => '— ${j.name} —\n${_render(j, e.format)}')
              .join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    emit(
      state.copyWith(
        copyFormat: e.format.id,
        status: jobs.length == 1
            ? currentL10n().statusCopiedFormat(e.format.label.toLowerCase())
            : currentL10n().statusCopiedRecords(
                jobs.length,
                e.format.label.toLowerCase(),
              ),
      ),
    );
    _persist();
  }

  Future<void> _onSave(SaveRequested e, Emitter<QueueState> emit) async {
    try {
      await File(e.path).writeAsString(_render(e.job, e.format));
      emit(
        state.copyWith(
          saveFormat: e.format.id,
          status: currentL10n().statusSavedFile(os.basename(e.path)),
        ),
      );
    } catch (err) {
      stderr.writeln('tsukiko: не удалось сохранить — $err');
      emit(state.copyWith(status: currentL10n().errorSaveFileFailed));
    }
    _persist();
  }

  Future<void> _onExport(ExportRequested e, Emitter<QueueState> emit) async {
    if (e.formats.isEmpty) return;
    var written = 0;
    try {
      // Свободное имя ищем сразу под все форматы: иначе экспорт текста
      // и субтитров в папку, где такие имена уже лежат, затрёт их.
      for (final job in e.jobs) {
        final stem = freeStemFor(
          e.dir,
          _stem(job.name),
          e.formats.map((f) => f.suffix).toList(),
        );
        for (final f in e.formats) {
          await File(
            os.join(e.dir, f.fileName(stem)),
          ).writeAsString(_render(job, f));
          written++;
        }
      }
      emit(
        state.copyWith(
          status: currentL10n().statusExported(filesLabel(written)),
        ),
      );
    } catch (err) {
      stderr.writeln('tsukiko: экспорт оборвался — $err');
      emit(state.copyWith(status: currentL10n().errorExportFailed));
    }
  }

  // ── модели ────────────────────────────────────────────────────────────────

  void _onModelChosen(ModelChosen e, Emitter<QueueState> emit) {
    emit(
      state.copyWith(
        models: state.models.contains(e.path)
            ? state.models
            : [...state.models, e.path],
      ),
    );
    add(OptionsEdited((o) => o.copyWith(model: e.path)));
  }

  Future<void> _onDownload(
    ModelDownloadRequested e,
    Emitter<QueueState> emit,
  ) async {
    if (_download != null) return;
    final path = await _fetch(
      e.offer,
      Download(e.offer.url, e.offer.path, title: e.offer.title),
      emit,
    );
    // Пункт в списке моделей означает «выбрать эту модель», а не просто
    // положить файл на склад. После загрузки применяем её и тогда, когда
    // до этого уже была выбрана другая.
    if (path != null) {
      add(OptionsEdited((o) => o.copyWith(model: path)));
    }
  }

  Future<void> _onVad(VadRequested e, Emitter<QueueState> emit) async {
    if (!e.on) {
      add(OptionsEdited((o) => o.copyWith(vad: false)));
      return;
    }
    if (File(vadModelPath).existsSync()) {
      add(OptionsEdited((o) => o.copyWith(vadModel: vadModelPath, vad: true)));
      return;
    }
    // Диктовка качает модель тишины в ту же папку — если она уже это
    // сделала, спрашивать нечего. Не вышло — остаётся выбрать файл руками.
    final path = await _fetch(
      null,
      Download(
        vadModelUrl,
        vadModelPath,
        title: currentL10n().vadDownloadTitle,
      ),
      emit,
    );
    if (path != null) {
      add(OptionsEdited((o) => o.copyWith(vadModel: path, vad: true)));
    } else {
      emit(state.copyWith(status: currentL10n().statusPickVadManually));
    }
  }

  void _onVadModelChosen(VadModelChosen e, Emitter<QueueState> emit) {
    add(
      e.path == null
          ? OptionsEdited((o) => o.copyWith(vad: false))
          : OptionsEdited((o) => o.copyWith(vadModel: e.path, vad: true)),
    );
  }

  /// Одна загрузка на всё окно: сеть общая, а два полуторагиговых файла
  /// разом просто мешают друг другу.
  Future<String?> _fetch(
    ModelOffer? offer,
    Download d,
    Emitter<QueueState> emit,
  ) async {
    _download = d;
    emit(
      state.copyWith(
        download: offer,
        downloadProgress: d.progressLabel,
        downloadPercent: d.percent,
        status: currentL10n().statusDownloadingTitle(d.title),
      ),
    );
    final path = await d.run(
      onProgress: () {
        if (!isClosed) add(DownloadAdvanced(d.progressLabel, d.percent));
      },
    );
    _download = null;
    emit(
      state.copyWith(
        clearDownload: true,
        models: path != null
            ? _withOwn(findModels(), state.defaults.model)
            : null,
        status: path != null
            ? currentL10n().statusDownloadedTitle(d.title)
            : d.cancelled
            ? currentL10n().statusDownloadCancelled
            : currentL10n().statusDownloadFailedTitle(d.title),
      ),
    );
    return path;
  }

  // ── что делает диктовка ───────────────────────────────────────────────────

  /// Значок в строке состояния — единственное, ради чего идёт опрос.
  /// Свёрнутому окну он не нужен; идущей очереди — нужен всегда, она сама
  /// смотрит на тот же ответ, когда уступает.
  void _syncPolling() {
    final needed = state.running || _windowVisible;
    if (needed == (_pollTimer != null)) return;
    if (!needed) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    add(const DictationPolled());
    // Полторы секунды: это подпись на значке, а не управление. Прежний
    // опрос ходил дважды в секунду, и каждый заход стоил трёх процессов.
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => add(const DictationPolled()),
    );
  }

  void _onVisibility(WindowVisibilityChanged e, Emitter<QueueState> emit) {
    _windowVisible = e.visible;
    _syncPolling();
  }

  Future<void> _onDictationPolled(
    DictationPolled e,
    Emitter<QueueState> emit,
  ) async {
    // Снимок берём после ответа, а не до: пока идёт вопрос, состояние
    // успевает измениться, и старый снимок затёр бы чужую правку.
    final status = await dictation.status();
    emit(state.copyWith(dictation: status));
  }

  // ── настройки приложения ──────────────────────────────────────────────────

  void _onTimestampsToggled(TimestampsToggled e, Emitter<QueueState> emit) {
    emit(state.copyWith(timestamps: !state.timestamps));
    _persist();
  }

  void _onRecentCleared(RecentCleared e, Emitter<QueueState> emit) {
    emit(state.copyWith(recent: const []));
    _persist();
  }

  /// Настройки поменяли в другом окне. Перечитываем то, чем это окно
  /// пользуется, но чего больше не правит.
  void _onSettingsReloaded(SettingsReloaded e, Emitter<QueueState> emit) {
    final s = Settings.load();
    final selectedModel = s['model'] as String?;
    final models = findModels();
    _setVocabulary(loadAndMigrateVocabulary(s));
    _commandsEnabled =
        (s[vocabularyTranscriberEnabledSetting] as bool?) ??
        (s[transcriberCommandsEnabledSetting] as bool?) ??
        true;
    final formats = (s['libraryFormats'] as List?)
        ?.cast<String>()
        .where((v) => exportFormats.any((f) => f.id == v))
        .toList();
    emit(
      state.copyWith(
        timestamps: (s['timestamps'] as bool?) ?? state.timestamps,
        saveNextToSource:
            (s['saveNextToSource'] as bool?) ?? state.saveNextToSource,
        toLibrary: (s['toLibrary'] as bool?) ?? state.toLibrary,
        libraryPath: (s['libraryPath'] as String?) ?? state.libraryPath,
        libraryFormats: formats != null && formats.isNotEmpty
            ? formats
            : state.libraryFormats,
        copyFormat: s['copyFormat'] == null
            ? state.copyFormat
            : _knownFormat(s['copyFormat']),
        saveFormat: s['saveFormat'] == null
            ? state.saveFormat
            : _knownFormat(s['saveFormat']),
        // На вкладке «Модели» теперь можно не только скачать файл, но и
        // назначить его новым расшифровкам. Открытая запись хранит свой
        // выбор, поэтому меняем именно defaults.
        // «Несколько голосов» по умолчанию тоже можно включить в окне
        // настроек — ключ общий с умолчаниями очереди.
        defaults: (selectedModel == null
                ? state.defaults
                : state.defaults.copyWith(model: selectedModel))
            .copyWith(diarize: s['diarize'] as bool?),
        models: _withOwn(models, selectedModel ?? state.defaults.model),
        vocabulary: _vocabulary,
      ),
    );
    // Галку API правит окно настроек, а сервер живёт здесь — узнать
    // о перемене можно только отсюда.
    unawaited(api.sync());
  }

  /// Раньше настройки писались только при выходе, и ⌘Q мимо dispose стирал
  /// все правки за сеанс. Теперь пишем сразу, но не чаще раза в полсекунды —
  /// иначе каждая буква в подсказке уходила бы на диск.
  void _persist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_persistNow()),
    );
  }

  /// Пишем только своё: библиотеку и поведение приложения правит окно
  /// настроек, и его ключи Settings.save оставляет в файле нетронутыми.
  Future<void> _persistNow() async {
    final savedModel = Settings.load()['model'] as String?;
    await Settings.save({
      ...state.defaults.toJson(),
      // Выбор другой модели в инспекторе делает расшифровщик опорной
      // стороной. Правки языка, подсказки и других полей связь не рвут.
      if (savedModel != state.defaults.model)
        transcriberUsesDictationModelSetting: false,
      'timestamps': state.timestamps,
      'copyFormat': state.copyFormat,
      'saveFormat': state.saveFormat,
      'recent': state.recent,
    });
    Prompts.write(Prompts.transcriber, state.defaults.prompt);
    // Форматы правятся и здесь, и в отдельном окне настроек. Сообщаем
    // соседним Flutter-движкам только после записи на диск, чтобы они
    // перечитали уже новое значение и оба окна оставались одним целым.
    await bridge.settingsChanged();
  }

  @visibleForTesting
  Future<void> flushSettings() async => _persistNow();

  @override
  Future<void> close() {
    _conversationInbox.close();
    IsolateNameServer.removePortNameMapping(conversationInboxPort);
    _saveTimer?.cancel();
    // Опрос диктовки идёт по таймеру и кончается событием в этот же блок.
    // Не погасить его — значит после закрытия получить «событие в
    // закрытый блок»: в приложении это видно только на выходе, а в
    // тестах роняет соседей, которые уже прошли.
    _pollTimer?.cancel();
    _settingsSub?.cancel();
    unawaited(api.stop());
    _proc?.kill();
    _releaseTemp();
    unawaited(_persistNow());
    return super.close();
  }
}

/// Построчный декодер с защитой от mojibake на Windows.
///
/// whisper-cli и nemo-speech всегда пишут текстовые сегменты распознавания
/// в stdout в кодировке UTF-8 независимо от региональных настроек Windows.
/// Если на русской Windows декодировать этот вывод системной кодировкой (CP1251),
/// двухбайтовая кириллица UTF-8 превращается в нечитаемый «РџСЂРёРІРµС‚».
///
/// В то же время сообщения об ошибках от CRT (например, при сбое запуска
/// с кириллическими путями C:\Users\...) могут попадать в stderr в системной
/// кодировке (Windows-1251).
///
/// Этот трансформер разбивает поток байтов на строки по \n или \r и декодирует
/// каждую строку как UTF-8. Если байты строки не являются валидным UTF-8,
/// выполняется откат к systemEncoding, а при редких сбоях — к UTF-8 с
/// заменой повреждённых байтов.
@visibleForTesting
StreamTransformer<T, String> resilientLineDecoder<T extends List<int>>() {
  final buffer = BytesBuilder(copy: false);
  var crLast = false;

  void emitLine(EventSink<String> sink) {
    final bytes = buffer.takeBytes();
    sink.add(_decodeResilientBytes(bytes));
  }

  return StreamTransformer<T, String>.fromHandlers(
    handleData: (T chunk, EventSink<String> sink) {
      for (var i = 0; i < chunk.length; i++) {
        final b = chunk[i];
        if (crLast) {
          crLast = false;
          if (b == 10) {
            continue;
          }
        }
        if (b == 10) {
          emitLine(sink);
        } else if (b == 13) {
          crLast = true;
          emitLine(sink);
        } else {
          buffer.addByte(b);
        }
      }
    },
    handleDone: (EventSink<String> sink) {
      if (buffer.isNotEmpty || crLast) {
        emitLine(sink);
      }
      sink.close();
    },
  );
}

String _decodeResilientBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    try {
      return systemEncoding.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

/// Нормализация пути к файлу: обрезка пробелов, кавычек, спецсимволов и разбор file://
String normalizePath(String raw) => QueueBloc.normalizePath(raw);
