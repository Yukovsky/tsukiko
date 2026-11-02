import 'dart:io';

import 'package:equatable/equatable.dart';

import '../platform/os.dart';
import 'app_locale.dart';
import 'logger.dart';
import 'recognition.dart';

/// Модели распознавания: где их искать, что из них годится, как они
/// называются для человека, что можно докачать и как это качается.

/// Файл модели распознавания. Имя VAD-модели устроено так же
/// (ggml-silero-….bin), но речь она не распознаёт — в списке моделей ей
/// не место, иначе её можно выбрать и получить пустую расшифровку.
/// То же с моделью разметки голосов: она тоже `.gguf`, но делит речь
/// по говорящим и текста не выдаёт.
bool looksLikeSpeechModel(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('diarization')) return false;
  if (lower.endsWith('.gguf')) return true;
  return lower.startsWith('ggml-') &&
      lower.endsWith('.bin') &&
      !lower.contains('silero');
}

/// Модель, лежащая на диске, со всем, что о ней надо знать до выбора.
///
/// Раньше список моделей был просто списком путей, и из него нельзя было
/// понять ни размера, ни того, цел ли файл: битую или недокачанную модель
/// показывали наравне с рабочей, и узнавалось это только при запуске
/// распознавания — руганью whisper про тензоры.
/// Сравнивается по значениям: обход диска каждый раз создаёт новые
/// объекты, и без этого список выглядел бы изменившимся на каждом опросе.
class InstalledModel extends Equatable {
  const InstalledModel({
    required this.path,
    required this.sizeBytes,
    required this.problem,
    required this.ours,
  });

  final String path;

  /// Размер файла. Ноль — прочитать не удалось.
  final int sizeBytes;

  /// Почему файл не годится в модель распознавания. Пусто — годится.
  final String? problem;

  /// Лежит в нашей папке моделей, а не в общем кеше whisper.cpp.
  /// Чужую папку делят с другими программами, и трогать её надо осторожнее.
  final bool ours;

  String get name => modelDisplayName(path);
  String get folder => os.dirname(path);
  bool get broken => problem != null;
  RecognitionEngine get engine => engineForModel(path);

  String get sizeLabel =>
      sizeBytes <= 0 ? '' : sizeLabelMb(sizeBytes ~/ (1024 * 1024));

  @override
  List<Object?> get props => [path, sizeBytes, problem, ours];
}

/// Что лежит на диске — с проверкой каждого файла.
///
/// Проверка стоит чтения восьми байт и размера, то есть ничего: моделей
/// единицы, а показать битую как рабочую дороже.
List<InstalledModel> scanModels() {
  final out = <InstalledModel>[];
  final seen = <String>{};
  for (final d in [os.modelsDir, ...os.sharedModelDirs]) {
    final dir = Directory(d);
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !looksLikeSpeechModel(os.basename(f.path))) continue;
      if (!seen.add(f.path)) continue;
      var size = 0;
      try {
        size = f.lengthSync();
      } catch (_) {}
      out.add(InstalledModel(
        path: f.path,
        sizeBytes: size,
        problem: modelFileProblem(f.path),
        ours: f.path.startsWith(os.modelsDir),
      ));
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  Log.info(
    'Model',
    'Discovered ${out.length} models in directories: [${[os.modelsDir, ...os.sharedModelDirs].join(', ')}]',
  );
  for (final m in out) {
    Log.debug('Model', 'Discovered model: ${m.path} (${m.sizeLabel}, broken: ${m.broken})');
  }
  return out;
}

