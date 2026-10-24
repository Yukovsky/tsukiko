import 'dart:convert';

import 'languages.dart';
import 'speakers.dart';
import 'text_commands.dart';
import 'vocabulary.dart';

export 'speakers.dart';

/// Что whisper сочиняет на тишине.
///
/// Модель обучена в том числе на субтитрах, и в тишине она договаривает
/// то, чем субтитры кончаются: «Продолжение следует…», «Субтитры сделал…»,
/// «Спасибо за просмотр». Сказано этого не было, и в тексте этому не место.
///
/// Список намеренно узкий, и совпадение — только по целому куску: если
/// человек действительно произнёс «продолжение следует» в середине фразы,
/// фраза останется как есть. Выбрасывается лишь то, что целиком совпало
/// с известной выдумкой.
const _silenceHallucinations = {
  // Continuation & endings
  'продолжение следует',
  'to be continued',
  'конец фильма',
  'конец серии',
  'конец связи',
  'the end',

  // Subtitle credits & ripper tags
  'субтитры сделал dimatorzok',
  'субтитры делал dimatorzok',
  'субтитры dimatorzok',
  'dimatorzok',
  'редактор субтитров асинецкая корректор аегорова',
  'редактор субтитров а синецкая корректор а егорова',
  'редактор субтитров',
  'автор субтитров',
  'русские субтитры',
  'subtitles by',
  'translated by',

  // Outros & channel plugs
  'спасибо за просмотр',
  'спасибо за внимание',
  'подписывайтесь на канал',
  'не забудьте подписаться',
  'ставьте лайки',
  'ставьте лайк',
  'thanks for watching',
  'thank you for watching',
  'subscribe to my channel',
  'please subscribe',
  'like and subscribe',
};

final _outerDecorations = RegExp(
  r'''^[\s"«»“”„'\[\]\(\)\{\}\*\-—–#]+|[\s"«»“”„'\[\]\(\)\{\}\*\-—–#]+$''',
);

final _standaloneCreditRegex = RegExp(
  r'^(?:'
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^.!?…\n]*|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[а-яёa-z0-9_\-]+[^.!?…\n]*|'
  r'(?:субтитры\s*[:\-—–]?\s*)?dima\s*torzok|'
  r'русские\s+субтитры(?:\s*[:\-—–]\s*.+|\s+(?:от|для)\s+.+|\s*)|'
  r'автор\s+субтитров(?:\s*[:\-—–]\s*.+|\s+[а-яёa-z]\s*\..*|\s+(?:от|для)\s+.+|\s*)|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор|\s*$).*|'
  r'корректор\s+[а-яёa-z]\s*\..*|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?:\s*[:\-—–]\s*.+|\s+(?:от|для)\s+.+|\s*)|'
  r'subtitles\s+(?:by|created\s+by|made\s+by)(?:\s+[^.!?…\n]+)?|'
  r'translated\s+by(?:\s+[^.!?…\n]+)?|'
  r'translation\s+by(?:\s+[^.!?…\n]+)?'
  r')$',
  caseSensitive: false,
);

final _standaloneEndingRegex = RegExp(
  r'^(?:продолжение\s+следует|to\s+be\s+continued|конец\s+фильма|конец\s+серии|конец\s+связи|the\s+end)$',
  caseSensitive: false,
);

final _standaloneOutroRegex = RegExp(
  r'^(?:'
  r'(?:большое\s+)?спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр(?:\s+(?:этого\s+видео|этого\s+ролика|видео|ролика|друзья|ставьте|подписывайтесь|не\s+забудьте).*)?|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s+(?:и|жмит[её]|ставь).*|\s*$)|'
  r'не\s+забудьте\s+подписаться(?:\s+(?:на\s+канал|и|постави).*|\s*$)|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s+(?:и|подписыва).*|\s*$)|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s+(?:this\s+video|guys|everyone|and|please).*|\s*$)|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel(?:\s+.*)?|'
  r'(?:please\s+)?like\s+and\s+subscribe(?:\s+.*)?|'
  r'please\s+subscribe(?:\s+.*)?|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe(?:\s+.*)?"""
  r')$',
  caseSensitive: false,
);

