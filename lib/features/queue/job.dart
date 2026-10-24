import 'dart:io';

import 'package:equatable/equatable.dart';

import '../../core/transcript.dart';
import '../../core/whisper.dart';
import '../../platform/os.dart';

/// Одна запись в очереди: файл, его состояние и то, что из него вышло.
///
/// Неизменяемая: Bloc решает, перерисовывать ли, сравнением состояний,
/// а правка на месте такому сравнению невидима — очередь молча замирала бы
/// на устаревшем виде. Каждая перемена делает новую запись через [copyWith].
class Job extends Equatable {
  const Job(
    this.file, {
    this.imported = false,
    this.state = JobState.queued,
    this.detail,
    this.error,
    this.progress = 0,
    this.live = const [],
    this.transcript,
    this.raw,
    this.overrides,
    this.besideSource,
    this.startedAt,
    this.took,
    this.resumeFrom = 0,
  });

  final File file;

  /// Расшифровку открыли из файла — распознавать в ней нечего.
  final bool imported;

  final JobState state;

  /// Уточнение к состоянию: «Русский · 42 фрагмента». Пусто — показываем
  /// само состояние.
  final String? detail;

  /// Что движок сказал перед тем, как не справиться, — целиком.
  ///
  /// Отдельно от [detail]: в подпись под именем записи влезает начало
  /// одной строки, а понять по ней, почему движок не поднимается, нельзя
  /// ни человеку, ни тому, кому он эту строку перешлёт. Здесь лежит весь
  /// вывод: его показывают подсказкой, кладут в инспектор и отдают
  /// в буфер обмена одним пунктом меню.
  final String? error;

  final double progress;

  /// Фрагменты, которые модель уже выдала, пока идёт распознавание.
  ///
  /// Список заменяется целиком на каждый фрагмент: добавление в общий
  /// прошло бы мимо сравнения состояний. Цена невелика — фрагмент приходит
  /// раз в пару секунд, а не в каждом кадре. В сравнение при этом входит
  /// сам список (см. [props]): обычно он только растёт, и сравнение сразу
  /// замечает разную длину. Но голосовую замену можно отменить, переписав
  /// один фрагмент без смены числа строк, — такая правка тоже должна стать
  /// видна окну.
  final List<Segment> live;

  final Transcript? transcript;
  final String? raw;

  /// Свои настройки записи. null — берутся общие.
  final RunOptions? overrides;

  /// Куда легла копия текста рядом с исходной записью. Запоминается, чтобы
  /// повторное распознавание обновило свой же файл, а не наплодило
  /// «запись 2.txt», «запись 3.txt».
  final String? besideSource;

  final DateTime? startedAt;
  final Duration? took;

  /// С какой миллисекунды продолжать. Ноль — с начала. Ставится, когда
  /// распознавание остановили посреди: считанное остаётся в [live],
  /// а досчитывать незачем то, что уже посчитано.
  final int resumeFrom;

  String get path => file.path;
  String get name => os.basename(file.path);
  bool get active =>
      state == JobState.converting ||
      state == JobState.transcribing ||
      state == JobState.diarizing;

  /// Начатое и не досчитанное. Такое не бросают: его продолжают.
  bool get paused => state == JobState.paused;
  bool get done => transcript != null || raw != null;
  bool get isDone => done;
  List<Segment> get segments => transcript?.segments ?? live;

  /// Сколько ещё осталось, если считать, что дальше пойдёт с той же скоростью.
  ///
  /// Считается от текущего времени, поэтому в сравнение состояний не входит:
  /// иначе очередь перерисовывалась бы просто оттого, что время идёт.
  Duration? get eta {
    final started = startedAt;
    if (started == null || progress < 0.05) return null;
    final spent = DateTime.now().difference(started);
    return spent * ((1 - progress) / progress);
  }

  Job copyWith({
    JobState? state,
    String? detail,
    String? error,
    double? progress,
    List<Segment>? live,
    Transcript? transcript,
    String? raw,
    RunOptions? overrides,
    String? besideSource,
    DateTime? startedAt,
    Duration? took,
    int? resumeFrom,
    // Обнулять поля иначе нечем: `null` в именованном параметре
    // не отличить от «не передали».
    bool clearDetail = false,
    bool clearOverrides = false,
  }) => Job(
    file,
    imported: imported,
    state: state ?? this.state,
    detail: clearDetail ? null : (detail ?? this.detail),
    error: clearDetail ? null : (error ?? this.error),
    progress: progress ?? this.progress,
    live: live ?? this.live,
    transcript: transcript ?? this.transcript,
    raw: raw ?? this.raw,
    overrides: clearOverrides ? null : (overrides ?? this.overrides),
    besideSource: besideSource ?? this.besideSource,
    startedAt: startedAt ?? this.startedAt,
    took: took ?? this.took,
    resumeFrom: resumeFrom ?? this.resumeFrom,
  );

  /// Записать ещё один распознанный фрагмент.
  Job withSegment(Segment s) => copyWith(live: [...live, s]);

  Job replaceSegment(Segment old, Segment replacement) {
    List<Segment> replace(List<Segment> source) => [
      for (final segment in source)
        if (identical(segment, old)) replacement else segment,
    ];
    final ready = transcript;
    return ready == null
        ? copyWith(live: replace(live))
        : copyWith(transcript: ready.copyWith(segments: replace(ready.segments)));
  }

  /// Забыть результат и встать обратно в очередь — «распознать заново».
  Job get reset => Job(file, imported: imported, overrides: overrides);

  /// Файл — то, чем запись отличается от соседки: в очереди он уникален.
  /// Остальное входит в сравнение, чтобы перерисовка замечала перемены.
  @override
  List<Object?> get props => [
    file.path,
    imported,
    state,
    detail,
    error,
    progress,
    live,
    transcript,
    raw,
    overrides,
    besideSource,
    startedAt,
    took,
    resumeFrom,
  ];
}