/// Модель тишины, если она загружена.
///
/// В списке речевых её нет намеренно — она не распознаёт речь, а вырезает
/// паузы до модели. Но файл лежит в той же папке, и молчать о нём нельзя:
/// человек видит его в папке, не находит в списке и не понимает, что это.
InstalledModel? findVadModel() {
  final f = File(vadModelPath);
  if (!f.existsSync()) return null;
  var size = 0;
  try {
    size = f.lengthSync();
  } catch (_) {}
  // Своя проверка: у модели тишины словарь в десяток слов, и общая
  // проверка речевой модели забраковала бы её по делу, но не по адресу.
  // Здесь важно одно — файл целый и не огрызок.
  return InstalledModel(
    path: f.path,
    sizeBytes: size,
    problem: size < 100 * 1024 ? currentL10n().vadTooSmall : null,
    ours: true,
  );
}

/// Только пути и только годных: тому, кто собирается распознавать, битая
/// модель в списке ни к чему.
List<String> findModels() =>
    [for (final m in scanModels()) if (!m.broken) m.path];

/// Подпись, по которой две модели не спутать.
///
/// Имя собирается из имени файла, поэтому одна и та же «Large v3 Turbo»
/// в разных папках выглядела в списке двумя одинаковыми строками, и какая
/// из них выбрана — понять было нельзя. Когда имя не одно, дописываем папку.
String modelLabel(String path, List<String> all) {
  final name = modelDisplayName(path);
  final sameName =
      all.where((p) => modelDisplayName(p) == name).length > 1;
  if (!sameName) return name;
  final dir = os.dirname(path);
  final where = dir.startsWith(os.modelsDir)
      ? appName
      : os.basename(dir).replaceFirst(RegExp(r'^\.'), '');
  return '$name · $where';
}

/// Пункты системного меню выбора модели: подпись, значение и отметка
/// выбранной. Чистая функция, чтобы состав меню проверялся без macOS.
List<Map<String, Object>> modelMenuItems(List<String> all, String? chosen) => [
  for (final path in all)
    {'title': modelLabel(path, all), 'value': path, 'checked': path == chosen},
];

// ── откуда берутся модели ───────────────────────────────────────────────────
//
// Без файла модели приложение бесполезно, а взять его новому человеку
// неоткуда. Поэтому качаем сами — в свою папку, которую findModels() уже
// просматривает.

const _modelRepo = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';
const _nemotron35Repo =
    'https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/'
    '1c8deaecc64b91f034d73e08dd8b64625eb3395d';
const _parakeetTdtRepo =
    'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/'
    '541d1f99c6b0c3cd0b11a95167540bb8edefd82b';

/// VAD лежит в другом репозитории: в ggerganov/whisper.cpp этого файла нет,
/// оттуда приходит 404.
const vadModelFile = 'ggml-silero-v5.1.2.bin';
const vadModelUrl =
    'https://huggingface.co/ggml-org/whisper-vad/resolve/main/$vadModelFile';

String modelPathFor(String file) => os.join(os.modelsDir, file);

String get vadModelPath => modelPathFor(vadModelFile);

String sizeLabelMb(int mb) {
  final l10n = currentL10n();
  return mb >= 1024 ? l10n.sizeGb(mb / 1024) : l10n.sizeMb(mb);
}