final _trailingHallucinationPattern = RegExp(
  r'(?:(?<=[.!?…])\s*|(?:\s*[,;\-—–:]\s*|\s+))'
  r'(?:'
  // 1. Subtitle credits (longer credit phrases first, cannot span across sentences)
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[^.!?…\n]+[.!?…\s]*|'
  r'(?:(?:субтитры|subtitles|автор|перевод|by|от)\s*[:\-—–]?\s*)?dima\s*torzok\b[^.!?…\n]*[.!?…\s]*|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор|\s*$).*?|'
  r'(?:редактор\s+субтитров.*?)?корректор\s+[а-яёa-z]\s*\..*?|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'автор\s+субтитров(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'русские\s+субтитры(?![а-яёА-ЯЁ])[^.!?…\n]*[.!?…\s]*|'
  r'subtitles\s+by\b[^.!?…\n]*[.!?…\s]*|'
  r'translated\s+by\b[^.!?…\n]*[.!?…\s]*|'
  r'translation\s+by\b[^.!?…\n]*[.!?…\s]*|'
  // 2. Continuation & endings
  r'продолжение\s+следует[.!?…\s]*|'
  r'to\s+be\s+continued[.!?…\s]*|'
  r'конец\s+фильма[.!?…\s]*|'
  r'конец\s+серии[.!?…\s]*|'
  r'конец\s+связи[.!?…\s]*|'
  r'the\s+end[.!?…\s]*|'
  // 3. Outros & channel plugs
  r'спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр(?:\s*[,–—\-]?\s*(?:этого\s+видео|этого\s+ролика|видео|ролика|друзья|ставьте\s+лайки|подписывайтесь))?[.!?…\s]*|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание[.!?…\s]*|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s*[,–—\-]?\s*(?:и\s+жмите\s+колокольчик|и\s+ставьте\s+лайки|ставьте\s+лайки|ставьте\s+лайк))?[.!?…\s]*|'
  r'не\s+забудьте\s+подписаться(?:\s+на\s+(?:наш\s+)?канал)?(?:\s*[,–—\-]?\s*(?:и\s+поставить\s+лайк|и\s+поставьте\s+лайк))?[.!?…\s]*|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s*[,–—\-]?\s*(?:и\s+подписывайтесь|и\s+подпишитесь))?[.!?…\s]*|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s+(?:this\s+video|guys|everyone))?[.!?…\s]*|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel[.!?…\s]*|'
  r'(?:please\s+)?like\s+and\s+subscribe[.!?…\s]*|'
  r'please\s+subscribe[.!?…\s]*|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe[.!?…\s]*"""
  r')\s*$',
  caseSensitive: false,
);

final _leadingHallucinationPattern = RegExp(
  r'^\s*(?:'
  // 1. Subtitle credits
  r'субтитры\s*(?:[:\-—–]\s*)?(?:сделал|делал|добавил|подготовил|перев[её]л|писал|создал|оформил)[аи]?(?![а-яёА-ЯЁ])[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'субтитры\s*(?:[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]+?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'(?:(?:субтитры|subtitles|автор|перевод|by|от)\s*[:\-—–]?\s*)?dima\s*torzok\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'редактор\s+субтитров(?:\s*[:\-—–]|\s+[а-яёa-z]\s*\.|\s+корректор)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'перевод\s+(?:и\s+субтитры|на\s+русский(?:\s+язык)?|текста|и\s+озвучк[аеиу])(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'автор\s+субтитров(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+[а-яёa-z]\s*\.|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'русские\s+субтитры(?![а-яёА-ЯЁ])(?:\s*[:\-—–]\s*|\s+(?:от|для)\s+)[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'subtitles\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'translated\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  r'translation\s+by\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*|\s+(?=[А-ЯЁA-Z]))|'
  // 2. Continuation & endings
  r'(?:продолжение\s+следует|to\s+be\s+continued|конец\s+фильма|конец\s+серии|конец\s+связи|the\s+end)(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  // 3. Outros & channel plugs
  r'спасибо(?:\s+всем|\s+большое)?\s+за\s+просмотр\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:большое\s+)?спасибо(?:\s+большое)?\s+за\s+внимание(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:подписывайтесь|подпишитесь)\s+на\s+(?:наш\s+)?канал(?:\s*(?:[,.!?…\-]|и\s+.*)|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'не\s+забудьте\s+подписаться(?:\s*[,.!?…\-]|\s+на\s+канал|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:ставьте|не\s+забудьте\s+поставить)\s+лайк[иа]?(?:\s*[,.!?…\-]|и\s+.*|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:thanks|thank\s+you)(?:\s+so\s+much)?\s+for\s+watching(?:\s*[,.!?…\-]|\s+(?:this\s+video|guys|everyone|and|please)|\s*$).*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:please\s+)?subscribe\s+to\s+(?:my|our|the)\s+channel\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'(?:please\s+)?like\s+and\s+subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r'please\s+subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)|'
  r"""don(?:'|\s+)?t\s+forget\s+to\s+(?:like\s+and\s+)?subscribe\b[^\n]*?(?:[.!?…]+[\s\n]*|[,;\-—–:]+[\s\n]*|\n+[\s]*)"""
  r')',
  caseSensitive: false,
);

