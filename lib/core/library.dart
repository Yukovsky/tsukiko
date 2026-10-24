import 'dart:convert';
import 'dart:io';

import '../platform/os.dart';
import 'recognition.dart';

/// Где лежат файлы приложения и куда ложатся готовые расшифровки:
/// раскладка по месяцам и выбор свободного имени.

String get home => os.home;

String get supportDir => os.supportDir;

/// Библиотека расшифровок — обычная папка, которую видно в проводнике.
String get defaultLibraryPath => os.defaultLibraryPath;

/// Расшифровки, которые приложение умеет открывать — и через диалог,
/// и перетаскиванием, и из обзора библиотеки.
const transcriptExt = {'.txt', '.srt', '.vtt', '.json', '.md'};

/// Запасная копия подсказок. Лежит в библиотеке нарочно — установщик
/// её не трогает, — но расшифровкой от этого не становится, и в обзоре
/// прошлых расшифровок ей делать нечего.
const promptsFileName = 'prompts.json';

String monthFolder(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}';

/// Куда и под каким именем лечь файлам одной записи.
class Placement {
  const Placement(this.dir, this.stem);
  final String dir, stem;

  String pathFor(String ext) => os.join(dir, '$stem$ext');
}

String _free(String path, bool Function(String) taken) {
  if (!taken(path)) return path;
  final slash = path.lastIndexOf(Platform.pathSeparator);
  final dotAt = path.lastIndexOf('.');
  final hasExt = dotAt > slash;
  final head = hasExt ? path.substring(0, dotAt) : path;
  final ext = hasExt ? path.substring(dotAt) : '';
  for (var n = 2; n < 1000; n++) {
    final candidate = '$head $n$ext';
    if (!taken(candidate)) return candidate;
  }
  return '$head ${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// Один формат — файл лежит прямо в папке месяца. Форматов несколько —
/// у записи появляется своя папка, иначе месяц превращается в свалку.
Placement planPlacement({
  required String root,
  required String stem,
  required int formatCount,
  DateTime? now,
}) {
  final month = os.join(root, monthFolder(now ?? DateTime.now()));
  if (formatCount > 1) {
    final dir = _free(os.join(month, stem), (p) => Directory(p).existsSync());
    return Placement(dir, stem);
  }
  return Placement(month, stem);
}

/// Свободное имя внутри папки: «Запись 2.txt», если «Запись.txt» уже занято.
String freeStem(String dir, String stem, String ext) =>
    freeStemFor(dir, stem, [ext]);

/// То же для набора форматов сразу: имя выбирается такое, при котором
/// ни один из [suffixes] не ляжет поверх чужого файла.
///
/// Отдельной функции здесь быть не должно бы, но проверять каждый формат
/// по очереди нельзя: «Запись.txt» свободно, «Запись.srt» занято — и
/// экспорт двух форматов затирал бы субтитры, оставляя текст рядом.
String freeStemFor(String dir, String stem, List<String> suffixes) {
  // Расширение первого формата нужно только чтобы отрезать его от готового
  // имени: _free приписывает номер к основе, а не к концу строки.
  final ext = suffixes.first;
  final path = _free(
    os.join(dir, '$stem$ext'),
    (p) {
      final base = p.substring(0, p.length - ext.length);
      return suffixes.any((s) => File('$base$s').existsSync());
    },
  );
  final name = os.basename(path);
  return name.substring(0, name.length - ext.length);
}

/// Одна расшифровка в библиотеке — файл на диске и то, что о нём видно
/// не открывая.
class LibraryEntry {
  const LibraryEntry(this.path, this.at, this.bytes);

  final String path;
  final DateTime at;
  final int bytes;

  String get name => os.basename(path);

  /// Папка, в которой файл лежит, — относительно корня библиотеки.
  /// Это либо месяц («2026-09»), либо месяц и папка записи, когда
  /// форматов было несколько.
  String folderIn(String root) {
    final dir = os.dirname(path);
    if (!dir.startsWith(root)) return dir;
    final rest = dir.substring(root.length);
    return rest.startsWith(Platform.pathSeparator) ? rest.substring(1) : rest;
  }
}

/// Всё, что библиотека накопила, — новое сверху.
///
/// Читаем с диска, а не из своего файла состояния: библиотека и есть
/// хранилище готовых расшифровок, оно переживает и перезапуск, и
/// переустановку, и правится человеком напрямую. Второй список рядом с ним
/// разошёлся бы с делом в тот же день, когда человек переложит папку.
///
/// [limit] — потолок на число строк: библиотека за год это тысячи файлов,
/// а список, в который нельзя вглядеться, всё равно никто не читает.
/// Ищем вглубь на два уровня — ровно так, как раскладывает `planPlacement`:
/// месяц, а внутри него папка записи, когда форматов было несколько.
List<LibraryEntry> scanLibrary(String root, {int limit = 300}) {
  final out = <LibraryEntry>[];

  void take(Directory dir, int depth) {
    final List<FileSystemEntity> items;
    try {
      items = dir.listSync();
    } catch (_) {
      // Нет папки, нет прав, том отвалился — не повод не показать остальное.
      return;
    }
    for (final f in items) {
      if (f is Directory) {
        if (depth > 0) take(f, depth - 1);
        continue;
      }
      if (f is! File) continue;
      final name = os.basename(f.path);
      // Своё хозяйство в списке расшифровок не место: и подсказки,
      // и указатель на записи лежат в библиотеке нарочно, но
      // расшифровками от этого не становятся.
      if (name == promptsFileName || name == Sources.fileName) continue;
      final at = name.lastIndexOf('.');
      if (at < 0 || !transcriptExt.contains(name.substring(at).toLowerCase())) {
        continue;
      }
      try {
        final stat = f.statSync();
        out.add(LibraryEntry(f.path, stat.modified, stat.size));
      } catch (_) {}
    }
  }

  take(Directory(root), 2);
  out.sort((a, b) => b.at.compareTo(a.at));
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// Записать JSON так, чтобы читатель никогда не увидел половину файла.
///
/// Живёт рядом с путями, а не с настройками: пользуются этим и настройки,
/// и подсказки, и указатель на записи, а сама эта строчка про файлы,
/// а не про то, что в них лежит.
void writeJsonAtomically(File target, Map<String, dynamic> data) {
  final tmp = File('${target.path}.tmp');
  final raf = tmp.openSync(mode: FileMode.write);
  try {
    raf.writeStringSync(const JsonEncoder.withIndent('  ').convert(data));
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  tmp.renameSync(target.path);
}

/// Папка спасённых записей — тех, что не стали текстом. Имя знают двое:
/// диктовка кладёт их туда, а поиск переехавшей записи туда заглядывает.
const rescuedFolderName = 'Не распознано';

/// Куда ложатся разговоры, записанные из диктовки («Записать разговор»):
/// их звук — исходник расшифровки, и терять его, как временный файл
/// диктовки, нельзя.
const conversationsFolderName = 'Разговоры';

/// Запись, из которой вышла расшифровка.
///
/// Путь, размер и время: путь отвечает, где она была, а размер и время —
/// та ли это запись. По имени одному верить нельзя: «Диктовка.wav»
/// бывает не одна.
class SourceLink {
  const SourceLink(this.path, this.size, this.at);

  final String path;
  final int size;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'path': path, 'size': size, 'at': at.millisecondsSinceEpoch};

  static SourceLink? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    return SourceLink(
      path,
      (raw['size'] as num?)?.toInt() ?? 0,
      DateTime.fromMillisecondsSinceEpoch((raw['at'] as num?)?.toInt() ?? 0),
    );
  }

  /// Тот ли это файл. Размер сверяем, содержимое — нет: час звука это
  /// сотни мегабайт, а на вопрос «та ли запись» имя с размером отвечают
  /// не хуже.
  bool matches(File f) {
    try {
      return size == 0 || f.lengthSync() == size;
    } catch (_) {
      return false;
    }
  }
}

/// Указатель «расшифровка → запись», один на всю библиотеку.
///
/// Почему не внутри самой расшифровки: у неё шесть форматов, и txt с srt
/// от лишней строки испортятся. Почему не файлом-спутником рядом: папку
/// с расшифровками человек открывает в проводнике, и половина файлов
/// в ней была бы служебной. Остаётся один указатель на библиотеку —
/// тем же способом и в том же месте, где лежат подсказки.
///
/// Ключ — путь расшифровки относительно корня библиотеки: переложили
/// библиотеку целиком, и связи остались целы.
class Sources {
  Sources._();

  static const fileName = 'sources.json';

  static File _file(String root) => File(os.join(root, fileName));

  static Map<String, dynamic> _load(String root) {
    try {
      return jsonDecode(_file(root).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static String _key(String root, String transcriptPath) {
    if (!transcriptPath.startsWith(root)) return transcriptPath;
    final rest = transcriptPath.substring(root.length);
    return rest.startsWith(Platform.pathSeparator) ? rest.substring(1) : rest;
  }

  static SourceLink? of(String root, String transcriptPath) =>
      SourceLink.fromJson(_load(root)[_key(root, transcriptPath)]);

  /// Все уже сохранённые форматы этой записи, новые сверху.
  ///
  /// Путь — главный признак. Если запись перенесли, узнаём её так же,
  /// как [locate]: имя, размер и время файла должны совпасть. Одного
  /// размера мало: две минутные диктовки легко могут весить одинаково.
  static List<String> transcriptsFor(String root, String audio) {
    final file = File(audio);
    if (!file.existsSync()) return const [];
    final targetPath = _comparablePath(file.absolute.path);
    final targetName = os.basename(audio);
    final targetSize = file.lengthSync();
    final targetAt = file.lastModifiedSync().millisecondsSinceEpoch;
    final found = <String>[];
    for (final entry in _load(root).entries) {
      final link = SourceLink.fromJson(entry.value);
      if (link == null) continue;
      final exact = _comparablePath(File(link.path).absolute.path) == targetPath;
      final moved = os.basename(link.path) == targetName &&
          link.size == targetSize &&
          link.at.millisecondsSinceEpoch == targetAt;
      if (!exact && !moved) continue;
      final path = File(entry.key).isAbsolute
          ? entry.key
          : os.join(root, entry.key);
      if (File(path).existsSync()) found.add(path);
    }
    found.sort((a, b) =>
        File(b).lastModifiedSync().compareTo(File(a).lastModifiedSync()));
    return found;
  }

  static String _comparablePath(String path) => os.platformId == 'windows'
      ? path.replaceAll('/', r'\').toLowerCase()
      : path;

  /// Запомнить, из какой записи вышли эти файлы.
  ///
  /// Списком, а не по одному: у одной записи бывает шесть форматов, и все
  /// они про один и тот же звук.
  static void remember(String root, Iterable<String> transcripts, String audio) {
    try {
      final f = File(audio);
      if (!f.existsSync()) return;
      final link = SourceLink(audio, f.lengthSync(), f.lastModifiedSync());
      final was = _load(root);
      for (final t in transcripts) {
        was[_key(root, t)] = link.toJson();
      }
      Directory(root).createSync(recursive: true);
      writeJsonAtomically(_file(root), was);
    } catch (e) {
      stderr.writeln('tsukiko: связь расшифровки с записью не сохранилась — $e');
    }
  }

  /// Где запись лежит сейчас, если она вообще жива.
  ///
  /// Сначала там, где была. Потом — с тем же именем и размером в двух
  /// местах, куда её могли переложить: рядом с расшифровкой и в папке
  /// спасённых записей. Дальше не ищем: обход диска ради одной строки
  /// в окне это минуты работы и обещание, которое не всегда выполнимо.
  static String? locate(String root, SourceLink link, String transcriptPath) {
    final was = File(link.path);
    if (was.existsSync() && link.matches(was)) return link.path;

    final name = os.basename(link.path);
    for (final dir in [os.dirname(transcriptPath), os.join(root, rescuedFolderName)]) {
      final candidate = File(os.join(dir, name));
      if (candidate.existsSync() && link.matches(candidate)) return candidate.path;
    }
    return null;
  }
}

/// Есть ли в WAV хоть один отсчёт.
///
/// Пустая запись — это не «плохой файл», а ничего: заголовок на четыре
/// килобайта и нулевой кусок `data`. `AVAudioRecorder` оставляет такой,
/// когда запись остановили раньше, чем микрофон отдал первый отсчёт.
///
/// Отличать это обязательно, потому что дальше по дороге разницы уже
/// не видно. Движок на таком файле говорит «failed to read the frames
/// of the audio data (Invalid argument)» и валит следом полтора экрана
/// про тензоры и Metal — по этому человеку не понять ни что случилось,
/// ни что делать. А случилось ровно одно: сказать ничего не успели.
///
/// Не RIFF — не наше дело: m4a, mp3 и прочее разбирает движок сам,
/// и «не знаю» здесь честнее выдуманного ответа.
bool wavHasAudio(String path) {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    final head = raf.readSync(12);
    if (head.length < 12) return false;
    if (String.fromCharCodes(head.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(head.sublist(8, 12)) != 'WAVE') {
      return true;
    }
    var at = 12;
    final end = raf.lengthSync();
    while (at + 8 <= end) {
      raf.setPositionSync(at);
      final header = raf.readSync(8);
      if (header.length < 8) break;
      final id = String.fromCharCodes(header.sublist(0, 4));
      final size = header[4] | header[5] << 8 | header[6] << 16 | header[7] << 24;
      if (id == 'data') return size > 0;
      // Куски выравниваются по чётной границе — нечётный длиной
      // дополняется байтом, который в его размер не входит.
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    return false;
  } catch (_) {
    return true;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

/// Показать файл в проводнике системы. Возвращает false, если показывать
/// нечего: файл убрали мимо приложения.
///
/// [createIfMissing] — только для папки библиотеки: её человек может ещё
/// ни разу не наполнить, и «показать» разумно понимать как «заведи и
/// покажи». Ко всему остальному это не относится: создавать файл, который
/// пропал, значит показывать подделку вместо него.
Future<bool> revealInFinder(String path, {bool createIfMissing = false}) async {
  if (createIfMissing && !Directory(path).existsSync()) {
    try {
      Directory(path).createSync(recursive: true);
    } catch (_) {}
  }
  return os.reveal(path);
}

/// Имена движка. Они же — имена процессов в «Мониторинге системы»:
/// гигабайт памяти должен числиться за понятным именем, а не за
/// безымянным whisper-cli, про который не скажешь, чей он.
const recognizerExeName = 'tsukiko-recognizer';
const dictationExeName = 'tsukiko-dictation';
const nemoSpeechExeName = 'nemo-speech';

/// Свой движок — тот, что лежит внутри самого приложения.
///
/// Он главнее системного, и это не гордость, а совместимость: мы передаём
/// модели флаги, которых в старых сборках whisper.cpp нет вовсе (`--vad`,
/// `-mc`, `--carry-initial-prompt`). На чужой сборке распознавание либо
/// падает, либо молча работает хуже — а какая она у человека, мы не знаем.
///
/// Заодно отсюда следует, что приложение нечем сломать снаружи: снесённый
/// Homebrew на него не влияет, потому что своего движка он не касается.
/// И наоборот — чужой мы не ставим, не правим и не удаляем.
String? bundledEngine(String name) {
  // Где именно движок лежит внутри приложения, знает только граница
  // системы: у macOS и Windows это разные места.
  // Какие сборки бывают и какая из них годится этой машине — знает
  // граница системы. Здесь только «первая, которая нашлась и ещё
  // не показала себя нерабочей».
  for (final candidate in os.engineNames(name)) {
    final path = os.join(os.engineDir, candidate);
    if (_deadEngines.contains(path)) continue;
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Сборки движка, которые на этой машине не запускаются.
///
/// Проверять сборку файлом мало. На Windows их две — с Vulkan и без, — и
/// Vulkan-сборка падает не только там, где нет `vulkan-1.dll`: сломанный
/// или слишком старый драйвер видеокарты роняет `ggml_vk_instance_init`
/// изнутри, до первой нашей строчки. Снаружи это выглядит так: процесс
/// поднялся и умер, модель в память не попала, код возврата ненулевой —
/// и так на каждой записи подряд.
///
/// Поэтому запуск и есть проверка: не поднялась — вычёркиваем эту сборку
/// на весь сеанс и берём следующую по списку (процессорную). Помнить
/// дольше сеанса незачем: драйвер могли и починить, а лишний файл
/// с памятью о неудаче — это ещё одно место, где что-то протухает.
final _deadEngines = <String>{};

/// Эта сборка движка не запустилась — больше её не предлагать.
///
/// Возвращает true, если после вычёркивания есть чем заменить, — тогда
/// зовущему есть смысл попробовать ещё раз тем же вызовом.
bool engineFailedToStart(String path, String name) {
  _deadEngines.add(path);
  return bundledEngine(name) != null;
}

/// Забыть вычеркнутое. Нужно только тестам: в приложении сеанс один.
void forgetDeadEngines() => _deadEngines.clear();

/// Путь, который чужая программа на этой системе всё равно не откроет.
///
/// Короткие имена Windows чинят кириллицу в пути (см. `Os.processPath`),
/// но их создание можно на томе отключить — `fsutil 8dot3name query`, —
/// и тогда Windows молча отдаёт длинный путь. Чужую модель мы перекладывать
/// не вправе, а человеку гадать не по чему: движок скажет только
/// «failed to open». Значит надо сказать прямо.
bool pathBeyondEngine(String path) =>
    path.isNotEmpty && os.processPath(path).codeUnits.any((c) => c > 127);

String? findWhisper() =>
    bundledEngine(recognizerExeName) ?? os.findExecutable('whisper-cli');

String? findNemoSpeech() =>
    bundledEngine(nemoSpeechExeName) ?? os.findExecutable(nemoSpeechExeName);

String recognitionExecutableName(RecognitionEngine engine) => switch (engine) {
      RecognitionEngine.whisperCpp => recognizerExeName,
      RecognitionEngine.nemoSpeechCpp => nemoSpeechExeName,
    };

String? findRecognitionEngine(RecognitionEngine engine) => switch (engine) {
      RecognitionEngine.whisperCpp => findWhisper(),
      RecognitionEngine.nemoSpeechCpp => findNemoSpeech(),
    };

bool get anyRecognitionEngineFound =>
    findWhisper() != null || findNemoSpeech() != null;

/// Работаем на своём движке, а не на системном. Разница видна человеку
/// в одной строке — и она честная: на чужой сборке мы за поведение
/// не отвечаем.
bool get engineIsOurs => bundledEngine(recognizerExeName) != null;

bool recognitionEngineIsOurs(RecognitionEngine engine) =>
    bundledEngine(recognitionExecutableName(engine)) != null;

/// Имя, под которым движок работает у нас.
///
/// В «Мониторинге системы» гигабайт памяти числился за `whisper-cli`, и по
/// этой строке нельзя было понять, чей он: tsukiko поднял или соседняя
/// программа на том же whisper.cpp. Спрашивают об этом ровно тогда, когда
/// память кончается, — то есть когда разбираться некогда.
///
/// Ссылка, а не копия: копия теряет свои библиотеки (они ищутся рядом
/// с самим файлом) и ломает подпись, а по ссылке система запускает тот же
/// бинарник и называет процесс её именем.
String? runnableEngine(String? exe, String as) {
  if (exe == null) return null;
  // Свой уже назван как надо (в том числе с .exe или суффиксами на Windows) — ссылка ни к чему.
  final base = os.basename(exe);
  if (base == as || base == '$as.exe' || base.startsWith('$as-')) return exe;
  try {
    final dir = Directory(os.join(os.supportDir, 'bin'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final link = Link(os.join(dir.path, as));
    // Движок могли обновить или переставить — ссылка обязана вести туда же,
    // куда ведёт поиск, иначе запустится вчерашний.
    if (link.existsSync()) {
      if (link.targetSync() == exe) return link.path;
      link.deleteSync();
    }
    link.createSync(exe);
    return link.path;
  } catch (e) {
    // Не вышло — работаем под чужим именем: имя в мониторе не стоит
    // того, чтобы из-за него не считалось вовсе.
    stderr.writeln('tsukiko: ссылка на движок не создалась — $e');
    return exe;
  }
}

String? runnableWhisper(String? exe, String as) => runnableEngine(exe, as);
