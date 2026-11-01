import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

/// Токенизатор ключевых слов для Sherpa-ONNX KeywordSpotter.
///
/// Преобразует пользовательские слова (русские, английские) в последовательность
/// токенов модели с поддержкой SentencePiece/BPE и транслитерации кириллицы.
///
/// Формат строки ключевого слова для sherpa-onnx:
/// `token1 token2 ... @оригинал :score #threshold`
/// Где:
/// - `:score` — boosting score (по умолчанию 1.5)
/// - `#threshold` — trigger threshold (по умолчанию 0.25)
/// - `@оригинал` — возвращаемое имя ключевого слова при срабатывании.
class KeywordTokenizer {
  KeywordTokenizer({Set<String>? vocabulary})
    : _vocabulary = vocabulary ?? defaultVocabulary;

  final Set<String> _vocabulary;

  static String normalizeKeywordText(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Encode with the model's own SentencePiece ranks. KWS token IDs must
  /// match the model; a greedy split of tokens.txt changes those IDs.
  static String formatForModel(
    String keyword,
    SentencePieceTokenizer tokenizer, {
    double boostingScore = 1.5,
    double threshold = 0.25,
  }) {
    final original = normalizeKeywordText(keyword);
    if (original.isEmpty) return '';
    final spoken = _englishPronunciation(original);
    final tokens = tokenizer.encode(spoken).tokens;
    if (tokens.isEmpty || tokens.any((token) => token == '<unk>')) return '';
    final label = original.replaceAll(' ', '_');
    return '${tokens.join(' ')} @$label '
        ':${boostingScore.toStringAsFixed(2)} '
        '#${threshold.toStringAsFixed(2)}';
  }

  static String _englishPronunciation(String text) {
    const common = {'джеф': 'JEFF', 'джефф': 'JEFF'};
    final lower = text.toLowerCase();
    if (common.containsKey(lower)) return common[lower]!;
    return text.runes.any((r) => r >= 0x0400 && r <= 0x052f)
        ? transliterate(text).replaceAll(RegExp(r'\s+'), ' ')
        : text.toUpperCase();
  }

  /// Стандартный словарь базовых токенов (латинские буквы + спецсимволы BPE).
  static final Set<String> defaultVocabulary = {
    '<blk>',
    '<sos/eos>',
    '<unk>',
    '▁',
    for (int c = 65; c <= 90; c++) String.fromCharCode(c), // A-Z
    for (int c = 65; c <= 90; c++) '▁${String.fromCharCode(c)}', // ▁A-▁Z
  };

  /// Таблица практической фонетической транслитерации для русской речи.
  static const Map<String, String> cyrillicToPhonetic = {
    'а': 'A',
    'б': 'B',
    'в': 'V',
    'г': 'G',
    'д': 'D',
    'е': 'E',
    'ё': 'YO',
    'ж': 'ZH',
    'з': 'Z',
    'и': 'I',
    'й': 'Y',
    'к': 'K',
    'л': 'L',
    'м': 'M',
    'н': 'N',
    'о': 'O',
    'п': 'P',
    'р': 'R',
    'с': 'S',
    'т': 'T',
    'у': 'U',
    'ф': 'F',
    'х': 'H',
    'ц': 'TS',
    'ч': 'CH',
    'ш': 'SH',
    'щ': 'SHCH',
    'ъ': '',
    'ы': 'Y',
    'ь': '',
    'э': 'E',
    'ю': 'YU',
    'я': 'YA',
  };

  /// Загрузить словарь из содержимого файла tokens.txt.
  static KeywordTokenizer fromTokensFile(String content) {
    final vocab = <String>{};
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.isNotEmpty) {
        vocab.add(parts.first);
      }
    }
    return KeywordTokenizer(vocabulary: vocab);
  }

  /// Транслитерировать кириллицу в латиницу для распознавания.
  static String transliterate(String text) {
    final sb = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune).toLowerCase();
      if (cyrillicToPhonetic.containsKey(ch)) {
        sb.write(cyrillicToPhonetic[ch]);
      } else {
        sb.write(String.fromCharCode(rune).toUpperCase());
      }
    }
    return sb.toString();
  }

  /// Токенизировать одно слово или фразу в токены словаря.
  List<String> tokenizeWord(String word, {bool isFirstWord = true}) {
    final clean = word.trim();
    if (clean.isEmpty) return const [];

    final latin = transliterate(clean);
    final tokens = <String>[];

    // Попытка разбить слово на подслова/буквы из словаря
    var i = 0;
    while (i < latin.length) {
      bool matched = false;
      // Жадный поиск самого длинного подходящего токена
      final maxLen = (latin.length - i).clamp(1, 15);
      for (var len = maxLen; len >= 1; len--) {
        final sub = latin.substring(i, i + len);
        final candidateWithPrefix = (i == 0 && isFirstWord) ? '▁$sub' : sub;

        if (_vocabulary.contains(candidateWithPrefix)) {
          tokens.add(candidateWithPrefix);
          i += len;
          matched = true;
          break;
        } else if (_vocabulary.contains(sub)) {
          tokens.add(sub);
          i += len;
          matched = true;
          break;
        }
      }

      if (!matched) {
        // Одиночный символ в верхнем регистре как запасной вариант
        final char = latin[i].toUpperCase();
        tokens.add(_vocabulary.contains(char) ? char : char);
        i++;
      }
    }

    return tokens;
  }

  /// Построить строку определения ключевого слова для sherpa-onnx.
  ///
  /// Пример: `▁J E FF @Джеф :1.5 #0.25`
  String formatKeyword(
    String keyword, {
    double boostingScore = 1.5,
    double threshold = 0.25,
  }) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return '';

    final words = trimmed.split(RegExp(r'\s+'));
    final allTokens = <String>[];

    for (var i = 0; i < words.length; i++) {
      final wTokens = tokenizeWord(words[i], isFirstWord: i == 0);
      allTokens.addAll(wTokens);
    }

    if (allTokens.isEmpty) return '';

    final tokensStr = allTokens.join(' ');
    return '$tokensStr @$trimmed :${boostingScore.toStringAsFixed(2)} #${threshold.toStringAsFixed(2)}';
  }

  /// Объединить несколько ключевых слов в формат аргумента SherpaOnnxCreateKeywordStreamWithKeywords.
  ///
  /// Разделитель между ключевыми словами — косая черта `/`.
  String buildStreamKeywords(
    List<String> keywords, {
    double boostingScore = 1.5,
    double threshold = 0.25,
  }) {
    final formatted = <String>[];
    for (final kw in keywords) {
      final f = formatKeyword(
        kw,
        boostingScore: boostingScore,
        threshold: threshold,
      );
      if (f.isNotEmpty) formatted.add(f);
    }
    return formatted.join('/');
  }
}