/// Похоже ли это на выдумку модели, а не на сказанное вслух.
bool looksLikeSilenceHallucination(String text) {
  var s = text.trim();
  if (s.isEmpty) return false;

  // Убираем внешние кавычки, скобки, тире, звёздочки
  s = s.replaceAll(_outerDecorations, '').trim();
  if (s.isEmpty) return false;

  // Если текст состоит из нескольких предложений:
  // он является чистой галлюцинацией ТОЛЬКО если каждое предложение — галлюцинация.
  if (s.contains(RegExp(r'(?<=[a-zа-яё0-9]{2,}[.!?…])\s+(?=[А-ЯЁA-Z])|\n+'))) {
    final sentences = s
        .split(RegExp(r'(?<=[a-zа-яё0-9]{2,}[.!?…])\s+(?=[А-ЯЁA-Z])|\n+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (sentences.length > 1) {
      return sentences.every(looksLikeSilenceHallucination);
    }
  }

  final bare = s
      .toLowerCase()
      .replaceAll(RegExp(r'''[!?.…,"«»“”„'\[\]\(\)\{\}\*\:;\-—–/\\_#]'''), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (bare.isEmpty) return false;

  // 1. Точное совпадение со списком
  if (_silenceHallucinations.contains(bare)) return true;

  // 2. Титры и авторство (проверяем и по s с пунктуацией, и по bare)
  if (_standaloneCreditRegex.hasMatch(s) || _standaloneCreditRegex.hasMatch(bare)) {
    return true;
  }

  // 3. Заставки окончания (строго по границам)
  if (_standaloneEndingRegex.hasMatch(bare)) return true;

  // 4. Концовки и подписки блогеров
  if (_standaloneOutroRegex.hasMatch(bare) || _standaloneOutroRegex.hasMatch(s)) {
    return true;
  }

  return false;
}

/// Удалить галлюцинации модели (титры, концовки видео, подписки),
/// прилипшие в начале или в конце сказанного пользователем.
///
/// Если весь текст состоит только из галлюцинации, возвращается пустая строка.
/// Осмысленная речь («продолжение следует ожидать осенью») не трогается.
String stripSilenceHallucinations(String text) {
  var s = text.trim();
  if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s)) return '';

  // 1. Повторно срезаем галлюцинации в хвосте
  while (true) {
    final m = _trailingHallucinationPattern.firstMatch(s);
    if (m == null) break;
    s = s.substring(0, m.start).trim();
    if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  }

  // 2. Повторно срезаем галлюцинации в начале
  while (true) {
    final m = _leadingHallucinationPattern.firstMatch(s);
    if (m == null) break;
    s = s.substring(m.end).trim();
    if (s.isEmpty || looksLikeSilenceHallucination(s)) return '';
  }

  // 3. Проверяем предложения внутри текста: если одно из них — чистая галлюцинация
  if (s.contains(RegExp(r'[.!?…]\s+[А-ЯЁA-Z]'))) {
    final parts = s.split(RegExp(r'(?<=[.!?…])\s+(?=[А-ЯЁA-Z])'));
    if (parts.length > 1) {
      final filtered = parts
          .where((p) => !looksLikeSilenceHallucination(p.trim()))
          .toList();
      if (filtered.isNotEmpty && filtered.length < parts.length) {
        s = filtered.join(' ');
      }
    }
  }

  // 4. Очищаем висящие запятые, тире, двоеточия на конце
  s = s.replaceFirst(RegExp(r'[,;:\-—–\s]+$'), '').trim();

  if (s.isEmpty || looksLikeSilenceHallucination(s) || !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(s)) return '';
  return s;
}

/// Расшифровка как данные: сегменты, разбор чужих форматов и обратная
/// сборка в наши.

class Segment {
  final int from, to;
  final String text;
  final List<TextReplacement> replacements;

  /// Чей голос — метка из списка голосов расшифровки («S1»). null —
  /// голоса не размечали, или разметка нашла только один.
  final String? speaker;

  /// Фрагмент начался поверх чужой реплики. Whisper слышит одну дорожку
  /// и два голоса сразу не разделит: слова в зоне перебивки достанутся
  /// кому-то одному. Отметка — честное признание этого, а не прятки.
  final bool overlap;

  const Segment(
    this.from,
    this.to,
    this.text, {
    this.replacements = const [],
    this.speaker,
    this.overlap = false,
  });

  /// Тот же фрагмент с другим текстом. Через него идут все пересборки:
  /// голос и отметка перебивки — свойства звучания, а не текста, и
  /// правка слов не должна их терять. Потеря здесь — самый вероятный
  /// способ молча стереть разметку голосов, поэтому путь один.
  Segment withText(String text, List<TextReplacement> replacements) => Segment(
    from,
    to,
    text,
    replacements: replacements,
    speaker: speaker,
    overlap: overlap,
  );

  /// Отдать фрагмент другому голосу. null — снять голос.
  Segment withSpeaker(String? speaker, {bool? overlap}) => Segment(
    from,
    to,
    text,
    replacements: replacements,
    speaker: speaker,
    overlap: overlap ?? this.overlap,
  );

  Segment applyCommands(Iterable<TextCommand> commands) {
    final result = applyTextCommands(text, commands);
    return withText(result.text, result.replacements);
  }

  Segment applyVocabulary(Iterable<VocabularyItem> items) {
    final result = applyVocabularyReplacements(text, items);
    return withText(result.text, result.replacements);
  }

  Segment undoReplacement(int index) {
    final result = undoTextReplacement(CommandText(text, replacements), index);
    return withText(result.text, result.replacements);
  }
}

class Transcript {
  final String lang;
  final List<Segment> segments;

  /// Голоса записи. Пусто — голоса не размечали (или нашёлся один):
  /// тогда ни на экране, ни в файлах подписей нет.
  final List<SpeakerInfo> speakers;

  /// Чем размечены голоса. Пишется в JSON, чтобы по файлу было видно,
  /// как он получен.
  final DiarizationInfo? diarization;

  const Transcript(
    this.lang,
    this.segments, {
    this.speakers = const [],
    this.diarization,
  });

  /// Подписывать ли реплики. Один голос — это «как без режима»: подпись
  /// «Голос 1» у каждой строки только мешала бы читать.
  bool get hasSpeakers => speakers.length > 1;

  Transcript copyWith({
    List<Segment>? segments,
    List<SpeakerInfo>? speakers,
    DiarizationInfo? diarization,
    bool clearSpeakers = false,
  }) => Transcript(
    lang,
    segments ?? this.segments,
    speakers: clearSpeakers ? const [] : (speakers ?? this.speakers),
    diarization: clearSpeakers ? null : (diarization ?? this.diarization),
  );

  /// Имя голоса для подписи. Неизвестная метка — сама метка: лучше
  /// «S7», чем молча потерянная подпись.
  String speakerName(String id) =>
      speakers.where((s) => s.id == id).firstOrNull?.name ?? id;

