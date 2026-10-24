/// Настройки одного распознавания и то, во что они превращаются
/// на командной строке whisper-cli.
library;

import '../platform/os.dart';
import 'recognition.dart';
import 'vocabulary.dart' show promptWithVocabulary;

/// С таймкодами модель на разговорной речи скатывается в сплошной нижний
/// регистр без знаков препинания. Затравка задаёт стиль — знаки возвращаются,
/// а таймкоды остаются (проверено на этих же записях).
///
/// Формулировка выверена по двум ошибкам, которые давала прежняя.
///
/// Первая: она называла себя «расшифровкой разговорной речи», а whisper
/// принимает подсказку не как указание, а как **предыдущий текст**, который
/// продолжает. В русском прямая речь открывается тире — и модель
/// добросовестно начинала реплику с тире. Слово «тире» в перечислении
/// знаков подсказывало то же самое. Теперь ни того, ни другого: речь идёт
/// о записанном тексте, а не о репликах, и тире в перечне нет.
///
/// Вторая: «расшифровка» и «субтитры» — соседи по обучающим данным, и
/// оттуда же приходили «Продолжение следует…» и «Субтитры сделал…».
/// Подсказка теперь не поминает ни расшифровок, ни субтитров вовсе.
const _punctuationPrimerRu =
    'Записанный текст оформлен по правилам русского языка: с запятыми и '
    'точками, с вопросительными и восклицательными знаками, каждое '
    'предложение начинается с заглавной буквы.';
const _punctuationPrimerEn =
    'The written text below follows standard punctuation: commas and periods, '
    'question and exclamation marks, and a capital letter at the start of '
    'every sentence.';

const _cyrillicLangs = {'ru', 'be', 'uk', 'kk'};

String punctuationPrimer(String lang) =>
    _cyrillicLangs.contains(lang) ? _punctuationPrimerRu : _punctuationPrimerEn;

/// Состояние записи в очереди. Раньше это была строка, и проверка «ошибка?»
/// сводилась к сравнению с текстом на экране — стоило переписать надпись,
/// и значок ломался.
enum JobState {
  queued,
  waiting,
  converting,
  transcribing,

  /// Текст готов, идёт разметка голосов — отдельным шагом после
  /// распознавания, по тому же звуку (см. `diarization/diarizer.dart`).
  diarizing,
  paused,
  done,
  failed,
  cancelled
}

/// Настройки одного распознавания. Они же — общие настройки приложения:
/// у записи может быть свой набор, и тогда он замещает общий целиком.
class RunOptions {
  final String model, lang, prompt, vadModel;
  final int threads, maxLen;
  final bool vad, punctuate;

  /// Режим «Несколько голосов»: после распознавания определить, кто
  /// говорит. Выключен — приложение ведёт себя ровно как без режима.
  final bool diarize;

  /// Сколько голосов ждать. Ноль — определить самим по порогу. Число —
  /// это цель для кластеризации, а не обещание: движок может найти
  /// меньше (talkthrough-mcp заказывал восемь–девять, получал семь).
  final int speakerCount;
  const RunOptions({
    required this.model,
    required this.lang,
    required this.threads,
    this.maxLen = 0,
    this.vad = false,
    this.vadModel = '',
    this.prompt = '',
    this.punctuate = true,
    this.diarize = false,
    this.speakerCount = 0,
  });

  RunOptions copyWith({
    String? model,
    String? lang,
    int? threads,
    int? maxLen,
    bool? vad,
    String? vadModel,
    String? prompt,
    bool? punctuate,
    bool? diarize,
    int? speakerCount,
  }) =>
      RunOptions(
        model: model ?? this.model,
        lang: lang ?? this.lang,
        threads: threads ?? this.threads,
        maxLen: maxLen ?? this.maxLen,
        vad: vad ?? this.vad,
        vadModel: vadModel ?? this.vadModel,
        prompt: prompt ?? this.prompt,
        punctuate: punctuate ?? this.punctuate,
        diarize: diarize ?? this.diarize,
        speakerCount: speakerCount ?? this.speakerCount,
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'lang': lang,
        'threads': threads,
        'maxLen': maxLen,
        'vad': vad,
        'vadModel': vadModel,
        'prompt': prompt,
        'punctuate': punctuate,
        'diarize': diarize,
        'speakerCount': speakerCount,
      };

  /// Чего в файле настроек нет — берём из [fallback]: так старые файлы
  /// продолжают открываться после добавления новой галки.
  factory RunOptions.fromJson(Map<String, dynamic> j, RunOptions fallback) =>
      RunOptions(
        model: (j['model'] as String?) ?? fallback.model,
        lang: (j['lang'] as String?) ?? fallback.lang,
        threads: (j['threads'] as int?) ?? fallback.threads,
        maxLen: (j['maxLen'] as int?) ?? fallback.maxLen,
        vad: (j['vad'] as bool?) ?? fallback.vad,
        vadModel: (j['vadModel'] as String?) ?? fallback.vadModel,
        prompt: (j['prompt'] as String?) ?? fallback.prompt,
        punctuate: (j['punctuate'] as bool?) ?? fallback.punctuate,
        diarize: (j['diarize'] as bool?) ?? fallback.diarize,
        speakerCount: (j['speakerCount'] as int?) ?? fallback.speakerCount,
      );

