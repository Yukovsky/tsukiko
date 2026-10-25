import 'dart:convert';
import 'dart:io';

import '../core/library.dart';
import '../core/recognition.dart';
import '../core/text_commands.dart';
import '../core/transcript.dart';
import '../core/vocabulary.dart';
import '../core/whisper.dart';
import '../platform/os.dart';

/// `tsukiko-transcribe` — расшифровка без приложения.
///
/// Главный путь для всего, что не человек с мышью: скрипта, соседней
/// программы, нейросетевого агента. Требовать ради одного голосового
/// сообщения запустить окно с котом — нелепо: агенту нужен текст, а не
/// интерфейс.
///
/// Поэтому это отдельная программа без единого пикселя интерфейса,
/// собранная `dart compile exe`. Flutter в неё не входит — и не может:
/// `dart compile exe` не соберёт ничего, что тянет `package:flutter`.
/// Ради этого из `whisper.dart`, `transcript.dart` и границы системы
/// вынесены все подписи (см. `core/labels.dart`): считающее осталось
/// там, произносимое уехало туда.
///
/// Движок, аргументы командной строки, разбор ответа и сборка форматов
/// у неё те же самые файлы, что и у приложения. Второй реализации
/// расшифровки в проекте нет — иначе флаги вроде `-mc 0` и
/// `--carry-initial-prompt`, за которыми стоят разобранные задачи,
/// разошлись бы между двумя копиями.
///
/// ## Две модели в памяти разом
///
/// Правило приложения — модель в полтора гигабайта в памяти одна —
/// действует и здесь, и снаружи оно труднее: эта программа не видит,
/// чем занято приложение. Поэтому два механизма.
///
/// **Отдать работу очереди.** Если приложение работает и его местное API
/// включено, расшифровка уходит туда: файл встаёт в ту же очередь, что
/// и брошенный в окно, и все правила уступки достаются даром. Своей
/// модели мы при этом не поднимаем вовсе.
///
/// **Иначе — уступать по процессам.** Приложение называет свой движок
/// `tsukiko-recognizer` и `tsukiko-dictation` (`library.dart`), и по этим
/// именам его видно в списке процессов. Пока хоть один жив, мы не
/// начинаем: он держит модель. А если диктовка началась посреди нашего
/// счёта — гасим свой процесс и досчитываем с той же секунды (`-ot`),
/// ровно как это делает очередь.

const _usage = '''
tsukiko-transcribe — расшифровка аудио на месте, без окна приложения.

  tsukiko-transcribe [ключи] <файл>
  tsukiko-transcribe --status

Ключи:
  --format <txt|txt-ts|srt|vtt|md|json>  что печатать (по умолчанию txt)
  --lang <ru|en|auto>                    язык речи (по умолчанию из настроек)
  --model <путь>                         файл модели (по умолчанию из настроек)
  --prompt <текст>                       подсказка модели / ключевые слова
  --speakers                             подписать, кто говорит, до восьми
                                         голосов (нужно запущенное приложение
                                         с API)
  --json                                 ответ целиком в JSON, а не голым текстом
  --quiet                                не писать ход работы в stderr
  --status                               что установлено и готово ли к работе
  --help

Текст уходит в stdout, ход работы и жалобы — в stderr. Код возврата 0 —
получилось, 1 — нет.
''';

/// Разобранная командная строка. Свой разбор, а не `package:args`:
/// ключей семь, а зависимость в программе, которую агент запускает
/// у себя, — это цепочка поставки, которую придётся кому-то доверять.
class Args {
  final files = <String>[];
  String format = 'txt', lang = '', model = '', prompt = '';

  /// «Несколько голосов». Сколько их, модель решает сама.
  bool speakers = false;
  bool json = false, quiet = false, status = false, help = false;
  String? problem;
}

Args parseArgs(List<String> argv) {
  final a = Args();
  for (var i = 0; i < argv.length; i++) {
    final it = argv[i];
    String next() =>
        i + 1 < argv.length ? argv[++i] : (a.problem ??= 'у $it нет значения');
    switch (it) {
      case '--format':
        a.format = next();
      case '--lang':
        a.lang = next();
      case '--model':
        a.model = next();
      case '--prompt':
        a.prompt = next();
      case '--speakers':
        a.speakers = true;
        // Первая версия ключа ждала «auto» или число. «auto» по-прежнему
        // принимаем молча; число задать больше нечем — модель находит
        // голоса сама, и обещать «ровно трёх» было бы неправдой.
        if (i + 1 < argv.length && argv[i + 1] == 'auto') {
          i++;
        } else if (i + 1 < argv.length && int.tryParse(argv[i + 1]) != null) {
          a.problem ??= '--speakers без числа: голоса модель находит сама';
        }
      case '--json':
        a.json = true;
      case '--quiet':
        a.quiet = true;
      case '--status':
        a.status = true;
      case '--help' || '-h':
        a.help = true;
      default:
        if (it.startsWith('-')) {
          a.problem ??= 'незнакомый ключ $it';
        } else {
          a.files.add(it);
        }
    }
  }
  if (!a.status && !a.help && a.files.isEmpty) {
    a.problem ??= 'не сказано, какой файл расшифровывать';
  }
  if (a.files.length > 1) {
    a.problem ??= 'за раз расшифровывается один файл';
  }
  if (!exportFormats.any((f) => f.id == a.format)) {
    a.problem ??= 'нет формата «${a.format}»';
  }
  return a;
}