  Transcript applyVocabulary(Iterable<VocabularyItem> items) {
    final matcher = VocabularyMatcher(items);
    return copyWith(
      segments: segments.map((s) {
        final result = matcher.apply(s.text);
        return s.withText(result.text, result.replacements);
      }).toList(),
    );
  }
}

final _segmentLine = RegExp(
  r'^\[(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)\]\s*(.*)$',
);

/// whisper-cli печатает готовые сегменты по ходу работы — ловим их сразу,
/// чтобы текст появлялся во время распознавания, а не только в конце.
Segment? parseSegmentLine(String line) {
  final m = _segmentLine.firstMatch(line.trim());
  if (m == null) return null;
  int at(int i) => int.parse(m.group(i)!);
  final from = at(1) * 3600000 + at(2) * 60000 + at(3) * 1000 + at(4);
  final to = at(5) * 3600000 + at(6) * 60000 + at(7) * 1000 + at(8);
  final rawText = m.group(9)!.trim();
  if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) return null;
  final text = stripSilenceHallucinations(rawText).trim();
  return (text.isEmpty || looksLikeSilenceHallucination(text))
      ? null
      : Segment(from, to, text);
}

final _cue = RegExp(
  r'(\d+):(\d{2}):(\d{2})[.,](\d{3})\s*(?:-->|→)\s*(\d+):(\d{2}):(\d{2})[.,](\d{3})',
);

/// SRT, VTT и наш собственный «текст с таймкодами» — один разбор на всех:
/// у всех трёх пара времён в строке, а текст идёт следом. Разобранная
/// расшифровка ведёт себя как распознанная — её можно пересохранить
/// в любой другой формат.
Transcript? parseSubtitles(String text) {
  final lines = const LineSplitter().convert(text.replaceAll('\r\n', '\n'));
  final segs = <Segment>[];
  for (var i = 0; i < lines.length; i++) {
    final m = _cue.firstMatch(lines[i]);
    if (m == null) continue;
    int at(int g) => int.parse(m.group(g)!);
    final from = at(1) * 3600000 + at(2) * 60000 + at(3) * 1000 + at(4);
    final to = at(5) * 3600000 + at(6) * 60000 + at(7) * 1000 + at(8);

    // Текст либо идёт после метки в той же строке («[00:00 → 00:01]  раз»),
    // либо со следующей и до пустой строки — как в SRT.
    final buf = <String>[];
    final tail = lines[i]
        .substring(m.end)
        .replaceFirst(RegExp(r'^\s*\]?\s*'), '');
    if (tail.trim().isNotEmpty) {
      buf.add(tail.trim());
    } else {
      var j = i + 1;
      while (j < lines.length &&
          lines[j].trim().isNotEmpty &&
          !_cue.hasMatch(lines[j])) {
        buf.add(lines[j].trim());
        j++;
      }
      i = j - 1;
    }
    final body = buf.join(' ').trim();
    if (body.isNotEmpty) segs.add(Segment(from, to, body));
  }
  return segs.isEmpty ? null : Transcript('?', segs);
}

/// Сколько одинаковых подряд — уже не речь.
///
/// Два одинаковых предложения человек говорит («Да. Да.»), три и больше
/// секунда в секунду — нет. Такой хвост оставляет сорвавшееся окно:
/// перенос текста между окнами уже отключён (см. `noLoopArgs`), но внутри
/// одного окна модель всё ещё способна повторяться, и это её след.
const _loopRun = 3;

/// Свернуть подряд идущие повторы в один сегмент на всё их время.
/// Сказанное один раз так и остаётся сказанным один раз.
///
/// Повтор — это одинаковый текст **одним голосом**. «Да. Да. Да.» от
/// троих разных людей — не зацикливание модели, а три ответа, и
/// схлопывать их в один значило бы стереть двоих.
List<Segment> collapseRepeats(List<Segment> segs) {
  final out = <Segment>[];
  var i = 0;
  while (i < segs.length) {
    var j = i + 1;
    while (j < segs.length &&
        segs[j].text == segs[i].text &&
        segs[j].speaker == segs[i].speaker) {
      j++;
    }
    final run = j - i;
    out.add(
      run >= _loopRun
          ? Segment(
              segs[i].from,
              segs[j - 1].to,
              segs[i].text,
              speaker: segs[i].speaker,
              overlap: segs[i].overlap,
            )
          : segs[i],
    );
    i = run >= _loopRun ? j : i + 1;
  }
  return out;
}

/// Разобрать содержимое файла расшифровки.
///
/// Одна дорога на всех, кто открывает готовый текст: очередь по
/// «Открыть расшифровку…» и обзор прошлых расшифровок. Разбираются JSON,
/// субтитры и наш «текст с таймкодами» — такую расшифровку можно
/// пересохранить в любой другой формат. Не разобралось — значит это
/// просто текст, и он отдаётся как есть: показать его всё равно можно,
/// а сочинять из него фрагменты нельзя.
({Transcript? parsed, String? raw}) readTranscript(String path, String text) {
  if (path.toLowerCase().endsWith('.json')) {
    try {
      return (parsed: parseTranscriptJson(text), raw: null);
    } catch (_) {
      return (parsed: null, raw: text);
    }
  }
  final parsed = parseSubtitles(text);
  return parsed == null
      ? (parsed: null, raw: text)
      : (parsed: parsed, raw: null);
}