/// Имя модели, одно на всё приложение: загрузчик, панель, переключатель,
/// инспектор и диалоги называют «ggml-large-v3-turbo.bin» одинаково —
/// «Large v3 Turbo». Модель может быть и не из каталога (свой файл, чужая
/// папка), поэтому имя разбирается из имени файла, а не ищется в списке:
/// слова из букв — с заглавной, версии и квантование — как есть.
String modelDisplayName(String path) {
  final file = os.basename(path);
  final stem = file
      .replaceFirst(RegExp(r'^ggml-'), '')
      .replaceFirst(RegExp(r'\.bin$'), '')
      .replaceFirst(RegExp(r'\.gguf$'), '')
      .replaceFirst(RegExp(r'\.(?:q8_0|q6_k|f16|fp16|bf16)$'), '')
      // Whisper пишет языковую разновидность через точку (`small.en`),
      // тогда как в версиях NeMo точка — часть числа (`3.5`, `0.6b`).
      .replaceFirstMapped(RegExp(r'\.([a-z]{2})$'), (m) => '-${m[1]}')
      .trim();
  if (stem.isEmpty) return file;
  final words = stem
      .split(RegExp(r'[-\s]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  String wordAt(int index) {
    final word = words[index];
    final lower = word.toLowerCase();
    if (lower == 'asr') return 'ASR';
    if (lower == 'tdt') return 'TDT';
    return RegExp(r'^[a-zA-Zа-яА-Я]+$').hasMatch(word)
        ? word[0].toUpperCase() + word.substring(1).toLowerCase()
        : word;
  }

  return [for (var i = 0; i < words.length; i++) wordAt(i)].join(' ');
}

/// Годится ли выбранный файл в модель распознавания. Возвращает null,
/// если годится, иначе — фразу для человека.
///
/// Расширения «.bin» мало: под ним лежит что угодно, а whisper-cli
/// на чужом файле падает с английской руганью про тензоры. Настоящая
/// модель ggml начинается с числа «ggml» (на диске это байты «lmgg»),
/// а следом идёт размер словаря — у модели речи он десятки тысяч слов,
/// у модели тишины десять. По этим двум числам речевая модель отличается
/// и от мусора, и от VAD.
String? modelFileProblem(String path) {
  final file = File(path);
  final name = os.basename(path);
  final l10n = currentL10n();
  if (!file.existsSync()) return l10n.modelFileGone(name);

  final size = file.lengthSync();
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final head = raf.readSync(8);
    final magic = head.length < 4
        ? ''
        : String.fromCharCodes(head.sublist(0, 4));
    if (engineForModel(path) == RecognitionEngine.nemoSpeechCpp) {
      if (magic != 'GGUF') return l10n.modelNotSpeechModel(name);
    } else if (head.length < 8 || magic != 'lmgg') {
      return l10n.modelNotSpeechModel(name);
    } else {
      // Little-endian uint32 сразу за меткой.
      final vocab =
          head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24);
      if (vocab < 1000) return l10n.modelIsVad(name, vocab);
    }
  } catch (_) {
    return l10n.modelUnreadable(name);
  } finally {
    raf?.closeSync();
  }

  // Самая маленькая речевая модель — tiny, 74 МБ; квантованная чуть меньше.
  if (size < 20 * 1024 * 1024) {
    return l10n.modelTooSmall(name, sizeLabelMb(size ~/ (1024 * 1024)));
  }
  return null;
}

/// Модель, которую приложение умеет достать само. Размер записан здесь,
/// а не спрашивается у сервера: выбирать надо до загрузки, а не после.
enum ModelLanguageScope { multilingual, fortyPlus, european25 }

/// Не рейтинг «вообще», а главный практический смысл варианта в каталоге.
/// Он нужен интерфейсу сравнения: одно название `Large` или `0.6B` ничего
/// не говорит человеку о том, зачем брать именно этот файл.
enum ModelFocus { compact, balanced, fast, accurate, live }

class ModelOffer {
  const ModelOffer(
    this.file,
    this.mb,
    this.about, {
    required this.engine,
    required this.languages,
    required this.focus,
    this.supportsPrompt = true,
    this.sourceUrl,
  });
  final String file, about;
  final int mb;
  final RecognitionEngine engine;
  final ModelLanguageScope languages;
  final ModelFocus focus;
  final bool supportsPrompt;
  final String? sourceUrl;

  /// Имя общее со всем приложением: отдельное поле разошлось бы с ним.
  String get title => modelDisplayName(file);
  String get url => sourceUrl ?? '$_modelRepo/$file';
  String get path => modelPathFor(file);
  bool get present => File(path).existsSync();
  String get size => sizeLabelMb(mb);
}

