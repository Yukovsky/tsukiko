import 'package:equatable/equatable.dart';

import '../../core/models.dart';
import '../../core/transcript.dart';
import '../../core/whisper.dart';
import '../../core/vocabulary.dart';
import 'job.dart';

/// Что случилось с очередью.
///
/// Полный Bloc, а не Cubit: здесь события нужны по делу. «Распознать» при
/// уже идущей очереди отбрасывается трансформером, а не проверкой внутри
/// обработчика; порядок и содержание событий видны в журнале, и по нему
/// читается, что происходило перед сбоем.
sealed class QueueEvent extends Equatable {
  const QueueEvent();

  @override
  List<Object?> get props => const [];
}

// ── очередь ─────────────────────────────────────────────────────────────────

/// Добавить файлы. Папки разворачиваются, готовые расшифровки открываются,
/// чужие расширения отбрасываются с объяснением.
class FilesAdded extends QueueEvent {
  const FilesAdded(this.paths);
  final Iterable<String> paths;

  @override
  List<Object?> get props => [paths];
}

/// Открыть готовую расшифровку как запись очереди.
class TranscriptOpened extends QueueEvent {
  const TranscriptOpened(this.path);
  final String path;

  @override
  List<Object?> get props => [path];
}

class SelectedRemoved extends QueueEvent {
  const SelectedRemoved();
}

class FinishedCleared extends QueueEvent {
  const FinishedCleared();
}

// ── выделение ───────────────────────────────────────────────────────────────