/// JSON любого из двух видов: сырой ответ whisper-cli или наш
/// собственный экспорт ([renderJson]). Свой узнаётся по списку
/// `segments` без `transcription`: только в нём живут голоса, и
/// открытая обратно расшифровка должна вернуть их все — с именами.
Transcript parseTranscriptJson(String jsonText) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  if (data['transcription'] == null && data['segments'] is List) {
    return _parseOwnJson(data);
  }
  return parseWhisperJson(jsonText);
}

Transcript _parseOwnJson(Map<String, dynamic> data) {
  final segs = <Segment>[
    for (final raw in (data['segments'] as List).whereType<Map>())
      if (raw['text'] is String)
        Segment(
          (raw['from'] as num?)?.toInt() ?? 0,
          (raw['to'] as num?)?.toInt() ?? 0,
          raw['text'] as String,
          speaker: raw['speaker'] as String?,
          overlap: raw['overlap'] == true,
        ),
  ];
  final speakers = [
    for (final raw in (data['speakers'] as List? ?? const []))
      ?SpeakerInfo.fromJson(raw),
  ];
  return Transcript(
    (data['language'] ?? '?').toString(),
    segs,
    speakers: speakers,
    diarization: DiarizationInfo.fromJson(data['diarization']),
  );
}

/// Служебные токены whisper в полном JSON: «[_BEG_]», «[_TT_150]».
final _specialToken = RegExp(r'^\[_[A-Z]+_?\d*\]$|^<\|.*\|>$');

/// Слова из потокенных таймкодов полного JSON whisper-cli (`-ojf`).
///
/// Токен — кусок слова, а не слово: новое слово начинается с токена,
/// у которого впереди пробел. Время слова — от начала первого его токена
/// до конца последнего. Служебные токены и токены без времени
/// пропускаются (время слова тогда берётся у его соседей по токенам).
List<TimedWord> whisperTokenWords(Object? tokens) {
  if (tokens is! List) return const [];
  final words = <TimedWord>[];
  var text = StringBuffer();
  int? from, to;
  void flush() {
    final word = text.toString().trim();
    if (word.isNotEmpty && from != null && to != null) {
      words.add(TimedWord(from!, to!, word));
    }
    text = StringBuffer();
    from = null;
    to = null;
  }

  for (final token in tokens.whereType<Map>()) {
    final piece = token['text'];
    if (piece is! String || _specialToken.hasMatch(piece.trim())) continue;
    if (piece.startsWith(' ')) flush();
    text.write(piece);
    final offsets = token['offsets'];
    if (offsets is Map) {
      final f = (offsets['from'] as num?)?.toInt();
      final t = (offsets['to'] as num?)?.toInt();
      if (f != null && f >= 0) from ??= f;
      if (t != null && t >= 0) to = t;
    }
  }
  flush();
  return words;
}

/// Разрезать фрагмент по смене голоса.
///
/// Голоса раздаются словам ([assignSpeakers]), а резать приходится
/// текст: кусок берётся из исходной строки по границам слов, а не
/// склеивается заново, — тогда в нём сохраняются и пробелы, и замены
/// словаря (их места пересчитываются на начало куска). Замена, которая
/// пришлась ровно на смену голоса, остаётся за куском, где она
/// начинается, если целиком в нём помещается; иначе её отметка
/// пропадает — сам заменённый текст остаётся на месте.
///
/// [raw] — слова с таймкодами от движка, если есть (см. [timeWords]).
List<Segment> splitBySpeakers(
  Segment seg,
  List<SpeakerTurn> turns, [
  List<TimedWord> raw = const [],
]) => splitAllBySpeakers([(seg, raw)], turns);

/// То же для всей записи сразу — так и надо звать, когда фрагментов
/// много: голосование по предложениям ([voteBySentences]) идёт по словам
/// всей записи, а предложение у whisper нередко начинается в одном
/// фрагменте и кончается в следующем («…стороны. На вопрос с» /
/// «кальцией здесь…»). По одному фрагменту такой хвост голосовать не
/// с кем.
List<Segment> splitAllBySpeakers(
  List<(Segment, List<TimedWord>)> parts,
  List<SpeakerTurn> turns,
) {
  final timed = [
    for (final (seg, raw) in parts) timeWords(seg.text, seg.from, seg.to, raw),
  ];
  final voiced = speakerWords([for (final w in timed) ...w], turns);
  final out = <Segment>[];
  var at = 0;
  for (var k = 0; k < parts.length; k++) {
    final n = timed[k].length;
    out.addAll(_cutByWords(parts[k].$1, voiced.sublist(at, at + n)));
    at += n;
  }
  return out;
}

List<Segment> _cutByWords(Segment seg, List<TimedWord> words) {
  if (words.isEmpty) return [seg.withSpeaker(null, overlap: false)];
  final spans = RegExp(r'\S+').allMatches(seg.text).toList();
  final out = <Segment>[];
  var start = 0;
  for (var i = 0; i < words.length; i++) {
    final last =
        i + 1 == words.length || words[i + 1].speaker != words[i].speaker;
    if (!last) continue;
    final textFrom = start == 0 ? 0 : spans[start].start;
    final textTo = i + 1 == words.length ? seg.text.length : spans[i].end;
    final piece = seg.text.substring(textFrom, textTo);
    final lead = piece.length - piece.trimLeft().length;
    final text = piece.trim();
    final shift = textFrom + lead;
    final replacements = [
      for (final r in seg.replacements)
        if (r.start >= shift && r.end <= shift + text.length)
          TextReplacement(
            start: r.start - shift,
            end: r.end - shift,
            original: r.original,
            replacement: r.replacement,
          ),
    ];
    out.add(
      Segment(
        start == 0 ? seg.from : words[start].from,
        i + 1 == words.length ? seg.to : words[i].to,
        text,
        replacements: replacements,
        speaker: words[i].speaker,
        overlap: words.sublist(start, i + 1).take(2).any((w) => w.overlap),
      ),
    );
    start = i + 1;
  }
  return out;
}