/// Настройки приложения. Читаем напрямую, а не через `core/settings.dart`:
/// тому нужен `dart:ui` ради очереди записи между изолятами приложения,
/// а изолят здесь один и писать мы ничего не собираемся.
Map<String, dynamic> readSettings() {
  try {
    return jsonDecode(
            File(os.join(os.supportDir, 'settings.json')).readAsStringSync())
        as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

/// Первая попавшаяся модель в нашей папке — на случай, когда приложение
/// ещё ни разу не открывали и выбирать было некому. Модель распознавания
/// пауз речью не занимается, её пропускаем.
String? _anyModel() {
  try {
    final found = Directory(os.modelsDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) {
          final lower = p.toLowerCase();
          return lower.endsWith('.gguf') ||
              (lower.endsWith('.bin') && !lower.contains('silero'));
        })
        .toList()
      ..sort();
    return found.firstOrNull;
  } catch (_) {
    return null;
  }
}

RunOptions optionsFrom(Args a) {
  final s = readSettings();
  var o = RunOptions.fromJson(
    s,
    RunOptions(
      model: _anyModel() ?? '',
      lang: 'auto',
      threads: (Platform.numberOfProcessors ~/ 2).clamp(2, 16),
    ),
  );
  if (o.model.isEmpty || !File(o.model).existsSync()) {
    o = o.copyWith(model: _anyModel() ?? o.model);
  }
  if (a.lang.isNotEmpty) o = o.copyWith(lang: a.lang);
  if (a.model.isNotEmpty) o = o.copyWith(model: a.model);
  if (a.prompt.isNotEmpty) {
    o = o.copyWith(
      prompt: o.prompt.isEmpty ? a.prompt : '${o.prompt}, ${a.prompt}',
    );
  }
  // Голоса своим ходом не размечаются (см. [run]): галка из настроек
  // приложения здесь только просила бы у движка лишний полный JSON.
  return o.copyWith(diarize: false);
}

/// Что установлено и готово ли оно к работе — для того, кто зовёт эту
/// программу впервые и должен понять, чего не хватает.
Future<Map<String, Object?>> status() async {
  final o = optionsFrom(Args());
  final engineKind = engineForModel(o.model);
  final engine = findRecognitionEngine(engineKind);
  final s = readSettings();
  final port = (s['apiPort'] as int?) ?? 8756;
  return {
    'app': appName,
    'version': appVersion,
    'engine': engine,
    'engineKind': engineTechnicalName(engineKind),
    'model': o.model,
    'modelExists': o.model.isNotEmpty && File(o.model).existsSync(),
    'language': o.lang,
    'formats': [for (final f in exportFormats) f.id],
    // Приложение может работать рядом. Если работает и API включено,
    // расшифровка уйдёт туда — и это не помеха, а лучший из путей.
    'appApi': await _liveApi(s, port) != null,
    'apiPort': port,
    'busy': (await busyEngines()).isNotEmpty,
    'ready': engine != null && o.model.isNotEmpty && File(o.model).existsSync(),
  };
}

// ── уступка модели ──────────────────────────────────────────────────────────

/// Процессы движка, которые сейчас держат модель. Свой ребёнок [mine]
/// в счёт не идёт.
Future<List<int>> busyEngines({int? mine}) async {
  try {
    return [
      for (final p in await os.listProcesses())
        if (p.pid != mine &&
            p.pid != pid &&
            (p.args.contains(recognizerExeName) ||
                p.args.contains(dictationExeName) ||
                p.args.contains(nemoSpeechExeName)))
          p.pid,
    ];
  } catch (_) {
    // Не смогли посмотреть процессы — не повод не работать вовсе.
    return const [];
  }
}

/// Дождаться, пока движок освободится. Ждём, а не отказываем: приложение
/// досчитывает свою запись или человек договаривает фразу, и через минуту
/// всё будет свободно. Отказ на этом месте агент истолковал бы как
/// «tsukiko сломан».
Future<void> waitForFreeModel(void Function(String) say) async {
  var said = false;
  while ((await busyEngines()).isNotEmpty) {
    if (!said) {
      said = true;
      say('ждём: модель занята самим tsukiko (расшифровка или диктовка)');
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

// ── путь через живое приложение ─────────────────────────────────────────────

/// Ключ доступа к местному API, если приложение работает и API включено.
/// null — идти своим ходом.
Future<String?> _liveApi(Map<String, dynamic> s, int port) async {
  final key = (s['apiKey'] as String?) ?? '';
  if (((s['apiEnabled'] as bool?) ?? false) == false || key.isEmpty) return null;
  try {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
        timeout: const Duration(milliseconds: 300));
    socket.destroy();
    return key;
  } catch (_) {
    return null;
  }
}

/// Отдать файл живому приложению и дождаться текста.
///
/// Так расшифровка встаёт в ту же очередь, что и брошенная в окно:
/// второй модели не появляется, результат ложится в библиотеку, и
/// человек видит запись в списке — а не гадает, откуда взялся текст.
Future<({String text, List<Object?> speakers})?> _viaApp(
    String key, int port, String file, String format,
    void Function(String) say, {bool speakers = false}) async {
  final client = HttpClient();
  try {
    Future<Map<String, Object?>> call(String method, String path,
        [Object? body]) async {
      final req = await client.open(method, '127.0.0.1', port, path);
      req.headers.set('authorization', 'Bearer $key');
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      final map = jsonDecode(text) as Map<String, Object?>;
      if (res.statusCode >= 400) throw Exception(map['error']);
      return map;
    }

    say('tsukiko работает рядом — отдаём запись его очереди');
    await call('POST', '/transcribe', {
      'file': file,
      if (speakers) 'diarize': true,
    });
    final id = Uri.encodeQueryComponent(file);
    while (true) {
      final r = await call(
          'GET', '/transcribe?id=$id&wait=30&format=$format');
      if (r['done'] == true) {
        return (
          text: r['text'] as String,
          speakers: (r['speakers'] as List?) ?? const [],
        );
      }
      if (r['state'] == 'failed' || r['state'] == 'cancelled') {
        throw Exception(r['detail'] ?? 'очередь не справилась с записью');
      }
      say('идёт: ${((r['progress'] as num? ?? 0) * 100).round()}%');
    }
  } finally {
    client.close(force: true);
  }
}

// ── свой ход ────────────────────────────────────────────────────────────────

/// Расшифровать самим. [say] — куда рассказывать о ходе работы.
Future<Transcript> transcribeHere(
    String file, RunOptions o, void Function(String) say) async {
  final engine = engineForModel(o.model);
  final exe = runnableEngine(findRecognitionEngine(engine), recognizerExeName);
  if (exe == null) {
    throw Exception('движок ${engineTechnicalName(engine)} не найден');
  }

  final tmp = await Directory.systemTemp.createTemp(appName);
  final base = os.join(tmp.path, 'run');
  try {
    await waitForFreeModel(say);
    final wav = await os.toWav(file, '$base.wav');
    // Подготовка звука занимает секунды — за это время диктовка могла
    // начаться. Спрашиваем ещё раз вплотную к запуску.
    await waitForFreeModel(say);

    // Собранное по ходу: нужно и для рассказа о работе, и чтобы после
    // вытеснения диктовкой досчитать с той же секунды, а не сначала.
    final live = <Segment>[];
    var from = 0;
    while (true) {
      final args = engine == RecognitionEngine.whisperCpp
          ? buildArgs(o, wav, base, from: from)
          : buildNemoArgs(o, wav, '$base.json');
      final proc = await Process.start(
        exe,
        args,
        environment: await os.engineEnvironment(),
      );
      os.bindToApp(proc.pid);
      var yielded = false;

      void onLine(String line) {
        if (engine == RecognitionEngine.whisperCpp) {
          final seg = parseSegmentLine(line);
          if (seg != null) return live.add(seg);
        }
        final p = RegExp(r'progress\s*=\s*(\d+)%').firstMatch(line);
        if (p != null) say('идёт: ${p.group(1)}%');
      }

      final subs = [
        // systemEncoding, а не UTF-8: движок пишет в трубу байтами
        // однобайтовой кодировки системы (на macOS это тот же UTF-8).
        // Строгий utf8.decoder на них не просто портил текст — он ронял
        // подписку целиком, вместе с процентами и фрагментами.
        proc.stdout
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())
            .listen(onLine),
        proc.stderr
            .transform(systemEncoding.decoder)
            .transform(const LineSplitter())
            .listen(onLine),
      ];
      // Диктовка главнее: часовая запись считается минутами, а говорить
      // хотят посреди. Заметили чужой движок — гасим свой немедленно,
      // память достаётся ему целиком.
      var asking = false;
      final watch = Stream.periodic(const Duration(milliseconds: 400)).listen((_) async {
        if (asking || yielded) return;
        asking = true;
        try {
          if ((await busyEngines(mine: proc.pid)).isEmpty) return;
          yielded = true;
          say('уступаем модель диктовке — досчитаем с того же места');
          proc.kill();
        } finally {
          asking = false;
        }
      });

      final code = await proc.exitCode;
      await watch.cancel();
      for (final s in subs) {
        await s.cancel();
      }

      if (yielded) {
        if (engine == RecognitionEngine.whisperCpp) {
          // Место берём по последнему выданному фрагменту, а не по проценту:
          // процент — оценка, метка фрагмента — факт.
          from = live.isEmpty ? from : live.last.to;
        } else {
          // NeMo пишет единый JSON лишь в конце и не умеет продолжать с
          // миллисекунды. После уступки модели безопасно считает заново.
          from = 0;
        }
        await waitForFreeModel(say);
        continue;
      }
      final out = File('$base.json');
      if (code != 0 || !out.existsSync()) {
        throw Exception('движок не справился с записью (код $code)');
      }
      final json = await out.readAsString();
      final t = engine == RecognitionEngine.whisperCpp
          ? parseWhisperJson(json)
          : parseNemoJson(json);
      // Заход после уступки знает только свою половину записи. Начало
      // осталось в собранном по ходу — оттуда и берём.
      return engine != RecognitionEngine.whisperCpp || from == 0
          ? t
          : Transcript(t.lang, [
              ...live.where((s) => s.from < from),
              ...t.segments,
            ]);
    }
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

// ── точка входа ─────────────────────────────────────────────────────────────

Future<int> run(List<String> argv) async {
  final a = parseArgs(argv);
  if (a.help) {
    stdout.write(_usage);
    return 0;
  }
  if (a.problem != null) {
    stderr.writeln('tsukiko-transcribe: ${a.problem}');
    stderr.write(_usage);
    return 1;
  }
  void say(String line) {
    if (!a.quiet) stderr.writeln('tsukiko: $line');
  }

  if (a.status) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(await status()));
    return 0;
  }

  final file = File(a.files.single);
  if (!file.existsSync()) {
    stderr.writeln('tsukiko-transcribe: файла нет — ${a.files.single}');
    return 1;
  }
  final path = file.absolute.path;
  final format = formatById(a.format);

  try {
    final s = readSettings();
    final port = (s['apiPort'] as int?) ?? 8756;
    final key = await _liveApi(s, port);
    // Разметку голосов и её сведение с текстом делает очередь
    // приложения — своей копии этого шага в программе нет. Поэтому
    // голоса — только через работающее приложение.
    if (a.speakers && key == null) {
      throw Exception(
          'для --speakers нужно запущенное приложение tsukiko с включённым '
          'местным API (Настройки → Приложение)');
    }
    final via = key != null
        ? await _viaApp(key, port, path, format.id, say, speakers: a.speakers)
        : null;
    final text = via?.text ??
        renderAs(format, await _own(path, a, say), name: os.basename(path));
    stdout.write(a.json
        ? const JsonEncoder.withIndent('  ').convert({
            'file': path,
            'format': format.id,
            'text': text,
            if (via != null && via.speakers.isNotEmpty) 'speakers': via.speakers,
          })
        : text);
    if (!a.json && !text.endsWith('\n')) stdout.writeln();
    return 0;
  } catch (e) {
    final message = e is Exception ? '$e'.replaceFirst('Exception: ', '') : '$e';
    stderr.writeln('tsukiko-transcribe: $message');
    if (a.json) {
      stdout.writeln(jsonEncode({'file': path, 'error': message}));
    }
    return 1;
  }
}

Future<Transcript> _own(String path, Args a, void Function(String) say) async {
  final s = readSettings();
  final vocab = loadAndMigrateVocabulary(s);
  final vocabEnabled = (s['vocabularyTranscriberEnabled'] as bool?) ??
      (s[transcriberCommandsEnabledSetting] as bool?) ??
      true;

  var o = optionsFrom(a);
  if (o.model.isEmpty || !File(o.model).existsSync()) {
    throw Exception(
        'нет модели. Откройте tsukiko и скачайте её в настройках, или укажите файл ключом --model');
  }
  if (vocabEnabled && vocab.isNotEmpty) {
    o = o.copyWith(prompt: promptWithVocabulary(
      o.effectivePrompt,
      vocab,
      maxEstimatedTokens: engineForModel(o.model) == RecognitionEngine.whisperCpp
          ? vocabularyPromptBudget
          : 9999,
    ));
  }
  var t = await transcribeHere(path, o, say);
  if (vocabEnabled && vocab.isNotEmpty) {
    t = t.applyVocabulary(vocab);
  }
  return t;
}
