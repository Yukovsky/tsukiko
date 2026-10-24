/// Кто говорит: голоса, их реплики и сведение слов с разметкой диаризации.
///
/// Чистая логика без Flutter и без sherpa: файл собирается и в программу
/// расшифровки (`lib/cli/transcribe.dart`), и в приложение. Сама
/// диаризация — нейросеть и нативная библиотека — живёт отдельно
/// (`lib/core/diarization/`), сюда приходят только её ответы: отрезки
/// времени с номером кластера.
///
/// Схема везде одна и та же (WhisperX, MacParakeet, talkthrough-mcp):
/// текст распознаётся сам по себе, голоса размечаются сами по себе,
/// а потом обе разметки сводятся по времени — каждому слову достаётся
/// голос, который звучал дольше всех, пока это слово произносили.
library;

import 'dart:math' as math;

/// Один голос в записи.
///
/// [id] — стабильная метка («S1»), [name] — то, что видит человек.
/// Раздельно намеренно (так же у MacParakeet): переименование трогает
/// только список голосов, а фрагменты продолжают ссылаться на [id].
/// Иначе «Иван» пришлось бы переписывать в каждой реплике, а слияние
/// двух голосов с одинаковым именем стало бы неотличимо от совпадения.
class SpeakerInfo {
  const SpeakerInfo({
    required this.id,
    required this.name,
    this.talkMs = 0,
    this.turns = 0,
    this.firstMs = 0,
    this.lastMs = 0,
    this.colorIndex = 0,
  });

  final String id, name;

  /// Сколько этот голос говорил всего — сумма длительностей его реплик.
  final int talkMs;

  /// Сколько раз голос брал слово: подряд идущие фрагменты одного голоса
  /// считаются одной репликой.
  final int turns;
  final int firstMs, lastMs;

  /// Номер цвета в палитре. Хранится, а не считается по порядку: после
  /// слияния голосов у оставшихся цвета не должны перескакивать.
  final int colorIndex;

  SpeakerInfo copyWith({
    String? name,
    int? talkMs,
    int? turns,
    int? firstMs,
    int? lastMs,
    int? colorIndex,
  }) => SpeakerInfo(
    id: id,
    name: name ?? this.name,
    talkMs: talkMs ?? this.talkMs,
    turns: turns ?? this.turns,
    firstMs: firstMs ?? this.firstMs,
    lastMs: lastMs ?? this.lastMs,
    colorIndex: colorIndex ?? this.colorIndex,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'talkMs': talkMs,
    'turns': turns,
    'firstMs': firstMs,
    'lastMs': lastMs,
    'colorIndex': colorIndex,
  };