/// Довести голоса до готового вида: отметить перебивки по времени и
/// собрать список голосов.
///
/// Нашёлся ровно один голос (или ни одного) — разметку снимаем целиком:
/// «Голос 1» у каждой строки ничего не сообщает, а в файлы попадал бы
/// лишним шумом. Режим тогда выглядит так, будто он выключен.
Transcript finishSpeakers(
  Transcript t, {
  DiarizationInfo? info,
  String Function(int number) defaultName = defaultSpeakerName,
}) {
  final roster = speakerRoster(
    [for (final s in t.segments) (from: s.from, to: s.to, speaker: s.speaker)],
    previous: t.speakers,
    defaultName: defaultName,
  );
  if (roster.length < 2) {
    return t.copyWith(
      segments: [
        for (final s in t.segments) s.withSpeaker(null, overlap: false),
      ],
      clearSpeakers: true,
    );
  }
  final interrupts = markInterruptions([
    for (final s in t.segments)
      (from: s.from, to: s.to, speaker: s.speaker, overlap: s.overlap),
  ]);
  return t.copyWith(
    segments: [
      for (var i = 0; i < t.segments.length; i++)
        t.segments[i].withSpeaker(
          t.segments[i].speaker,
          overlap: interrupts[i],
        ),
    ],
    speakers: roster,
    diarization: info == null
        ? null
        : DiarizationInfo(
            engine: info.engine,
            segmentation: info.segmentation,
            embedding: info.embedding,
            threshold: info.threshold,
            requestedSpeakers: info.requestedSpeakers,
            detectedSpeakers: roster.length,
          ),
  );
}

/// Раздать голоса уже готовым фрагментам — тем, у кого слов от движка
/// нет (досчитанное до паузы, открытая расшифровка). Время слов внутри
/// каждого фрагмента раскладывается по доле символов.
Transcript applySpeakerTurns(
  Transcript t,
  List<SpeakerTurn> turns, {
  DiarizationInfo? info,
  String Function(int number) defaultName = defaultSpeakerName,
}) => finishSpeakers(
  t.copyWith(
    segments: splitAllBySpeakers([for (final s in t.segments) (s, const [])], turns),
  ),
  info: info,
  defaultName: defaultName,
);

/// [turns] — разметка голосов. Пусто — разбор ровно прежний, голосов нет.
/// [finish] false — фрагменты с голосами, но без списка голосов: так
/// очередь сначала доклеивает к ним досчитанное до паузы и только потом
/// собирает список ([finishSpeakers]) — иначе половина записи с одним
/// голосом потеряла бы разметку раньше времени.
/// Есть — каждый фрагмент режется по смене голоса по потокенным
/// таймкодам (они есть только в полном JSON, `-ojf`; без них время слов
/// раскладывается по доле символов).
Transcript parseWhisperJson(
  String jsonText, {
  List<SpeakerTurn> turns = const [],
  DiarizationInfo? info,
  String Function(int number) defaultName = defaultSpeakerName,
  bool finish = true,
}) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final lang = (data['result']?['language'] ?? '?').toString();
  final segs = <Segment>[];
  final parts = <(Segment, List<TimedWord>)>[];
  for (final t in (data['transcription'] as List? ?? [])) {
    final rawText = (t['text'] as String).trim();
    if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) continue;
    final text = stripSilenceHallucinations(rawText).trim();
    // Фрагмент, совпавший с известной выдумкой или очищенный до пустоты, —
    // это тишина, которую модель договорила за себя.
    if (text.isEmpty || looksLikeSilenceHallucination(text)) continue;
    final seg = Segment(
      (t['offsets']['from'] as num).toInt(),
      (t['offsets']['to'] as num).toInt(),
      text,
    );
    if (turns.isEmpty) {
      segs.add(seg);
    } else {
      // Слова от токенов годятся, только если фильтр не тронул текст:
      // иначе они описывают не то, что осталось.
      final words = text == rawText
          ? whisperTokenWords(t['tokens'])
          : const <TimedWord>[];
      parts.add((seg, words));
    }
  }
  if (turns.isNotEmpty) segs.addAll(splitAllBySpeakers(parts, turns));
  final out = Transcript(lang, collapseRepeats(segs));
  return turns.isEmpty || !finish
      ? out
      : finishSpeakers(out, info: info, defaultName: defaultName);
}

/// Слова из JSON, который пишет `nemo-speech transcribe --format json`.
List<TimedWord> parseNemoWords(Map<String, dynamic> data) =>
    (data['words'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final text = raw['word']?.toString().trim() ?? '';
          final from = (((raw['start'] as num?) ?? 0) * 1000).round();
          final to = (((raw['end'] as num?) ?? 0) * 1000).round();
          return TimedWord(from, to, text);
        })
        .where((word) => word.text.isNotEmpty)
        .toList();

