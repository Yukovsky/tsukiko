import '../platform/os.dart';
import 'app_locale.dart';
import 'transcript.dart';
import 'whisper.dart';

/// Всё, что произносится вслух: как называется состояние записи, формат
/// сохранения, строка меню и разрешение системы.
///
/// Отдельным файлом, а не рядом с самими понятиями, по одной причине,
/// и она не про красоту раскладки. Переводы — это `AppLocalizations`,
/// а он приходит из `package:flutter`. Ядро же обязано собираться и без
/// Flutter: из `whisper.dart`, `transcript.dart`, `library.dart` и границы
/// системы растёт `tsukiko-transcribe` — отдельная программа расшифровки
/// без единого пикселя интерфейса, и `dart compile exe` не соберёт её,
/// если по дороге встретится хоть один Flutter-импорт. Поэтому то, что
/// считается, живёт там, а то, что произносится, — здесь.
///
/// Проверка, что граница цела:
///
/// ```sh
/// grep -rn "package:flutter" lib/core/whisper.dart lib/core/transcript.dart \
///     lib/core/library.dart lib/platform/os*.dart
/// ```
///
/// Пусто — значит `dart compile exe bin/tsukiko_transcribe.dart` соберётся.

extension JobStateLabel on JobState {
  String get label {
    final l10n = currentL10n();
    return switch (this) {
      JobState.queued => l10n.jobStateQueued,
      JobState.waiting => l10n.jobStateWaiting,
      JobState.converting => l10n.jobStateConverting,
      JobState.transcribing => l10n.jobStateTranscribing,
      JobState.diarizing => l10n.jobStateDiarizing,
      JobState.paused => l10n.jobStatePaused,
      JobState.done => l10n.jobStateDone,
      JobState.failed => l10n.jobStateFailed,
      JobState.cancelled => l10n.jobStateCancelled,
    };
  }
}

extension RunOptionsDiff on RunOptions {
  /// Чем эта запись отличается от общих настроек — списком, для подписи
  /// «изменено: язык, модель».
  List<String> diffAgainst(RunOptions base) {
    final l10n = currentL10n();
    return [
      if (model != base.model) l10n.diffModel,
      if (lang != base.lang) l10n.diffLanguage,
      if (threads != base.threads) l10n.diffThreads,
      if (maxLen != base.maxLen) l10n.diffSegmentLength,
      if (vad != base.vad || vadModel != base.vadModel) 'VAD',
      if (prompt.trim() != base.prompt.trim()) l10n.diffPrompt,
      if (punctuate != base.punctuate) l10n.diffPunctuation,
      if (diarize != base.diarize || speakerCount != base.speakerCount)
        l10n.diffSpeakers,
    ];
  }
}

extension ExportFormatLabels on ExportFormat {
  /// Окончание имени файла. У текста с таймкодами оно со словом, и слово
  /// это интерфейсное: по-английски файл должен называться
  /// «(timestamps).txt», а не «(таймкоды).txt».
  String get suffix =>
      id == 'txt-ts' ? '${currentL10n().timedTextSuffix}.txt' : bareSuffix;

  /// Считается из [id], а не хранится: имя формата — интерфейсный текст,
  /// и меняться должно вместе с языком интерфейса, а не быть впаянным
  /// в константу на старте.
  String get label {
    final l10n = currentL10n();
    return switch (id) {
      'txt' => l10n.formatPlainTextLabel,
      'txt-ts' => l10n.formatTimedTextLabel,
      'srt' => l10n.formatSrtLabel,
      'vtt' => l10n.formatVttLabel,
      'json' => l10n.formatJsonLabel,
      _ => 'Markdown',
    };
  }

  String fileName(String stem) => '$stem$suffix';
  String get ext => suffix.substring(suffix.lastIndexOf('.'));
}

/// Каким форматом назван этот файл.
///
/// Сначала по полному окончанию, потом по расширению: «текст
/// с таймкодами» и обычный текст оба кончаются на «.txt», и различает их
/// только слово в имени. Ничего не узнали — null: выдуманный ответ здесь
/// хуже отсутствующего.
///
/// Окончание интерфейсное (см. [ExportFormatLabels.suffix]), поэтому
/// и живёт это здесь, а не рядом с самими форматами.
ExportFormat? formatOfFile(String path) {
  final name = path.toLowerCase();
  for (final f in exportFormats) {
    if (name.endsWith(f.suffix.toLowerCase())) return f;
  }
  for (final f in exportFormats) {
    if (name.endsWith(f.ext)) return f;
  }
  return null;
}

/// Расшифровка в выбранном формате — с переведённой шапкой markdown.
///
/// Приложение зовёт это, отдельная программа расшифровки — голый
/// [renderAs]: у неё нет переводов и не может быть.
String renderFor(ExportFormat f, Transcript t, {String name = ''}) {
  final l10n = currentL10n();
  return renderAs(f, t,
      name: name,
      markdownHeader: l10n.markdownHeader(
          name, t.lang, l10n.segmentsLabel(t.segments.length)));
}

/// Как система называет свои вещи. Раньше это лежало в `os_macos.dart`
/// и `os_windows.dart`, но там нельзя: те два файла нужны программе
/// расшифровки, а переводы тянут за собой Flutter. Выбор системы идёт
/// по [Os.platformId], а не по `Platform.isMacOS`, — граница системы
/// по-прежнему одна.
extension OsLabels on Os {
  /// Что сказать человеку, у которого движка не оказалось.
  String get whisperInstallHint => platformId == 'macos'
      ? currentL10n().whisperInstallHint
      : currentL10n().whisperInstallHintWindows;

  /// Куда приложение уходит, оставшись без значка.
  String get menuBarName =>
      platformId == 'macos'
          ? currentL10n().menuBarNameLabel
          : currentL10n().trayAreaName;

  /// Как система зовёт разрешение, без которого нельзя ни перехватить
  /// клавишу, ни вставить текст в чужое окно.
  ///
  /// Язык здесь системный, а не выбранный в приложении: человек пойдёт
  /// искать эту панель в настройках системы и должен увидеть там ровно
  /// то слово, которое мы назвали.
  String get accessibilityName => platformId == 'macos'
      ? systemL10n().accessibilityPermissionName
      : 'специальные возможности';
}