/// Каталог один на всё приложение: и вкладка «Модели», и выпадающий список
/// в инспекторе, и он же в настройках диктовки берут модели отсюда.
///
/// Large v1 и v2 в каталог не попали намеренно: это те же три гигабайта,
/// что и v3, только обучены раньше, и на русском v3 их обходит. Три почти
/// одинаковые трёхгигабайтные строки в списке — не выбор, а помеха.
List<ModelOffer> get modelCatalog {
  final l10n = currentL10n();
  return [
    ModelOffer(
      'ggml-tiny.bin', 74, l10n.offerTiny,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.compact,
    ),
    ModelOffer(
      'ggml-base.bin', 141, l10n.offerBase,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.compact,
    ),
    ModelOffer(
      'ggml-small.bin', 465, l10n.offerSmall,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.balanced,
    ),
    ModelOffer(
      'ggml-medium.bin', 1463, l10n.offerMedium,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.accurate,
    ),
    ModelOffer(
      'ggml-large-v3-turbo.bin', 1549, l10n.offerLargeV3Turbo,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.fast,
    ),
    ModelOffer(
      'ggml-large-v3.bin', 2952, l10n.offerLargeV3,
      engine: RecognitionEngine.whisperCpp,
      languages: ModelLanguageScope.multilingual,
      focus: ModelFocus.accurate,
    ),
    ModelOffer(
      'nemotron-3.5-asr-streaming-0.6b.q8_0.gguf',
      708,
      l10n.offerNemotron35,
      engine: RecognitionEngine.nemoSpeechCpp,
      languages: ModelLanguageScope.fortyPlus,
      focus: ModelFocus.live,
      sourceUrl:
          '$_nemotron35Repo/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf',
    ),
    ModelOffer(
      'parakeet-tdt-0.6b-v3.q8_0.gguf',
      681,
      l10n.offerParakeetTdt,
      engine: RecognitionEngine.nemoSpeechCpp,
      languages: ModelLanguageScope.european25,
      focus: ModelFocus.fast,
      supportsPrompt: false,
      sourceUrl: '$_parakeetTdtRepo/parakeet-tdt-0.6b-v3.q8_0.gguf',
    ),
  ];
}

/// Есть ли эта модель уже на диске.
///
/// По имени файла, а не по пути: одна и та же модель лежит то в нашей папке,
/// то в общем кеше whisper.cpp — путь каждый раз свой, файл один. Со
/// сравнением путей приложение предлагало скачать полтора гигабайта того,
/// что у человека уже стоит.
bool haveModel(List<String> installed, ModelOffer m) =>
    installed.any((p) => os.basename(p) == m.file);

/// Что из каталога ещё можно загрузить. Пусто — значит есть всё.
List<ModelOffer> modelOffers(List<String> installed) =>
    modelCatalog.where((m) => !haveModel(installed, m)).toList();

/// Загрузка файла с докачкой. Пишем в «.part» рядом и переименовываем только
/// в конце: обрыв на полутора гигабайтах не должен оставить огрызок, который
/// findModels() покажет как готовую модель.
class Download {
  Download(this.url, this.dest, {this.title = ''});

  final String url, dest, title;

  /// Байты: сколько уже есть и сколько всего. Ноль в [total] — сервер
  /// не сказал длину, тогда процент показывать не из чего.
  int got = 0, total = 0;
  bool cancelled = false;

  /// Почему не вышло — человеческими словами, для показа на экране.
  /// Пусто, пока всё идёт хорошо или пока загрузку отменили сами.
  String? error;

  int get percent => total > 0 ? (got * 100 ~/ total).clamp(0, 100) : 0;

  String get progressLabel {
    const mb = 1024 * 1024;
    final done = (got / mb).round();
    final l10n = currentL10n();
    return total > 0
        ? l10n.downloadProgressWithTotal(percent, done, (total / mb).round())
        : l10n.sizeMb(done);
  }

  void cancel() => cancelled = true;