class JobSelected extends QueueEvent {
  const JobSelected(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class JobToggled extends QueueEvent {
  const JobToggled(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class SelectionExtended extends QueueEvent {
  const SelectionExtended(this.job);
  final Job job;

  @override
  List<Object?> get props => [job];
}

class SelectionStepped extends QueueEvent {
  const SelectionStepped(this.delta, {this.extend = false});
  final int delta;
  final bool extend;

  @override
  List<Object?> get props => [delta, extend];
}

class AllSelected extends QueueEvent {
  const AllSelected();
}

class SelectionCleared extends QueueEvent {
  const SelectionCleared();
}

// ── распознавание ───────────────────────────────────────────────────────────

/// Запустить очередь. Отбрасывается, пока она уже идёт.
class RunRequested extends QueueEvent {
  const RunRequested();
}

/// Ответ на вопрос «модель занята, продолжить?».
class RunConfirmed extends QueueEvent {
  const RunConfirmed(this.yes);
  final bool yes;

  @override
  List<Object?> get props => [yes];
}

/// Распознать выбранное заново, забыв прежний результат.
class RetryRequested extends QueueEvent {
  const RetryRequested();
}

class StopRequested extends QueueEvent {
  const StopRequested();
}

/// Приостановить распознавание. От остановки отличается тем, что
/// посчитанное остаётся, и второй заход начнётся с того же места,
/// а не с начала записи.
class PauseRequested extends QueueEvent {
  const PauseRequested();
}

class ResumeRequested extends QueueEvent {
  const ResumeRequested();
}

/// Строку очереди перетащили на другое место. Порядок — это и есть
/// очерёдность: следующей берётся первая недоделанная сверху.
class JobsReordered extends QueueEvent {
  const JobsReordered(this.from, this.to);
  final int from, to;

  @override
  List<Object?> get props => [from, to];
}

/// Внутреннее: whisper-cli выдал очередной фрагмент, процент или язык.
class JobAdvanced extends QueueEvent {
  const JobAdvanced(this.job, {this.segment, this.progress, this.language});
  final Job job;
  final Segment? segment;
  final double? progress;
  final String? language;

  @override
  List<Object?> get props => [job.path, segment, progress, language];
}

/// Вернуть одну автоматически заменённую команду к сказанным словам.
class CommandReplacementUndone extends QueueEvent {
  const CommandReplacementUndone(this.job, this.segment, this.index);

  final Job job;
  final Segment segment;
  final int index;

  @override
  List<Object?> get props => [job.path, segment, index];
}

// ── голоса ──────────────────────────────────────────────────────────────────

/// Переименовать голос. Меняется только список голосов: фрагменты
/// ссылаются на метку («S1»), а не на имя. Пустое имя — вернуть имя
/// по умолчанию.
class SpeakerRenamed extends QueueEvent {
  const SpeakerRenamed(this.job, this.speaker, this.name);
  final Job job;
  final String speaker, name;

  @override
  List<Object?> get props => [job.path, speaker, name];
}

/// Слить голос [from] в голос [into]: одного человека разметка
/// разбила на два. Только руками — автоматическое слияние по близости
/// голосов ошибается чаще, чем помогает (замер YazSes на 16 встречах).
class SpeakersMerged extends QueueEvent {
  const SpeakersMerged(this.job, this.from, this.into);
  final Job job;
  final String from, into;

  @override
  List<Object?> get props => [job.path, from, into];
}

/// Отдать один фрагмент другому голосу.
class SegmentSpeakerChanged extends QueueEvent {
  const SegmentSpeakerChanged(this.job, this.segment, this.speaker);
  final Job job;
  final Segment segment;
  final String speaker;

  @override
  List<Object?> get props => [job.path, segment, speaker];
}

/// Включить или выключить «Несколько голосов» — там же, куда уходят
/// остальные правки инспектора (см. [OptionsEdited]).
class DiarizationToggled extends QueueEvent {
  const DiarizationToggled(this.enabled);
  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// Определить голоса в уже готовой расшифровке: режим включили после
/// распознавания, запись длиннее предела или прошлый прогон не удался.
class DiarizationRequested extends QueueEvent {
  const DiarizationRequested(this.job);
  final Job job;

  @override
  List<Object?> get props => [job.path];
}

/// Разговор, записанный из диктовки: встать в очередь с разметкой
/// голосов и сразу начать.
class ConversationReceived extends QueueEvent {
  const ConversationReceived(this.path);
  final String path;

  @override
  List<Object?> get props => [path];
}

/// Внутреннее: правка настроек одной записи по пути — для местного API,
/// у которого нет выделения.
class JobOptionsEdited extends QueueEvent {
  const JobOptionsEdited(this.path, this.change);
  final String path;
  final RunOptions Function(RunOptions) change;

  @override
  List<Object?> get props => [path, change];
}

// ── настройки распознавания ─────────────────────────────────────────────────

/// Правка уходит туда, куда смотрит инспектор: в общие настройки или
/// во все выбранные записи сразу.
class OptionsEdited extends QueueEvent {
  const OptionsEdited(this.change);
  final RunOptions Function(RunOptions) change;

  @override
  List<Object?> get props => [change];
}

class OverridesReset extends QueueEvent {
  const OverridesReset();
}

class LeadOptionsMadeDefault extends QueueEvent {
  const LeadOptionsMadeDefault();
}

/// Добавить слово в подсказку модели или создать правило автозамены в словаре.
class VocabularyReplacementAdded extends QueueEvent {
  const VocabularyReplacementAdded({
    required this.phrase,
    this.replacement = '',
    this.removeFromPrompt = false,
  });

  final String phrase;
  final String replacement;
  final bool removeFromPrompt;

  @override
  List<Object?> get props => [phrase, replacement, removeFromPrompt];
}

// ── модели ──────────────────────────────────────────────────────────────────

class ModelChosen extends QueueEvent {
  const ModelChosen(this.path);
  final String path;

  @override
  List<Object?> get props => [path];
}

class ModelDownloadRequested extends QueueEvent {
  const ModelDownloadRequested(this.offer);
  final ModelOffer offer;

  @override
  List<Object?> get props => [offer.file];
}

class DownloadCancelled extends QueueEvent {
  const DownloadCancelled();
}

/// Внутреннее: у идущей загрузки сдвинулся процент.
class DownloadAdvanced extends QueueEvent {
  const DownloadAdvanced(this.progress, this.percent);
  final String progress;
  final int percent;

  @override
  List<Object?> get props => [progress, percent];
}

class VadRequested extends QueueEvent {
  const VadRequested(this.on);
  final bool on;

  @override
  List<Object?> get props => [on];
}

class VadModelChosen extends QueueEvent {
  const VadModelChosen(this.path);
  final String? path;

  @override
  List<Object?> get props => [path];
}

// ── прочее ──────────────────────────────────────────────────────────────────

/// Спросить у диктовки, чем она занята.
///
/// Раньше на это место приходил опрос чужих процессов: `pgrep`, `ps`
/// и `lsof` дважды в секунду — приложение искало, не держит ли модель
/// кто-то посторонний. Посторонних больше нет, диктовка своя, и весь
/// ответ — один вызов через родную сторону.
class DictationPolled extends QueueEvent {
  const DictationPolled();
}

/// Окно на виду или свёрнуто: невидимому окну значок не нужен.
class WindowVisibilityChanged extends QueueEvent {
  const WindowVisibilityChanged(this.visible);
  final bool visible;

  @override
  List<Object?> get props => [visible];
}

class SettingsReloaded extends QueueEvent {
  const SettingsReloaded();
}

class LegacyPromptMigrated extends QueueEvent {
  const LegacyPromptMigrated(this.vocabulary);
  final List<VocabularyItem> vocabulary;

  @override
  List<Object?> get props => [vocabulary];
}

class TimestampsToggled extends QueueEvent {
  const TimestampsToggled();
}

class RecentCleared extends QueueEvent {
  const RecentCleared();
}

/// Записать готовые расшифровки в буфер обмена.
class CopyRequested extends QueueEvent {
  const CopyRequested(this.format);
  final ExportFormat format;

  @override
  List<Object?> get props => [format.id];
}

/// Положить в очередь запись вместе с уже готовой её расшифровкой.
///
/// Не то же, что [FilesAdded]: там появляется чистая запись, которую
/// надо считать. Здесь расшифровка уже есть — её сделали когда-то
/// и нашли в обзоре прошлых, — и открывать запись «готовой
/// к распознаванию» значило бы прятать сделанную работу. Считать заново
/// при этом никто не мешает: запись не «открыта из файла», а настоящая.
class SourceOpened extends QueueEvent {
  const SourceOpened(this.audio, this.transcript);

  /// Путь к звуку и путь к файлу его расшифровки.
  final String audio, transcript;

  @override
  List<Object?> get props => [audio, transcript];
}

/// Выбрали формат сохранения, а сохранять пока нечего.
///
/// Формат — это настройка, а не действие: его выбирают заранее, ещё до
/// того как в очереди появится хоть одна запись. Раньше оба списка
/// форматов были серыми, пока ничего не выбрано, — то есть настройку
/// нельзя было тронуть ровно тогда, когда до неё доходят руки.
/// У копирования для этого хватает [CopyRequested]: копировать нечего —
/// он просто запоминает формат.
class SaveFormatChosen extends QueueEvent {
  const SaveFormatChosen(this.format);
  final ExportFormat format;

  @override
  List<Object?> get props => [format.id];
}

/// Записать готовую расшифровку в указанный файл.
class SaveRequested extends QueueEvent {
  const SaveRequested(this.job, this.path, this.format);
  final Job job;
  final String path;
  final ExportFormat format;

  @override
  List<Object?> get props => [job.path, path, format.id];
}

/// Разложить готовые расшифровки по указанной папке.
class ExportRequested extends QueueEvent {
  const ExportRequested(this.jobs, this.dir, this.formats);
  final List<Job> jobs;
  final String dir;
  final List<ExportFormat> formats;

  @override
  List<Object?> get props => [jobs.length, dir, formats.length];
}

/// Сообщение прочитано — убрать его с экрана.
class AskDismissed extends QueueEvent {
  const AskDismissed();
}

/// Сказать что-нибудь в строке состояния. Нужно окну: часть действий
/// (копирование фрагмента, показ в проводнике) целиком его дело.
class StatusReported extends QueueEvent {
  const StatusReported(this.text);
  final String text;

  @override
  List<Object?> get props => [text];
}