/// Разобрать JSON, который пишет `nemo-speech transcribe --format json`.
///
/// NeMo отдаёт времена отдельных слов, а интерфейс работает с фрагментами.
/// Собираем слова по естественным границам ([groupWords]): конец
/// предложения, заметная пауза, либо достаточно длинная строка, а с
/// разметкой голосов [turns] — ещё и смена голоса. Таймкоды при этом
/// не теряются.
Transcript parseNemoJson(
  String jsonText, {
  List<SpeakerTurn> turns = const [],
  DiarizationInfo? info,
  String Function(int number) defaultName = defaultSpeakerName,
  bool finish = true,
}) {
  final data = jsonDecode(jsonText) as Map<String, dynamic>;
  final detectedLanguages = (data['languages'] as List? ?? const [])
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toList();
  var rawLang = detectedLanguages.isNotEmpty
      ? detectedLanguages.first
      : (data['language']?.toString().isNotEmpty == true
          ? data['language'].toString()
          : '?');
  var lang = normalizeLanguageCode(rawLang);
  var words = parseNemoWords(data);

  if (lang == '?' || lang == 'auto' || lang == 'unknown') {
    final wordsText = words.map((w) => w.text).join(' ');
    final rootText = data['text']?.toString() ?? '';
    final combinedText = '$wordsText $rootText'.trim();
    if (RegExp(r'[\u0400-\u04FF]').hasMatch(combinedText)) {
      lang = 'ru';
    } else {
      final latinCount = RegExp(r'[a-zA-Z]').allMatches(combinedText).length;
      final cyrillicCount =
          RegExp(r'[\u0400-\u04FF]').allMatches(combinedText).length;
      if (latinCount > cyrillicCount && latinCount > 0) {
        lang = 'en';
      }
    }
  }

  if (words.isEmpty) {
    final rawText = data['text']?.toString().trim() ?? '';
    if (rawText.isEmpty || looksLikeSilenceHallucination(rawText)) {
      return Transcript(lang, const []);
    }
    final text = stripSilenceHallucinations(rawText).trim();
    if (text.isEmpty || looksLikeSilenceHallucination(text)) {
      return Transcript(lang, const []);
    }
    final duration = (((data['duration'] as num?) ?? 0) * 1000).round();
    final whole = Transcript(lang, [Segment(0, duration, text)]);
    if (turns.isEmpty) return whole;
    return finish
        ? applySpeakerTurns(whole, turns, info: info, defaultName: defaultName)
        : whole.copyWith(segments: splitBySpeakers(whole.segments.single, turns));
  }

  if (turns.isNotEmpty) {
    words = speakerWords(words, turns);
  }
  final segments = <Segment>[];
  for (final group in groupWords(words)) {
    final rawText = group.text;
    if (rawText.isNotEmpty && !looksLikeSilenceHallucination(rawText)) {
      final text = stripSilenceHallucinations(rawText).trim();
      if (text.isNotEmpty && !looksLikeSilenceHallucination(text)) {
        segments.add(
          Segment(
            group.from,
            group.to,
            text,
            speaker: group.speaker,
            overlap: group.overlap,
          ),
        );
      }
    }
  }
  final out = Transcript(lang, collapseRepeats(segments));
  return turns.isEmpty || !finish
      ? out
      : finishSpeakers(out, info: info, defaultName: defaultName);
}

String fmtTs(int ms, {String msSep = '.'}) {
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final r = ms % 1000;
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(h)}:${p(m)}:${p(s)}$msSep${p(r, 3)}';
}

/// Знак перебивки в тексте. Знак, а не слово: переводить нечего, и
/// в файле он читается одинаково на любом языке.
const overlapMark = '⇄';

/// Кто говорит в этом фрагменте — имя для подписи или null, если
/// подписывать не нужно. Подпись ставится, только когда голосов больше
/// одного.
String? _who(Segment s, List<SpeakerInfo> speakers) {
  final id = s.speaker;
  if (id == null || speakers.length < 2) return null;
  return speakers.where((v) => v.id == id).firstOrNull?.name ?? id;
}

String _lead(Segment s, String name) =>
    s.overlap ? '$overlapMark $name: ' : '$name: ';

/// Подряд идущие фрагменты одного голоса — одна реплика.
List<List<Segment>> _byTurns(List<Segment> segs) {
  final out = <List<Segment>>[];
  for (final s in segs) {
    if (out.isNotEmpty && out.last.last.speaker == s.speaker) {
      out.last.add(s);
    } else {
      out.add([s]);
    }
  }
  return out;
}

/// Обычный текст. С голосами реплика одного голоса склеивается в абзац
/// с одной шапкой («Иван: …»), а смена голоса отделяется пустой строкой —
/// так расшифровку разговора читают глазами, а не по строчке на фрагмент.
String renderPlain(
  List<Segment> segs,
  bool timestamps, {
  List<SpeakerInfo> speakers = const [],
}) {
  String body(Segment s) {
    final name = _who(s, speakers);
    return name == null ? s.text : '${_lead(s, name)}${s.text}';
  }

  if (timestamps) {
    return segs
        .map((s) => '[${fmtTs(s.from)} → ${fmtTs(s.to)}]  ${body(s)}')
        .join('\n');
  }
  if (speakers.length < 2) return segs.map((s) => s.text).join('\n');
  return _byTurns(segs)
      .map((turn) {
        final text = turn.map((s) => s.text).join(' ');
        final name = _who(turn.first, speakers);
        return name == null ? text : '${_lead(turn.first, name)}$text';
      })
      .join('\n\n');
}

String renderSrt(List<Segment> segs, {List<SpeakerInfo> speakers = const []}) {
  final b = StringBuffer();
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    final name = _who(s, speakers);
    b.writeln('${i + 1}');
    b.writeln('${fmtTs(s.from, msSep: ',')} --> ${fmtTs(s.to, msSep: ',')}');
    b.writeln(name == null ? s.text : '$name: ${s.text}');
    b.writeln();
  }
  return b.toString();
}