  /// Своя подсказка важнее: она уже задаёт модели и стиль, и словарь.
  String get effectivePrompt {
    final selected = prompt.trim().isNotEmpty
        ? prompt.trim()
        : punctuate && lang != 'auto'
            ? punctuationPrimer(lang)
            : '';
    return engineForModel(model) == RecognitionEngine.whisperCpp
        ? promptWithVocabulary(selected, const [])
        : selected;
  }
}

/// Чем разрывается цепочка повторов: окно не наследует текст предыдущего,
/// а стиль держится затравкой — её подкладывают в каждое окно заново,
/// иначе с потерей контекста ушли бы и знаки препинания.
///
/// В исходном whisper.cpp эти флаги конфликтуют: нулевой max-context
/// съедает и начальную подсказку. В комплектном движке их разделяет
/// `tool/prompt-context.patch`: ноль относится только к распознанной
/// истории, а initial prompt остаётся у каждого окна.
List<String> noLoopArgs(RunOptions o) => [
      '-mc', '0',
      if (o.effectivePrompt.isNotEmpty) '--carry-initial-prompt',
    ];

/// [from] — с какой миллисекунды считать. Так продолжается запись,
/// остановленная посреди: whisper умеет начать с середины и метки времени
/// отдаёт всё равно от начала файла, так что склеивать ничего не нужно.
/// Доводы для whisper-cli.
///
/// Каждый путь идёт через `os.processPath`: на Windows чужой программе
/// нельзя отдать путь с кириллицей — её рантайм переводит `argv`
/// в однобайтовую кодировку системы, и буквы теряются до первой строчки
/// кода движка (разбор в `os.dart`). На macOS это ничего не меняет.
List<String> buildArgs(RunOptions o, String wav, String outBase, {int from = 0}) => [
      '-m', os.processPath(o.model),
      '-l', o.lang,
      '-t', '${o.threads}',
      '-pp',
      // Отсюда и брались зацикливания на десятки минут. whisper тащит
      // распознанный текст окна в подсказку следующего: стоит одному
      // тридцатисекундному окну сорваться в повтор, как повтор приходит
      // затравкой в следующее — и модель повторяет его сама себе, пока
      // что-нибудь случайно не собьёт. Без переноса срыв остаётся внутри
      // одного окна, а оттуда его вытаскивает обычный откат по температуре.
      ...noLoopArgs(o),
      '-of', os.processPath(outBase),
      // Остальные форматы приложение собирает само — из одного источника.
      //
      // С голосами нужен полный JSON: в нём у каждого токена своё время,
      // и по нему фрагмент режется на смене говорящего. Фрагменты при
      // этом остаются прежними, и текст тоже: потокенное время whisper
      // считает уже после декодирования (`whisper_exp_compute_token_level_
      // timestamps` в whisper.cpp 1.9.3), на сами слова оно не влияет.
      // Поэтому и не `-ml 1`: тот дробит фрагменты до слова, и фильтры
      // выдумок, рассчитанные на фразы, перестали бы их узнавать.
      o.diarize ? '-ojf' : '-oj',

      if (from > 0) ...['-ot', '$from'],
      if (o.maxLen > 0) ...['-ml', '${o.maxLen}', '-sow'],
      if (o.vad && o.vadModel.isNotEmpty)
        ...['--vad', '-vm', os.processPath(o.vadModel)],
      if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
      os.processPath(wav),
    ];

/// Доводы для нативного `nemo-speech transcribe`.
///
/// NeMo сам отдаёт один JSON с таймкодами слов. Остальные форматы, как и
/// у Whisper, приложение строит из него — тогда копирование, библиотека и
/// конвертация всегда видят один и тот же результат.
List<String> buildNemoArgs(RunOptions o, String wav, String jsonPath) => [
      'transcribe',
      os.processPath(wav),
      // Команда живёт ровно один файл. Штатный warm-up заранее прогоняет
      // четыре секунды тишины, а затем процесс всё равно сразу завершается.
      // На старых Vulkan-картах эта подготовка может быть дольше самой
      // записи; первый настоящий проход и без неё построит нужные графы.
      '--no-warmup',
      '--model',
      os.processPath(o.model),
      '--format',
      'json',
      '--output',
      os.processPath(jsonPath),
      '--force',
      if (o.lang != 'auto' && o.lang.isNotEmpty) ...['--language', o.lang],
      if (!o.punctuate) '--no-punctuation',
      if (o.prompt.trim().isNotEmpty && recognitionModelSupportsPrompt(o.model)) ...[
        '--speech-context',
        o.prompt.trim(),
        '--speech-context-boost',
        '3',
      ],
    ];