/// Удалить слово завершения (CloseWord) из конца распознанного текста,
/// если оно попало в расшифровку Whisper (в том числе повторенное несколько раз,
/// в кавычках, скобках, через запятую, тире или отдельными предложениями).
String stripTrailingCloseWord(String text, String closeWord) {
  final target = closeWord.trim().toLowerCase();
  if (target.isEmpty || text.trim().isEmpty) return text;

  // Регулярка для хвостовых знаков препинания, кавычек и скобок
  final trailingPunctuationRegex = RegExp(r'[\s.,!?;:\-—…""«»”’‘)\]}>„]+$');
  final boundarySeparators = RegExp(r'[\s.,!?;:\-—…""«»“”‘’()[\]{}<>„]$');

  var current = text;
  bool changed = true;

  while (changed) {
    changed = false;
    final trimmed = current.trimRight();
    if (trimmed.isEmpty) return '';

    // Снимаем хвостовую пунктуацию, кавычки и скобки
    final trailingMatch = trailingPunctuationRegex.firstMatch(trimmed);
    final endPunct = trailingMatch?.group(0) ?? '';
    final core = trimmed.substring(0, trimmed.length - endPunct.length);
    final coreLower = core.toLowerCase();

    int? matchStartIdx;
    if (coreLower.endsWith(target)) {
      matchStartIdx = core.length - target.length;
    } else {
      // Проверяем случай с открывающей кавычкой или скобкой перед target
      for (final quote in ['"', "'", '«', '“', '‘', '(', '[', '{']) {
        if (coreLower.endsWith('$quote$target')) {
          matchStartIdx = core.length - target.length - quote.length;
          break;
        }
      }
    }

    if (matchStartIdx != null) {
      final isAtStart = matchStartIdx == 0;
      final hasWordBoundary =
          isAtStart ||
          boundarySeparators.hasMatch(core.substring(0, matchStartIdx));

      if (hasWordBoundary) {
        var before = core.substring(0, matchStartIdx).trimRight();
        // Убираем висячие знаки препинания, кавычки и скобки перед вырезанным словом
        final danglingRegex = RegExp(r'[,:\-—"«“‘(\[{<„]+$');
        while (danglingRegex.hasMatch(before)) {
          before = before.replaceAll(danglingRegex, '').trimRight();
        }

        current = before;
        changed = true;
      }
    }
  }

  return current;
}

/// Слово «с Enter» из настроек, если оно допустимо: пустое, совпадающее
/// с закрывающим словом или словом активации не работает — иначе одно
/// слово означало бы два разных действия.
String effectiveEnterWord(String enterWord, String wakeWord, String closeWord) {
  final enter = KeywordTokenizer.normalizeKeywordText(enterWord);
  if (enter.isEmpty ||
      enter == KeywordTokenizer.normalizeKeywordText(wakeWord) ||
      enter == KeywordTokenizer.normalizeKeywordText(closeWord)) {
    return '';
  }
  return enterWord;
}

/// Вырезать слово «с Enter» из конца текста. Слово считается только как
/// последнее в фразе (как закрывающее): в середине предложения оно остаётся
/// обычным словом. Возвращает текст без слова и признак, что оно было.
(String, bool) takeTrailingEnterWord(String text, String enterWord) {
  if (enterWord.trim().isEmpty) return (text, false);
  final rest = stripTrailingCloseWord(text, enterWord);
  return (rest, rest != text);
}