/// Имя в голосовом теге WebVTT: угловые скобки и амперсанд в нём
/// ломают разметку, остальное можно как есть.
String _vttEscape(String name) => name
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// WebVTT. Голос — стандартным голосовым тегом `<v Иван>`: его понимают
/// проигрыватели и показывают имя сами.
String renderVtt(List<Segment> segs, {List<SpeakerInfo> speakers = const []}) {
  final b = StringBuffer('WEBVTT\n\n');
  for (final s in segs) {
    final name = _who(s, speakers);
    b.writeln('${fmtTs(s.from)} --> ${fmtTs(s.to)}');
    b.writeln(name == null ? s.text : '<v ${_vttEscape(name)}>${s.text}</v>');
    b.writeln();
  }
  return b.toString();
}

String renderJson(Transcript t) {
  final voices = t.hasSpeakers;
  return const JsonEncoder.withIndent('  ').convert({
    'language': t.lang,
    'segments': [
      for (final s in t.segments)
        {
          'from': s.from,
          'to': s.to,
          'text': s.text,
          if (voices) 'speaker': s.speaker,
          if (voices) 'overlap': s.overlap,
        },
    ],
    if (voices) 'speakers': [for (final v in t.speakers) v.toJson()],
    if (voices && t.diarization != null) 'diarization': t.diarization!.toJson(),
  });
}

/// Имя в markdown: служебные знаки разметки экранируются, иначе
/// «*Иван*» стал бы курсивом, а «[Иван]» — ссылкой.
String _mdEscape(String name) =>
    name.replaceAllMapped(RegExp(r'[\\`*_\[\]<>#|~]'), (m) => '\\${m[0]}');

/// Markdown с готовой шапкой. Шапку сюда передают: в ней имя записи,
/// язык и число фрагментов — то есть переведённый текст, а переводы
/// приходят из Flutter, которого в этом файле быть не должно
/// (см. `labels.dart`).
String renderMarkdown(
  String header,
  List<Segment> segs, {
  List<SpeakerInfo> speakers = const [],
}) {
  final b = StringBuffer(header);
  if (speakers.length < 2) {
    for (final s in segs) {
      b.writeln('**[${fmtTs(s.from)}]** ${s.text}\n');
    }
    return b.toString();
  }
  for (final turn in _byTurns(segs)) {
    final first = turn.first;
    final name = _who(first, speakers);
    final text = turn.map((s) => s.text).join(' ');
    if (name == null) {
      b.writeln('**[${fmtTs(first.from)}]** $text\n');
      continue;
    }
    final mark = first.overlap ? '$overlapMark ' : '';
    b.writeln('$mark**${_mdEscape(name)}** · [${fmtTs(first.from)}]');
    b.writeln('$text\n');
  }
  return b.toString();
}

/// Формат экспорта — именованный, с собственным окончанием имени файла.
/// Раньше содержимое .txt зависело от галки «показывать метки времени»,
/// то есть настройка вида молча меняла файл. Теперь это разные форматы.
class ExportFormat {
  const ExportFormat(this.id, this.bareSuffix);
  final String id;

  /// Окончание имени файла без перевода. У текста с таймкодами в нём
  /// стоит слово, а слово это интерфейсное — по-английски файл должен
  /// называться «(timestamps).txt». Переведённое окончание, имя формата
  /// и всё прочее, что произносится вслух, живёт в `labels.dart`:
  /// здесь Flutter появиться не может.
  final String bareSuffix;
}

const formatPlainText = ExportFormat('txt', '.txt');
const formatTimedText = ExportFormat('txt-ts', ' (таймкоды).txt');
const formatSrt = ExportFormat('srt', '.srt');
const formatVtt = ExportFormat('vtt', '.vtt');
const formatMarkdown = ExportFormat('md', '.md');
const formatJson = ExportFormat('json', '.json');

const exportFormats = [
  formatPlainText,
  formatTimedText,
  formatSrt,
  formatVtt,
  formatMarkdown,
  formatJson,
];

ExportFormat formatById(String id) =>
    exportFormats.firstWhere((f) => f.id == id, orElse: () => formatPlainText);

/// Расшифровка в выбранном формате.
///
/// [markdownHeader] — готовая шапка markdown-файла; без неё берётся
/// простая, из одного имени. Приложение подставляет переведённую
/// (`renderFor` в `labels.dart`), отдельная программа расшифровки
/// обходится простой: переводов у неё нет.
String renderAs(
  ExportFormat f,
  Transcript t, {
  String name = '',
  String? markdownHeader,
}) => switch (f.id) {
  'txt' => renderPlain(t.segments, false, speakers: t.speakers),
  'txt-ts' => renderPlain(t.segments, true, speakers: t.speakers),
  'srt' => renderSrt(t.segments, speakers: t.speakers),
  'vtt' => renderVtt(t.segments, speakers: t.speakers),
  'md' => renderMarkdown(
    markdownHeader ?? '# $name\n\n',
    t.segments,
    speakers: t.speakers,
  ),
  'json' => renderJson(t),
  _ => renderPlain(t.segments, false, speakers: t.speakers),
};

// Настройки живут в lib/settings.dart: им нужен dart:ui ради очереди
// записи между изолятами, а этот файл должен оставаться пригодным для
// `dart run` (tool/probe.dart).