  static SpeakerInfo? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    int number(String key) => (value[key] as num?)?.toInt() ?? 0;
    return SpeakerInfo(
      id: id,
      name: (value['name'] as String?) ?? id,
      talkMs: number('talkMs'),
      turns: number('turns'),
      firstMs: number('firstMs'),
      lastMs: number('lastMs'),
      colorIndex: number('colorIndex'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeakerInfo &&
      other.id == id &&
      other.name == name &&
      other.talkMs == talkMs &&
      other.turns == turns &&
      other.firstMs == firstMs &&
      other.lastMs == lastMs &&
      other.colorIndex == colorIndex;

  @override
  int get hashCode =>
      Object.hash(id, name, talkMs, turns, firstMs, lastMs, colorIndex);

  @override
  String toString() => 'SpeakerInfo($id, $name, ${talkMs}ms)';
}

/// Чем получена разметка голосов — чтобы по готовому файлу было видно,
/// какой моделью и с каким порогом его размечали (так делает
/// talkthrough-mcp). Без этого через полгода не понять, почему в одной
/// расшифровке три голоса, а в соседней, той же встречи, — пять.
class DiarizationInfo {
  const DiarizationInfo({
    this.engine = 'sherpa-onnx',
    required this.segmentation,
    required this.embedding,
    required this.threshold,
    required this.requestedSpeakers,
    required this.detectedSpeakers,
  });

  final String engine, segmentation, embedding;
  final double threshold;

  /// Сколько голосов просили. Ноль — «определить самим».
  final int requestedSpeakers;
  final int detectedSpeakers;

  Map<String, Object> toJson() => {
    'engine': engine,
    'segmentation': segmentation,
    'embedding': embedding,
    'threshold': threshold,
    'requestedSpeakers': requestedSpeakers,
    'detectedSpeakers': detectedSpeakers,
  };

  static DiarizationInfo? fromJson(Object? value) {
    if (value is! Map) return null;
    return DiarizationInfo(
      engine: (value['engine'] as String?) ?? 'sherpa-onnx',
      segmentation: (value['segmentation'] as String?) ?? '',
      embedding: (value['embedding'] as String?) ?? '',
      threshold: (value['threshold'] as num?)?.toDouble() ?? 0,
      requestedSpeakers: (value['requestedSpeakers'] as num?)?.toInt() ?? 0,
      detectedSpeakers: (value['detectedSpeakers'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiarizationInfo &&
      other.engine == engine &&
      other.segmentation == segmentation &&
      other.embedding == embedding &&
      other.threshold == threshold &&
      other.requestedSpeakers == requestedSpeakers &&
      other.detectedSpeakers == detectedSpeakers;

  @override
  int get hashCode => Object.hash(
    engine,
    segmentation,
    embedding,
    threshold,
    requestedSpeakers,
    detectedSpeakers,
  );
}

/// Отрезок, на котором звучит один голос. Так отвечает диаризация.
///
/// Отрезки разных голосов могут заходить друг на друга: модель
/// сегментации pyannote 3.0 различает до двух одновременных голосов,
/// и перебивки она видит. Это не ошибка разметки, а её смысл.
class SpeakerTurn {
  const SpeakerTurn(this.fromMs, this.toMs, this.clusterId);

  final int fromMs, toMs;

  /// До [relabelTurns] — номер кластера, как его назвал движок («0», «3»),
  /// после — стабильная метка («S1»).
  final String clusterId;

  int get durationMs => math.max(0, toMs - fromMs);

  @override
  bool operator ==(Object other) =>
      other is SpeakerTurn &&
      other.fromMs == fromMs &&
      other.toMs == toMs &&
      other.clusterId == clusterId;

  @override
  int get hashCode => Object.hash(fromMs, toMs, clusterId);

  @override
  String toString() => 'SpeakerTurn($fromMs–$toMs, $clusterId)';
}

/// Переименовать кластеры в «S1», «S2»… по порядку первого появления.
///
/// Номера кластеров у движка случайны: одна и та же запись, посчитанная
/// дважды, может назвать первого говорящего то «0», то «2». Метки же
/// должны быть одними и теми же — иначе переименованный «Иван» после
/// повторной разметки оказался бы чужим голосом. Порядок первого
/// появления от номеров не зависит.
///
/// При одновременном начале первым считается тот, чей отрезок длиннее;
/// номер кластера — самая последняя ступень, только чтобы ответ был
/// однозначным.
List<SpeakerTurn> relabelTurns(List<SpeakerTurn> raw) {
  final sorted = [...raw]
    ..sort((a, b) {
      final byStart = a.fromMs.compareTo(b.fromMs);
      if (byStart != 0) return byStart;
      final byLength = b.durationMs.compareTo(a.durationMs);
      if (byLength != 0) return byLength;
      return a.clusterId.compareTo(b.clusterId);
    });
  final labels = <String, String>{};
  for (final turn in sorted) {
    labels.putIfAbsent(turn.clusterId, () => 'S${labels.length + 1}');
  }
  return [
    for (final turn in sorted)
      SpeakerTurn(turn.fromMs, turn.toMs, labels[turn.clusterId]!),
  ];
}

/// Слово с таймкодами — и голос, которому оно досталось.
class TimedWord {
  const TimedWord(
    this.from,
    this.to,
    this.text, {
    this.speaker,
    this.overlap = false,
  });

  final int from, to;
  final String text;

  /// null — ни один голос не звучал рядом с этим словом.
  final String? speaker;

  /// Пока звучало слово, говорили двое: перебивка.
  final bool overlap;

  int get durationMs => math.max(0, to - from);

  TimedWord withSpeaker(String? speaker, {bool? overlap}) => TimedWord(
    from,
    to,
    text,
    speaker: speaker,
    overlap: overlap ?? this.overlap,
  );

  @override
  bool operator ==(Object other) =>
      other is TimedWord &&
      other.from == from &&
      other.to == to &&
      other.text == text &&
      other.speaker == speaker &&
      other.overlap == overlap;

  @override
  int get hashCode => Object.hash(from, to, text, speaker, overlap);

  @override
  String toString() =>
      'TimedWord($from–$to, $text, $speaker${overlap ? ', ⇄' : ''})';
}

/// Насколько далеко можно искать голос для слова, рядом с которым не
/// звучал никто. Аналог `fill_nearest` из WhisperX: границы отрезков
/// диаризации и слов расходятся на десятки миллисекунд, и короткое слово
/// на стыке легко попадает в щель между ними. Дальше секунды — это уже
/// не щель, а слово, которого диаризация не услышала.
const nearestSpeakerMs = 1000;

/// Какая доля слова должна прозвучать одновременно с другим голосом,
/// чтобы считать его перебивкой. Стартовое значение: меньше — и в перебивки
/// попадают обычные стыки реплик, где один договаривает, а другой уже
/// вдохнул; больше — и пропускаются настоящие.
const overlapWordShare = 0.3;

/// Сколько миллисекунд внутри [from]–[to] звучат сразу два голоса и больше.
///
/// Считается именно одновременность, а не «у двух голосов есть доля
/// в слове»: на чистой передаче слова посреди него (один замолчал ровно
/// там, где начал другой) у обоих по половине слова, но перебивки нет.
int _together(List<SpeakerTurn> turns, int from, int to) {
  final edges = <(int, int)>[];
  for (final t in turns) {
    final f = math.max(from, t.fromMs);
    final e = math.min(to, t.toMs);
    if (e <= f) continue;
    edges
      ..add((f, 1))
      ..add((e, -1));
  }
  // Конец раньше начала в одной точке: стык — не нахлёст.
  edges.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
  var active = 0, last = from, total = 0;
  for (final (at, delta) in edges) {
    if (active >= 2) total += at - last;
    active += delta;
    last = at;
  }
  return total;
}

/// Раздать словам голоса по разметке диаризации.
///
/// Каждому слову — голос с наибольшим суммарным пересечением по времени;
/// ничья — тот, кто начал раньше (так у MacParakeet и talkthrough-mcp).
/// Пересечений нет — ближайший голос не дальше [nearestMs], иначе null:
/// такие слова потом присоединяются к соседям ([fillUnassigned]).
///
/// [turns] — уже после [relabelTurns], но порядок не важен.
List<TimedWord> assignSpeakers(
  List<TimedWord> words,
  List<SpeakerTurn> turns, {
  int nearestMs = nearestSpeakerMs,
  double overlapShare = overlapWordShare,
}) {
  if (turns.isEmpty) return [for (final w in words) w.withSpeaker(null)];
  final sorted = [...turns]..sort((a, b) => a.fromMs.compareTo(b.fromMs));
  final out = <TimedWord>[];
  for (final word in words) {
    // Слово нулевой длины — точка; пусть у неё будет хоть миллисекунда,
    // иначе пересечение с любым отрезком равно нулю.
    final from = word.from;
    final int to = math.max(word.to, word.from + 1);
    final length = to - from;
    final overlapBySpeaker = <String, int>{};
    final startBySpeaker = <String, int>{};
    for (final turn in sorted) {
      if (turn.fromMs >= to) break;
      final int shared = math.min(to, turn.toMs) - math.max(from, turn.fromMs);
      if (shared <= 0) continue;
      overlapBySpeaker.update(
        turn.clusterId,
        (v) => v + shared,
        ifAbsent: () => shared,
      );
      startBySpeaker.update(
        turn.clusterId,
        (v) => math.min(v, turn.fromMs),
        ifAbsent: () => turn.fromMs,
      );
    }

    if (overlapBySpeaker.isEmpty) {
      String? nearest;
      var best = nearestMs + 1;
      for (final turn in sorted) {
        final gap = turn.toMs <= from
            ? from - turn.toMs
            : turn.fromMs >= to
            ? turn.fromMs - to
            : 0;
        if (gap < best) {
          best = gap;
          nearest = turn.clusterId;
        }
      }
      out.add(word.withSpeaker(nearest, overlap: false));
      continue;
    }

    String? winner;
    for (final entry in overlapBySpeaker.entries) {
      if (winner == null) {
        winner = entry.key;
        continue;
      }
      final current = overlapBySpeaker[winner]!;
      if (entry.value > current ||
          (entry.value == current &&
              startBySpeaker[entry.key]! < startBySpeaker[winner]!)) {
        winner = entry.key;
      }
    }
    out.add(
      word.withSpeaker(
        winner,
        overlap:
            overlapBySpeaker.length >= 2 &&
            _together(sorted, from, to) >= length * overlapShare,
      ),
    );
  }
  return out;
}

/// Слова без голоса присоединить к соседям: к предыдущему, а в самом
/// начале записи — к первому следующему с голосом.
List<TimedWord> fillUnassigned(List<TimedWord> words) {
  String? firstKnown;
  for (final w in words) {
    if (w.speaker != null) {
      firstKnown = w.speaker;
      break;
    }
  }
  if (firstKnown == null) return words;
  var last = firstKnown;
  return [
    for (final w in words)
      if (w.speaker == null)
        w.withSpeaker(last)
      else
        w.withSpeaker(last = w.speaker!),
  ];
}

/// Включён ли фильтр одиночного слова (см. [smoothSingleWords]).
///
/// Этого правила в источниках нет — оно наше, поэтому вынесено флагом:
/// если на настоящих записях окажется, что оно съедает настоящие
/// короткие реплики, его можно выключить одной строкой.
const smoothSingleWordFlips = true;

/// Короче этого одиночное слово чужого голоса считается дрожанием границы.
const singleWordFlipMs = 300;

/// Убрать «мигание» A A **B** A A.
///
/// Границы отрезков диаризации не совпадают с границами слов, и короткое
/// слово на стыке нередко достаётся соседнему голосу, хотя вокруг него
/// говорит один и тот же человек. Такое слово — короче [maxMs], не
/// перебивка, и слева и справа от него один и тот же другой голос —
/// возвращается этому голосу. Настоящие короткие реплики («да») живут
/// в паузах и между репликами, а не посреди чужой фразы, поэтому их это
/// не задевает; поддакивания внутри чужой речи — отдельная задача
/// второго этапа.
List<TimedWord> smoothSingleWords(
  List<TimedWord> words, {
  int maxMs = singleWordFlipMs,
}) {
  if (!smoothSingleWordFlips || words.length < 3) return words;
  final out = [...words];
  for (var i = 1; i < words.length - 1; i++) {
    final word = words[i];
    final left = words[i - 1].speaker;
    final right = words[i + 1].speaker;
    if (word.overlap || word.durationMs >= maxMs) continue;
    if (left == null || left != right || left == word.speaker) continue;
    out[i] = word.withSpeaker(left);
  }
  return out;
}

/// Включено ли голосование по предложениям (см. [voteBySentences]).
/// Флагом — по той же причине, что и [smoothSingleWordFlips]: правило
/// наше, а не из источников.
const voteSentences = true;

/// Чужой голос внутри предложения остаётся, только если он держит
/// столько слов подряд и столько времени: это уже настоящая перебивка
/// посреди фразы, а не дрожание границы.
const sentenceMinorityWords = 4;
const sentenceMinorityMs = 1500;

/// Длиннее этого «предложение» — скорее текст без знаков препинания
/// (пунктуация выключена), и голосовать по нему нельзя: оно может
/// накрыть несколько реплик.
const sentenceVoteMaxWords = 25;

/// Отдать каждое предложение голосу, который держит большую часть его
/// времени.
///
/// Проверка на настоящем whisper.cpp 1.9.3 (записи реальных людей,
/// русская и английская) показала: пословная раздача режет смену голоса
/// на одно–три слова мимо — первое слово новой реплики прилипает к
/// концу прежней («…где теперь льды. **В**» / «Сарайке…»), а
/// предложение одного человека рассыпается на куски разных голосов.
/// Причина — неточное время: и потокенное время whisper, и границы его
/// фрагментов на стыке фраз уходят на доли секунды, а то и на секунду.
/// Люди же почти никогда не передают слово посреди предложения.
///
/// Поэтому голос выбирается на целое предложение — по сумме длительностей
/// слов. Исключение — ряд слов другого голоса не короче
/// [sentenceMinorityWords] слов и [sentenceMinorityMs]: это настоящая
/// перебивка, и она остаётся. Предложения длиннее [sentenceVoteMaxWords]
/// не трогаются.
///
/// Слова с отметкой перебивки голосуют наравне с остальными: в зоне, где
/// говорят двое, whisper записывает кого-то одного, и чьи это слова,
/// честнее всего скажет предложение, в которое они вошли («…стороны.» —
/// один человек, «На вопрос с кальцией…» — другой, начавший на 0,8 с
/// раньше). Сама отметка ⇄ при этом остаётся.
List<TimedWord> voteBySentences(List<TimedWord> words) {
  if (!voteSentences || words.length < 2) return words;
  final out = [...words];
  var start = 0;
  for (var i = 0; i < words.length; i++) {
    final last = i + 1 == words.length || _sentenceEnd.hasMatch(words[i].text);
    if (!last) continue;
    _vote(out, start, i + 1);
    start = i + 1;
  }
  return out;
}

void _vote(List<TimedWord> out, int from, int to) {
  if (to - from < 2 || to - from > sentenceVoteMaxWords) return;
  final time = <String, int>{};
  for (var i = from; i < to; i++) {
    final id = out[i].speaker;
    if (id == null) continue;
    time.update(id, (v) => v + math.max(1, out[i].durationMs),
        ifAbsent: () => math.max(1, out[i].durationMs));
  }
  if (time.length < 2) return;
  final major = time.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  var i = from;
  while (i < to) {
    final id = out[i].speaker;
    var j = i;
    while (j < to && out[j].speaker == id) {
      j++;
    }
    final run = j - i;
    final runMs = out[j - 1].to - out[i].from;
    final keep = id == major ||
        id == null ||
        (run >= sentenceMinorityWords && runMs >= sentenceMinorityMs);
    if (!keep) {
      for (var k = i; k < j; k++) {
        out[k] = out[k].withSpeaker(major);
      }
    }
    i = j;
  }
}

/// Вся дорога от слов с таймкодами до слов с голосами: раздать голоса,
/// присоединить ничьи слова, убрать одиночное мигание и проголосовать
/// по предложениям. Одна на whisper и NeMo, чтобы правила не разошлись.
List<TimedWord> speakerWords(List<TimedWord> words, List<SpeakerTurn> turns) =>
    voteBySentences(
      smoothSingleWords(fillUnassigned(assignSpeakers(words, turns))),
    );

/// Расставить слова фрагмента по времени.
///
/// [text] — окончательный текст фрагмента, [raw] — слова с таймкодами
/// от движка, если они есть. Совпало число слов — таймкоды берутся как
/// есть. Не совпало (словарь заменил «ии» на «ИИ», фильтр срезал
/// выдуманный хвост, а у части записи, досчитанной до паузы, слов нет
/// вовсе) — время раскладывается по доле символов: слово, стоящее на
/// середине текста, получает время середины звучания исходных слов.
/// Это вариант «A» из замысла: менее точно, но текст не трогаем.
List<TimedWord> timeWords(
  String text,
  int from,
  int to, [
  List<TimedWord> raw = const [],
]) {
  final spans = RegExp(r'\S+').allMatches(text).toList();
  if (spans.isEmpty) return const [];
  if (raw.length == spans.length) {
    return [
      for (var i = 0; i < spans.length; i++)
        TimedWord(raw[i].from, raw[i].to, spans[i].group(0)!),
    ];
  }

  // Опорные точки «доля символов → миллисекунда». Без слов от движка их
  // две — начало и конец фрагмента.
  final anchors = <(double, int)>[];
  if (raw.isEmpty) {
    anchors.addAll([(0, from), (1, math.max(from, to))]);
  } else {
    final total = raw.fold<int>(0, (sum, w) => sum + w.text.length + 1);
    var at = 0;
    for (final w in raw) {
      anchors.add((at / total, w.from));
      at += w.text.length + 1;
      anchors.add(((at - 1) / total, w.to));
    }
  }
  int timeAt(double share) {
    if (share <= anchors.first.$1) return anchors.first.$2;
    for (var i = 1; i < anchors.length; i++) {
      final (s1, t1) = anchors[i];
      if (share <= s1) {
        final (s0, t0) = anchors[i - 1];
        if (s1 <= s0) return t1;
        return (t0 + (t1 - t0) * (share - s0) / (s1 - s0)).round();
      }
    }
    return anchors.last.$2;
  }

  final length = math.max(1, text.length);
  return [
    for (final span in spans)
      TimedWord(
        timeAt(span.start / length),
        timeAt(span.end / length),
        span.group(0)!,
      ),
  ];
}

/// Фрагмент, как его видит группировка: время, текст, голос, перебивка.
/// Отдельный тип, а не `Segment`: этот файл не знает про замены словаря
/// и прочее, что несёт фрагмент расшифровки.
class WordGroup {
  const WordGroup(
    this.from,
    this.to,
    this.text, {
    this.speaker,
    this.overlap = false,
  });

  final int from, to;
  final String text;
  final String? speaker;
  final bool overlap;

  @override
  String toString() => 'WordGroup($from–$to, $text, $speaker)';
}

final _sentenceEnd = RegExp(r'[.!?…][\"»”’)]*$');

/// Сколько первых слов фрагмента смотреть, решая, перебивка ли он.
const _interruptLeadWords = 2;

/// Собрать слова во фрагменты по естественным границам: конец
/// предложения, пауза не короче [gapMs], строка длиннее [maxChars]
/// или [maxMs] — и, если голоса расставлены, смена голоса.
///
/// Это та самая группировка, которая раньше жила внутри разбора NeMo,
/// вынесенная наружу, чтобы голоса получали обе дороги: и NeMo, и
/// whisper. Без голосов результат совпадает с прежним символ в символ
/// (проверяется в `test/core/engine_test.dart`).
List<WordGroup> groupWords(
  List<TimedWord> words, {
  int gapMs = 700,
  int maxChars = 90,
  int maxMs = 12000,
}) {
  final groups = <WordGroup>[];
  var start = 0;
  var chars = 0;
  for (var i = 0; i < words.length; i++) {
    final current = words[i];
    final next = i + 1 < words.length ? words[i + 1] : null;
    chars += current.text.length + 1;
    final sentenceEnd = _sentenceEnd.hasMatch(current.text);
    final pause = next != null && next.from - current.to >= gapMs;
    final tooLong =
        chars >= maxChars || current.to - words[start].from >= maxMs;
    final turn = next != null && next.speaker != current.speaker;
    if (next == null || sentenceEnd || pause || tooLong || turn) {
      final part = words.sublist(start, i + 1);
      groups.add(
        WordGroup(
          words[start].from,
          current.to,
          part.map((word) => word.text).join(' ').trim(),
          speaker: current.speaker,
          overlap: part.take(_interruptLeadWords).any((w) => w.overlap),
        ),
      );
      start = i + 1;
      chars = 0;
    }
  }
  return groups;
}

/// Насколько раньше конца чужой реплики должна начаться своя, чтобы
/// считаться перебивкой, даже если слова сами её не показали.
const interruptLeadMs = 200;

/// Отметить фрагменты, начавшиеся поверх чужой реплики.
///
/// [overlaps] — уже известные отметки (по словам), [speakers] и время —
/// по фрагментам. Возвращает новые отметки той же длины.
List<bool> markInterruptions(
  List<({int from, int to, String? speaker, bool overlap})> segments, {
  int leadMs = interruptLeadMs,
}) {
  final out = <bool>[];
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    var interrupt = s.overlap;
    if (!interrupt && s.speaker != null) {
      // Ближайший предыдущий фрагмент другого голоса.
      for (var j = i - 1; j >= 0; j--) {
        final before = segments[j];
        if (before.speaker == null || before.speaker == s.speaker) continue;
        interrupt = before.to - s.from >= leadMs;
        break;
      }
    }
    out.add(interrupt);
  }
  return out;
}

/// Голос по умолчанию, пока его не переименовали: «Голос 1». Приложение
/// подставляет переведённое имя; программе расшифровки переводов взять
/// неоткуда, и ей достаётся это.
String defaultSpeakerName(int number) => 'Голос $number';

/// Номер голоса из метки: «S3» → 3. Чужая метка — 0.
int speakerNumber(String id) =>
    id.startsWith('S') ? int.tryParse(id.substring(1)) ?? 0 : 0;

/// Список голосов со статистикой по готовым фрагментам.
///
/// [segments] — пары «голос, время» в порядке записи. [previous] —
/// прежний список: имена и цвета голосов, которые в нём были, остаются
/// за ними (после слияния и переназначения статистика меняется, а имя
/// «Иван» — нет). Новые голоса получают имя от [defaultName] и следующий
/// свободный цвет. Голос, у которого не осталось ни одного фрагмента,
/// из списка уходит.
List<SpeakerInfo> speakerRoster(
  List<({int from, int to, String? speaker})> segments, {
  List<SpeakerInfo> previous = const [],
  String Function(int number) defaultName = defaultSpeakerName,
}) {
  final known = {for (final s in previous) s.id: s};
  final talk = <String, int>{};
  final turns = <String, int>{};
  final first = <String, int>{};
  final last = <String, int>{};
  final order = <String>[];
  String? before;
  for (final s in segments) {
    final id = s.speaker;
    if (id == null) {
      before = null;
      continue;
    }
    if (!talk.containsKey(id)) order.add(id);
    talk.update(
      id,
      (v) => v + math.max(0, s.to - s.from),
      ifAbsent: () => math.max(0, s.to - s.from),
    );
    if (before != id) turns.update(id, (v) => v + 1, ifAbsent: () => 1);
    first.update(id, (v) => math.min(v, s.from), ifAbsent: () => s.from);
    last.update(id, (v) => math.max(v, s.to), ifAbsent: () => s.to);
    before = id;
  }

  final usedColors = {
    for (final id in order)
      if (known[id] != null) known[id]!.colorIndex,
  };
  var nextColor = 0;
  int freshColor() {
    while (usedColors.contains(nextColor)) {
      nextColor++;
    }
    usedColors.add(nextColor);
    return nextColor;
  }

  // Порядок списка — по номеру метки, а не по первому появлению после
  // правок: «Голос 2» не должен прыгать наверх оттого, что первый
  // фрагмент записи переназначили ему.
  order.sort((a, b) {
    final byNumber = speakerNumber(a).compareTo(speakerNumber(b));
    return byNumber != 0 ? byNumber : a.compareTo(b);
  });
  return [
    for (final id in order)
      SpeakerInfo(
        id: id,
        name: known[id]?.name ?? defaultName(speakerNumber(id)),
        talkMs: talk[id]!,
        turns: turns[id]!,
        firstMs: first[id]!,
        lastMs: last[id]!,
        colorIndex: known[id]?.colorIndex ?? freshColor(),
      ),
  ];
}

/// Похоже ли, что голоса рассыпались на «осколки».
///
/// Порог кластеризации у каждого эмбеддера свой и зависит от записи:
/// промах в нём превращает четырёх человек в десятки «голосов» по
/// несколько секунд (замер YazSes: 86 голосов вместо 4 на пороге из
/// примера sherpa). Признак — не меньше половины меток держат речи
/// меньше `min(20 с, max(5 с, 2 % всей речи))`.
///
/// Только предупреждение: ничего не сливает и не прячет. И ловит оно
/// только осколки — ошибку «один человек разбит на два крупных голоса»
/// оно не видит, поэтому обещать по нему «разметка верна» нельзя.
///
/// Двух голосов для осколков мало: «один говорил, второй разок
/// ответил» — обычный разговор, а не рассыпавшаяся разметка.
bool looksFragmented(List<SpeakerInfo> roster) {
  if (roster.length < 3) return false;
  final total = roster.fold<int>(0, (sum, s) => sum + s.talkMs);
  final limit = math.min(20000, math.max(5000, total * 0.02));
  final small = roster.where((s) => s.talkMs < limit).length;
  return small * 2 >= roster.length;
}