  /// Метка версии файла на сервере (ETag, иначе Last-Modified), сохранённая
  /// рядом с «.part».
  ///
  /// Без неё докачка небезопасна: между двумя заходами файл в репозитории
  /// могли перезалить, и хвост новой версии, дописанный к началу старой,
  /// даёт мусор, который переименовывается в готовую модель. Метка уходит
  /// в `If-Range`: не совпала — сервер сам отдаёт файл целиком, и мы
  /// начинаем сначала.
  File get _tagFile => File('$dest.part.id');

  String? _readTag() {
    try {
      final tag = _tagFile.readAsStringSync().trim();
      return tag.isEmpty ? null : tag;
    } catch (_) {
      return null;
    }
  }

  static String? _tagOf(HttpHeaders headers) =>
      headers.value(HttpHeaders.etagHeader) ??
      headers.value(HttpHeaders.lastModifiedHeader);

  void _forgetPart(File part) {
    try {
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
    try {
      if (_tagFile.existsSync()) _tagFile.deleteSync();
    } catch (_) {}
  }

  /// Возвращает путь к готовому файлу или null: отменили, оборвалось,
  /// сервер ответил не тем. Недокачанное остаётся в «.part» — следующий
  /// заход продолжит с того же места, если файл на сервере тот же.
  Future<String?> run({void Function()? onProgress}) async {
    if (File(dest).existsSync()) return dest;
    error = null;
    final uri = Uri.parse(url);
    final part = File('$dest.part');
    try {
      part.parent.createSync(recursive: true);
    } catch (_) {
      error = currentL10n().downloadNoFolder(part.parent.path);
      return null;
    }

    // Продолжаем только то, у чего есть метка версии. Огрызок без метки
    // достался от старой сборки или от оборванной записи — начинаем заново.
    var have = part.existsSync() ? part.lengthSync() : 0;
    var tag = have > 0 ? _readTag() : null;
    if (have > 0 && tag == null) {
      _forgetPart(part);
      have = 0;
    }

    final client = HttpClient()
      // Без таймаутов повисшее соединение висит вечно, и единственный
      // признак беды — что счётчик мегабайт перестал расти.
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(uri);
      if (have > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        req.headers.set(HttpHeaders.ifRangeHeader, tag!);
      }
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        error = currentL10n().downloadHostResponded(uri.host, res.statusCode);
        return null;
      }
      // Полный ответ вместо куска значит одно из двух: докачку не поняли
      // или файл на сервере сменился. И там и там начинаем сначала —
      // дороже, но верно.
      if (res.statusCode == HttpStatus.ok) have = 0;
      tag = _tagOf(res.headers) ?? tag;
      got = have;
      total = res.contentLength > 0 ? have + res.contentLength : 0;

      final sink = part.openSync(mode: have > 0 ? FileMode.append : FileMode.write);
      var shown = -1;
      try {
        // Метку пишем до первого байта: оборвись загрузка сразу, «.part»
        // без метки следующий заход просто выбросит.
        if (tag != null) {
          try {
            _tagFile.writeAsStringSync(tag);
          } catch (_) {}
        }
        await for (final chunk in res) {
          if (cancelled) return null;
          sink.writeFromSync(chunk);
          got += chunk.length;
          // Кусок приходит десятками килобайт: на полутора гигабайтах это
          // двадцать тысяч перерисовок. Дёргаем экран только на новом проценте.
          if (percent != shown) {
            shown = percent;
            onProgress?.call();
          }
        }
      } finally {
        sink.closeSync();
      }
      if (total > 0 && got < total) {
        error = currentL10n().downloadInterrupted(percent);
        return null;
      }
      part.renameSync(dest);
      try {
        if (_tagFile.existsSync()) _tagFile.deleteSync();
      } catch (_) {}
      return dest;
    } catch (e) {
      // Текст исключения показывать нельзя: он английский и про сокеты.
      // Человеку важно другое — сеть или сервер, и что делать дальше.
      error = e is SocketException
          ? currentL10n().downloadNoConnection(uri.host)
          : currentL10n().downloadFailedGeneric(uri.host);
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
