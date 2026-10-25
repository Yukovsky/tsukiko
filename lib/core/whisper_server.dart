import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../core/app_locale.dart';
import '../core/dictated_text.dart';
import '../core/library.dart';
import '../core/logger.dart';
import '../core/recognition.dart';
import '../core/whisper.dart';
import '../platform/os.dart';
import '../core/settings.dart';

import 'indicator_mode.dart';
export 'indicator_mode.dart';

export 'dictated_text.dart' show tidyDictated;

/// Фоновая диктовка: долгоживущий whisper-server, который держит модель
/// в памяти между фразами, и состояние самой диктовки.
///
/// Ядро замысла — время. Холодный whisper-cli тратит на короткую фразу
/// секунды: почти всё уходит на чтение модели с диска. Сервер читает её
/// один раз, поэтому распознавание фразы занимает около полусекунды.
/// Сервер поднимается в тот момент, когда пользователь начал говорить,
/// и успевает загрузиться, пока фраза не кончилась.

String? findWhisperServer() =>
    bundledEngine(dictationExeName) ?? os.findExecutable('whisper-server');

/// Модель весит гигабайты, поэтому осиротевший сервер — это не «лишний
/// процесс», а полтора гигабайта, которые никто не вернёт. Pid пишется
/// на диск, и следующий запуск добивает того, кто пережил падение.
File get _pidFile => File(os.join(supportDir, 'whisper-server.pid'));

/// Метка своего сервера в аргументах процесса. Нужна затем, что pid-файл
/// теряется: приложение падает, его убивают сигналом, файл стирают — и
/// сервер с полутора гигабайтами становится невидимым навсегда.
/// Аргументы процесса не теряются никогда, поэтому метка живёт в них.
///
/// `--tmp-dir` сервер читает только вместе с `--convert`, которого мы
/// не просим: на поведение метка не влияет, а в списке процессов видна.
///
/// Путь внутри своих же данных, а не `/tmp/…`: на Windows такой папки нет
/// вовсе, а значение должно оставаться похожим на путь — вдруг когда-нибудь
/// сервер начнёт его проверять.
String get serverMark => os.join(supportDir, 'whisper-server-mark');

/// Метка прежних сборок. Только для узнавания: сирота, поднятая старой
/// версией, тоже наша, и оставлять её с полутора гигабайтами нельзя.
const legacyServerMark = '/tmp/tsukiko-whisper';

/// По чему сервер узнаётся нашим. Второй признак — для серверов, поднятых
/// совсем старыми сборками, когда метки ещё не было: путь к нашей модели
/// тишины они передают почти всегда. У чужого whisper-server нет ни одного
/// из этих признаков, и трогать его нельзя.
List<String> get ourServerMarks => [serverMark, legacyServerMark, supportDir];

/// Pid работающего движка расшифровки.
///
/// Тот же приём, что и с сервером диктовки, и по той же причине: движок
/// держит в памяти полтора гигабайта, а живёт он отдельным процессом и
/// смерть приложения переживает. Обычное «Завершить» до Dart не доходит
/// (⌘Q на macOS, снятие задачи на Windows), и погасить ребёнка изнутри
/// уже некому — гасит его родная сторона, а найти его она может только
/// по записанному номеру.
///
/// По имени процесса искать нельзя: под тем же именем работает движок
/// отдельной программы расшифровки (`tsukiko-transcribe`), и гасить чужую
/// начатую работу вместе со своим выходом — потеря чужого часа счёта.
File get _recognizerPidFile => File(os.join(supportDir, 'recognizer.pid'));

void rememberRecognizerPid(int pid) {
  try {
    Directory(supportDir).createSync(recursive: true);
    _recognizerPidFile.writeAsStringSync('$pid');
  } catch (_) {}
}

void forgetRecognizerPid() {
  try {
    if (_recognizerPidFile.existsSync()) _recognizerPidFile.deleteSync();
  } catch (_) {}
}

/// Погасить движок расшифровки, переживший прошлый запуск.
Future<void> sweepRecognizer() async {
  int? recorded;
  try {
    recorded = int.tryParse(_recognizerPidFile.readAsStringSync().trim());
  } catch (_) {}
  if (recorded == null) return;
  if (recorded != pid && processAlive(recorded)) await killForSure(recorded);
  forgetRecognizerPid();
}

bool processAlive(int pid) => os.isAlive(pid);

/// Погасить наверняка. whisper-server на SIGTERM не умирает — проверено:
/// процесс жил часами с 1,7 ГБ, пока приложение считало его выгруженным.
/// Поэтому просим вежливо, ждём, проверяем и добиваем. Возвращает true,
/// если процесса больше нет.
///
/// Асинхронно: ждать приходится до 600 мс, а зовут это и по кнопке
/// «Выгрузить», и по таймеру простоя — то есть прямо из изолята, который
/// рисует панель. Синхронный `sleep` там просто морозил интерфейс.
Future<bool> killForSure(int pid) async {
  Future<bool> gone() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!processAlive(pid)) return true;
    }
    return false;
  }

  os.signal(pid);
  if (await gone()) return true;
  os.signal(pid, force: true);
  return gone();
}

/// Наши серверы среди перечисленных процессов. Чужие whisper-server
/// в список не попадают: наших меток у них нет.
List<ProcListing> ourServersIn(List<ProcListing> processes) => [
      for (final p in processes)
        // Имя может быть и своим, и родным: под своим сервер работает
        // с этой сборки, а пережить обновление приложения может и тот,
        // что поднят прежней.
        if ((p.args.contains('whisper-server') ||
                p.args.contains(dictationExeName) ||
                p.args.contains(nemoSpeechExeName)) &&
            ourServerMarks.any(p.args.contains))
          p,
    ];

/// Pid, записанный нашим сервером. Просто число из файла: ни живости,
/// ни имени процесса не проверяет.
///
/// Ровно это и нужно тому, кто уже знает, что процесс жив. Опрос занятости
/// получает pid из `ps` и спрашивает лишь «он наш?» — а чтение файла в сотню
/// байт стоит несравнимо меньше, чем запуск ещё одного `ps` дважды в секунду
/// на изоляте, который рисует окно.
int? recordedServerPid() {
  try {
    return int.tryParse(_pidFile.readAsStringSync().trim());
  } catch (_) {
    return null;
  }
}

/// Pid нашего whisper-server, если он жив. Отличать своего от чужого можно
/// только так: у пользователя рядом может работать чужой whisper-server,
/// и по имени процесса они неразличимы. Один и тот же pid система могла
/// успеть отдать другому — поэтому сверяемся с именем процесса.
///
/// Дорого (запуск `ps`), поэтому только для уборки за собой. Для опроса
/// занятости есть [recordedServerPid].
int? ourServerPid() {
  final pid = recordedServerPid();
  if (pid == null) return null;
  return os.isAlive(pid) ? pid : null;
}

/// Подобрать за собой на старте: сервер, переживший прошлый запуск,
/// держит полтора гигабайта и никому уже не отвечает. Ищем по меткам,
/// а не по pid-файлу: файла может не быть вовсе — именно так утечка
/// и становилась невидимой.
///
/// Возвращает, сколько мегабайт вернули: молчаливая потеря такого
/// размера должна становиться видимой человеку.
Future<int> sweepOurServers({Set<int> keep = const {}}) async {
  var freedKb = 0;
  // Заодно и движок расшифровки: он тоже держит модель и тоже переживает
  // падение приложения.
  await sweepRecognizer();
  for (final s in ourServersIn(await os.listProcesses())) {
    if (s.pid == pid || keep.contains(s.pid)) continue;
    if (await killForSure(s.pid)) freedKb += s.rssKb;
  }
  // Запись стираем, только когда за ней никого не осталось: pid живого
  // процесса — единственный способ найти его потом.
  final left = ourServerPid();
  if (left == null || !processAlive(left)) {
    try {
      _pidFile.deleteSync();
    } catch (_) {}
  }
  return freedKb ~/ 1024;
}

/// Насколько старым должен быть временный мусор, чтобы считаться забытым.
/// Час: свои папки этого же запуска трогать нельзя, а очередь может
/// готовить звук в соседнем изоляте прямо сейчас.
const _staleAfter = Duration(hours: 1);

/// Подмести временное от прошлых запусков.
///
/// Два вида мусора. Записи диктовки (`tsukiko-*.wav`) ложатся в корень
/// временной папки и стираются сразу после распознавания. Очередь заводит
/// себе целую папку (`tsukikoXXXXXX/`) и держит в ней подготовленный звук —
/// час записи это больше сотни мегабайт, а удалялась она только в dispose,
/// мимо которого проходит ⌘Q. Пережившее падение и выход остаётся тут
/// навсегда, поэтому подметаем на старте.
/// [where] — только для проверок: функция удаляет файлы, и проверять её
/// на настоящей временной папке разработчика было бы невежливо.
void sweepRecordings({Directory? where}) {
  final now = DateTime.now();
  try {
    for (final f in (where ?? Directory.systemTemp).listSync()) {
      final name = os.basename(f.path);
      try {
        if (f is File && name.startsWith('tsukiko-') && name.endsWith('.wav')) {
          f.deleteSync();
        } else if (f is Directory && name.startsWith(appName)) {
          // По возрасту: папка этого запуска ещё нужна своему окну.
          if (now.difference(f.statSync().modified) > _staleAfter) {
            f.deleteSync(recursive: true);
          }
        }
      } catch (_) {
        // Чужая папка, права, гонка с соседом — не наше дело, идём дальше.
      }
    }
  } catch (_) {}
}

/// Запись, которую не удалось распознать, — единственный экземпляр
/// сказанного, и стирать её нельзя. Уносим из временной папки (её
/// подметает `sweepRecordings`) в библиотеку, откуда файл видно и можно
/// перетащить в очередь. Возвращает путь или null, если и это не вышло.
String? rescueRecording(String path) =>
    _keepRecording(path, rescuedFolderName, 'Диктовка');

/// Разговор, записанный из диктовки, — исходник для очереди: из временной
/// папки он уходит в библиотеку, в «Разговоры». Возвращает путь или null.
String? keepConversation(String path) =>
    _keepRecording(path, conversationsFolderName, 'Разговор');

String? _keepRecording(String path, String folder, String prefix) {
  try {
    final root =
        (Settings.load()['libraryPath'] as String?) ?? defaultLibraryPath;
    final dir = Directory(os.join(root, folder))..createSync(recursive: true);
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final dest = os.join(
        dir.path,
        '$prefix ${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}-${two(t.minute)}-${two(t.second)}.wav');
    File(path).copySync(dest);
    try {
      File(path).deleteSync();
    } catch (_) {}
    return dest;
  } catch (_) {
    return null;
  }
}

/// Свободный порт: занимаем его на мгновение и сразу отпускаем. Между
/// «отпустили» и «занял сервер» есть теоретическая гонка, но выбирает
/// порты ядро, и повторно тот же оно не выдаёт.
Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Аргументы запуска whisper-server. Отдельно от `_start` затем, что
/// проверять их иначе нечем: сервер поднимается один раз и надолго.
/// Доводы для whisper-server. Пути — через `os.processPath` по той же
/// причине, что и в `buildArgs`: с кириллицей в пути движок не откроет
/// ни модель, ни звук (разбор в `os.dart`).
List<String> serverArgs(RunOptions o, int port, {bool noGpu = false}) => [
  '-m', os.processPath(o.model),
  if (noGpu) '-ng',
  '-l', o.lang,
  '-t', '${o.threads}',
  '--host', '127.0.0.1',
  '--port', '$port',
  // Метка своего процесса в аргументах: по ней сирота узнаётся, когда
  // pid-файла уже нет. Сервер читает её только вместе с --convert.
  //
  // Через processPath не идёт нарочно, хотя путь тут и есть. Это не путь,
  // а метка: сервер по ней ничего не открывает, а вот ищем мы её потом
  // в командной строке процесса (`ourServersIn`) — и командную строку
  // Windows отдаёт нам широкой, какой мы её и передали. Сократи мы её
  // здесь — метка перестала бы совпадать сама с собой, и забытый сервер
  // с полутора гигабайтами больше никогда бы не нашёлся.
  '--tmp-dir', serverMark,
  // Речь в диктовке короткая, таймкоды в ней не нужны и только мешают
  // склеивать текст.
  '-nt',
  // Луч, а не жадный поиск. Это и была потеря на длинных записях:
  // whisper-cli по умолчанию идёт лучом (-bs 5 -bo 5), а whisper-server
  // — жадно (-bs -1 -bo 2), и на жадном декодере длинная речь срывается
  // в повторы и обрывы. Измерено на одной и той же модели и записях:
  // 6 с и 2 мин — без разницы, 4 мин — +18% текста, 5,5 мин — +25%,
  // 10,5 мин — +46%, 14,5 мин — +24%. Короткая фраза от этого не
  // медленнее (1,2 с и там, и там), а очередь и так идёт лучом.
  //
  // Только флагами запуска: стратегию сервер выбирает один раз, и те же
  // beam_size/best_of в самом запросе доходят лишь наполовину.
  '-bs', '5', '-bo', '5',
  // То же, что и в очереди: окно не наследует текст предыдущего, иначе
  // повтор кормит сам себя из окна в окно (см. `noLoopArgs`).
  ...noLoopArgs(o),
  // Тот же VAD, что и у очереди: он вырезает тишину до модели, а
  // значит и повод для галлюцинаций.
  if (o.vad && o.vadModel.isNotEmpty)
    ...['--vad', '-vm', os.processPath(o.vadModel)],
  if (o.effectivePrompt.isNotEmpty) ...['--prompt', o.effectivePrompt],
];

/// Аргументы постоянного HTTP-сервера NeMo. Модель загружается один раз,
/// а язык, пунктуация и словарь меняются на каждом запросе.
List<String> nemoServerArgs(RunOptions o, int port) => [
      'serve',
      '--asr-model',
      os.processPath(o.model),
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      '--max-upload-mb',
      '4096',
      '--no-ui',
      '--no-warmup',
      // У Tsukiko один поток диктовки. NeMo-сервер по умолчанию готовит
      // пакетные GPU-графы для 16 одновременных потоков; на RX 570 такая
      // подготовка может занять больше времени, чем загрузка самой модели.
      // Отключение batching заодно убирает ненужное ожидание его очереди.
      '--asr.batching.enabled=false',
      // Безопасное неиспользуемое значение, которое остаётся в командной
      // строке и позволяет отличить наш nemo-speech от чужого.
      '--cors-origin',
      serverMark,
    ];

class WhisperServer {
  WhisperServer({this.idleTimeout = const Duration(minutes: 3), this.onChanged});

  Duration idleTimeout;

  /// Дёргается, когда сервер поднялся или выгрузился, — панели нужно
  /// перерисовать состояние модели.
  void Function()? onChanged;

  Process? _proc;
  int _port = 0;
  String _model = '';
  Timer? _idle;
  DateTime? _deadline;
  Future<void>? _starting;
  Future<void>? _shuttingDown;
  String _lastEngineError = '';
  final Set<String> _cpuFallbackModels = {};
  String get lastEngineError => _lastEngineError;
  final List<String> _startupLog = [];

  /// Незакрытые аренды. Сервер поднимается в начале записи, а работы у него
  /// до конца фразы никакой — таймер простоя успевал догореть и выгружал
  /// модель посреди длинной записи, после чего распознавать было нечем.
  /// Пока аренда открыта, таймер не идёт вовсе.
  int _holds = 0;

  bool get up => _proc != null;
  bool get held => _holds > 0;
  int get port => _port;
  String get model => _model;

  /// Сколько осталось до выгрузки. null — сервер не поднят.
  Duration? get untilUnload {
    final d = _deadline;
    if (_proc == null || d == null) return null;
    final left = d.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Реальная память процесса. `ps -o rss` на macOS занижает всё, что
  /// пришло через mmap; Мониторинг системы показывает phys_footprint,
  /// и в интерфейсе должно стоять то же число.
  Future<int> footprintMb() async {
    final p = _proc;
    if (p == null) return 0;
    try {
      return await os.footprintMb(p.pid);
    } catch (_) {}
    return 0;
  }

  /// Поднять сервер под нужную модель. Возвращает сразу, если он уже
  /// поднят под неё же, — на этом и держится вся скорость.
  ///
  /// Подъёмы выстроены в очередь, а не схлопнуты в один: раньше здесь
  /// стояло `_starting ??= _start(o)`, и запрос под другую модель молча
  /// получал фьючер чужого подъёма — диктовка уходила говорить не в ту
  /// модель, которую у неё попросили.
  Future<void> ensureUp(RunOptions o) async {
    while (_starting != null) {
      try {
        await _starting;
      } catch (_) {}
    }
    if (_proc != null && _sameOptions(_startedWith, o)) {
      _touch();
      return;
    }
    await (_starting = _start(o).whenComplete(() => _starting = null));
  }

  /// Дождаться идущего подъёма. Нужен тем, кто собирается говорить с
  /// сервером: между `shutdown()` внутри `_start` и присвоением `_proc`
  /// сервер выглядит выключенным, хотя он как раз поднимается.
  Future<void> get ready async {
    while (_starting != null) {
      try {
        await _starting;
      } catch (_) {}
    }
  }

  bool _sameOptions(RunOptions? before, RunOptions after) =>
      before != null && jsonEncode(before.toJson()) == jsonEncode(after.toJson());

  Future<void> _start(RunOptions o) async {
    try {
      // Ждём, пока прежний действительно умрёт: два сервера разом — это
      // три гигабайта в памяти и драка за процессор.
      await shutdown();
      final engine = engineForModel(o.model);
      final exe = engine == RecognitionEngine.whisperCpp
          ? findWhisperServer()
          : findNemoSpeech();
      if (exe == null || o.model.isEmpty) return;

      _lastEngineError = '';
      _startupLog.clear();
      _port = await freePort();
      _model = o.model;
      _startedExe = exe;
      _startedWith = o;
      _startedEngineName = engine == RecognitionEngine.whisperCpp
          ? dictationExeName
          : nemoSpeechExeName;
      _engine = engine;
      Log.info(
        'Engine',
        'Starting server: engine=${engineTechnicalName(engine)}, model=${o.model}, port=$_port, exe=$exe',
      );
      final Process proc;
      try {
        proc = await Process.start(
          runnableEngine(exe, _startedEngineName!)!,
          engine == RecognitionEngine.whisperCpp
              ? serverArgs(o, _port,
                  noGpu: _cpuFallbackModels.contains(o.model))
              : nemoServerArgs(o, _port),
          environment: await os.engineEnvironment(),
        );
      } catch (e, st) {
        _lastEngineError = '$e';
        Log.error('Engine', 'Failed to launch server ($exe)', e, st);
        stderr.writeln('tsukiko: не удалось запустить сервер диктовки ($exe) — $e');
        // waitReady увидит пустой процесс и попробует следующую сборку.
        return;
      }
      _proc = proc;
      os.bindToApp(proc.pid);
      Log.info('Engine', 'Server process launched: PID=${proc.pid}');
      // Сохраняем начальный вывод сервера: если процесс завершится со сбоем
      // на старте или во время waitReady, в диагностических логах и
      // _lastEngineError останется причина ошибки.
      void onStartupLine(String line) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty && _startupLog.length < 50) {
          _startupLog.add(trimmed);
        }
      }

      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onStartupLine, onError: (_) {});
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onStartupLine, onError: (_) {});
      proc.exitCode.then((code) {
        if (identical(_proc, proc)) {
          _proc = null;
          _deadline = null;
          if (_startupLog.isNotEmpty) {
            _lastEngineError = _startupLog.join('\n');
          }
          if (code != 0) {
            Log.error(
              'Engine',
              'Server process ($exe) exited with code $code'
              '${_lastEngineError.isNotEmpty ? ': $_lastEngineError' : ''}',
            );
            stderr.writeln(
              'tsukiko: сервер диктовки ($exe) завершился с кодом $code'
              '${_lastEngineError.isNotEmpty ? ':\n$_lastEngineError' : ''}',
            );
          } else {
            Log.info('Engine', 'Server process ($exe) exited cleanly with code 0');
          }
          onChanged?.call();
        }
      });
      try {
        _pidFile.parent.createSync(recursive: true);
        _pidFile.writeAsStringSync('${proc.pid}');
      } catch (_) {}
      _touch();
      onChanged?.call();
    } catch (e, st) {
      _lastEngineError = '$e';
      Log.error('Engine', 'Unexpected error starting server: $e', e, st);
    }
  }

  /// Чем и с чем поднят нынешний сервер. Нужно на случай, если сборка
  /// движка вовсе не запускается: тогда её вычёркивают на весь сеанс,
  /// а сервер поднимают заново — с теми же настройками, а не с чем попало.
  String? _startedExe;
  String? _startedEngineName;
  RunOptions? _startedWith;
  RecognitionEngine? _engine;

  /// Порт открывается только после того, как модель прочитана целиком —
  /// проверено: 0,75 с на прогретом кеше, до 2 с на холодном. Поэтому
  /// «порт отвечает» и есть «модель готова».
  Future<bool> waitReady({Duration timeout = const Duration(minutes: 2)}) async {
    final sw = Stopwatch()..start();
    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      // Процесс умер, не открыв порта. На Windows это чаще всего значит,
      // что Vulkan-сборку убил драйвер видеокарты: вычёркиваем её и
      // поднимаемся заново на процессорной. Без этого диктовка молчала
      // бы на каждой фразе до конца жизни установки.
      if (_proc == null) {
        final dead = _startedExe;
        final engineName = _startedEngineName;
        final options = _startedWith;
        _startedExe = null;
        if (_lastEngineError.isEmpty && _startupLog.isNotEmpty) {
          _lastEngineError = _startupLog.join('\n');
          if (dead != null) {
            stderr.writeln(
              'tsukiko: сервер диктовки ($dead) завершился до открытия порта:\n$_lastEngineError',
            );
          }
        }
        Log.warn(
          'Engine',
          'Server process died before port opened (elapsed: ${sw.elapsedMilliseconds} ms)',
        );
        // macOS иногда обрывает загрузку large-v3 при выделении памяти
        // Metal. Повторяем сохранённую запись на CPU вместо ручного импорта.
        if (Platform.isMacOS &&
            engineName == dictationExeName &&
            options != null &&
            !_cpuFallbackModels.contains(options.model) &&
            _lastEngineError.contains('ggml_metal')) {
          _cpuFallbackModels.add(options.model);
          Log.warn('Engine', 'Metal startup failed; retrying ${options.model} on CPU');
          await ensureUp(options);
          return _proc != null && await waitReady(timeout: timeout);
        }
        if (dead == null ||
            engineName == null ||
            options == null ||
            !engineFailedToStart(dead, engineName)) {
          return false;
        }
        await ensureUp(options);
        return _proc != null && await waitReady(timeout: timeout);
      }
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _port,
            timeout: const Duration(milliseconds: 300));
        s.destroy();
        Log.info(
          'Engine',
          'Server ready on port $_port with PID ${_proc?.pid} (took ${sw.elapsedMilliseconds} ms)',
        );
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    if (_proc != null && _startupLog.isNotEmpty) {
      _lastEngineError = _startupLog.join('\n');
      stderr.writeln(
        'tsukiko: сервер диктовки не ответил за ${timeout.inSeconds} с:\n$_lastEngineError',
      );
    }
    Log.warn(
      'Engine',
      'Server did not respond within ${timeout.inSeconds} s (PID ${_proc?.pid}, port $_port)',
    );
    return false;
  }

  /// Пустая строка — человек промолчал; null — распознать не удалось.
  /// Разница принципиальна: на молчание нечего показывать, а провал должен
  /// быть виден, иначе запись пропадает в тишине.
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async {
    // Сервер поднимается параллельно записи, и короткая фраза успевает
    // кончиться раньше, чем `Process.start` вернёт процесс. Без этого
    // ожидания такая фраза считалась нераспознанной, а запись уезжала
    // в «Не распознано» — при том что сервер поднялся через полсекунды.
    await ready;
    // Раньше здесь стояло `if (_proc == null) return null;` — и это была
    // дыра, из-за которой павшая Vulkan-сборка не вычёркивалась никогда.
    // Она умирает мгновенно, ещё пока человек говорит; к концу записи
    // процесса уже нет, и проверка возвращала «не распознал», не дойдя
    // до [waitReady] — того единственного места, где сборку вычёркивают.
    // Следующая фраза поднимала ту же сборку заново, она снова падала,
    // и Windows писала об этом ещё один отчёт в свой журнал сбоев.
    // Решать, что делать с умершим процессом, должен [waitReady].
    if (!await waitReady()) return null;
    _touch();

    // Тело собирается из трёх частей, и звук в память не читается: час
    // диктовки — это больше сотни мегабайт, которые прежде ложились
    // в BytesBuilder, а затем копировались ещё раз в takeBytes. Длина
    // известна заранее, поэтому файл просто утекает в сокет с диска,
    // и расход памяти перестаёт зависеть от длины записи. Ограничивать
    // длительность ради этого не нужно — а именно так и подмывало сделать.
    const boundary = '----tsukiko-dictation';
    final head = BytesBuilder();
    void field(String name, String value) => head.add(utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n$value\r\n'));
    field('response_format', 'json');
    final engine = _engine ?? RecognitionEngine.whisperCpp;
    Log.info(
      'Engine',
      'Inference request: wav=$wav, lang=$lang, engine=${engineTechnicalName(engine)}',
    );
    if (engine == RecognitionEngine.whisperCpp || lang != 'auto') {
      field('language', lang);
    }
    if (engine == RecognitionEngine.nemoSpeechCpp) {
      final options = _startedWith;
      field('automatic_punctuation', '${options?.punctuate ?? true}');
      final prompt = options?.prompt.trim() ?? '';
      if (prompt.isNotEmpty && recognitionModelSupportsPrompt(_model)) {
        field('prompt', prompt);
      }
    }
    head.add(utf8.encode('--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
        'Content-Type: audio/wav\r\n\r\n'));
    final headBytes = head.takeBytes();
    final tailBytes = utf8.encode('\r\n--$boundary--\r\n');
    final file = File(wav);
    final int audioLength;
    try {
      audioLength = await file.length();
    } catch (e) {
      Log.error('Engine', 'Failed to read audio file length ($wav)', e);
      return null;
    }

    final client = HttpClient();
    final sw = Stopwatch()..start();
    try {
      final path = engine == RecognitionEngine.whisperCpp
          ? '/inference'
          : '/v1/audio/transcriptions';
      final req = await client.post('127.0.0.1', _port, path);
      req.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary');
      // Без явной длины Dart перешёл бы на chunked, а сервер её ждёт.
      req.contentLength = headBytes.length + audioLength + tailBytes.length;
      req.add(headBytes);
      await req.addStream(file.openRead());
      req.add(tailBytes);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final durationMs = sw.elapsedMilliseconds;
      if (res.statusCode != 200) {
        Log.error(
          'Engine',
          'Inference failed with HTTP ${res.statusCode} in ${durationMs}ms',
        );
        return null;
      }
      final data = jsonDecode(text);
      final result = tidyDictated((data is Map ? data['text'] : null)?.toString() ?? '');
      Log.info(
        'Engine',
        'Inference completed in ${durationMs}ms (length: ${result.length} chars)',
      );
      return result;
    } catch (e, st) {
      Log.error('Engine', 'Inference failed after ${sw.elapsedMilliseconds}ms', e, st);
      return null;
    } finally {
      client.close(force: true);
      _touch();
    }
  }

  /// Держать сервер живым безусловно. Освобождать обязательно — иначе
  /// модель останется в памяти навсегда.
  void hold() {
    _holds++;
    _touch();
  }

  void release() {
    if (_holds > 0) _holds--;
    _touch();
  }

  void _touch() {
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    if (_proc == null || _holds > 0) return;
    _deadline = DateTime.now().add(idleTimeout);
    _idle = Timer(idleTimeout, () {
      Log.info('Engine', 'Idle unload timer expired (${idleTimeout.inSeconds}s), shutting down server');
      unawaited(shutdown());
    });
  }

  /// Выгрузить модель. `p.kill()` здесь недостаточно: он шлёт SIGTERM,
  /// а whisper-server от него не умирает — панель писала «Выгружена»,
  /// пока процесс держал полтора гигабайта. Убеждаемся, что он мёртв,
  /// и только тогда забываем о нём.
  ///
  /// Экран обновляется сразу, до ожидания: с точки зрения интерфейса
  /// сервера уже нет, а добивание идёт в фоне и панель не морозит.
  Future<void> shutdown() async {
    while (_shuttingDown != null) {
      try {
        await _shuttingDown;
      } catch (_) {}
    }
    _idle?.cancel();
    _idle = null;
    _deadline = null;
    final p = _proc;
    _proc = null;
    // Мы сами его и погасили — это не «сборка не запускается». Без этой
    // строчки память о запущенном пережила бы выключение по простою,
    // и следующий [waitReady] вычеркнул бы совершенно исправную сборку.
    _startedExe = null;
    _startedEngineName = null;
    _startedWith = null;
    _engine = null;
    _startupLog.clear();
    if (p == null) return;
    Log.info('Engine', 'Server shutdown requested (PID ${p.pid})');
    onChanged?.call();
    return _shuttingDown = _killProcess(p).whenComplete(() => _shuttingDown = null);
  }

  Future<void> _killProcess(Process p) async {
    if (await killForSure(p.pid)) {
      Log.info('Engine', 'Server PID ${p.pid} terminated');
      try {
        if (_proc == null) _pidFile.deleteSync();
      } catch (_) {}
    }
  }
}

// ── хоткеи ──────────────────────────────────────────────────────────────────

/// Сочетание в том виде, в каком его понимают обе стороны моста.
/// Клавиши нет вовсе — значит сочетание из одних модификаторов (fn+ctrl):
/// такое приходит событием flagsChanged, а не нажатием клавиши.
class Hotkey {
  const Hotkey(this.mods, {this.keys = const [], this.taps = 1});

  /// Старые общие имена: 'fn', 'ctrl', 'opt', 'shift', 'cmd'. Новые
  /// позиционные добавляют бок: 'leftctrl', 'rightopt' и так далее.
  /// В этом же виде их читают Swift и Windows-мост.
  final List<String> mods;

  /// Обычные клавиши сочетания. Именно набор, а не одна: годится и «Y»,
  /// и «X+Y», и «fn+O». Раньше клавиша была одна, а в одиночку принимались
  /// только функциональные — обычную букву назначить было нельзя вовсе.
  final List<String> keys;

  /// Сколько раз стукнуть. Двойное нажатие назначается двойным же стуком
  /// при захвате: отдельной галочки для него нет — жест и есть настройка.
  final int taps;

  bool get isDouble => taps >= 2;

  /// Одна физическая клавиша без второго стука и без сочетания забирает
  /// привычное действие у всей системы. Такое назначение допустимо, но
  /// только после отдельного согласия человека в настройках.
  bool get requiresExclusiveConsent =>
      !isDouble && mods.length + keys.length == 1;

  /// Не `const`: у каждой системы своё (см. `Os.defaultHold`), а `const`
  /// про систему знать не может.
  static Hotkey get holdDefault =>
      Hotkey(os.defaultHold.mods, keys: os.defaultHold.keys);
  static Hotkey get toggleDefault =>
      Hotkey(os.defaultToggle.mods, keys: os.defaultToggle.keys);

  /// Умолчания у «бросить» нет намеренно: пустое сочетание значит
  /// «не назначено», и клавиш система не перехватывает вовсе. Отмена —
  /// действие редкое, а каждое занятое сочетание отнимается у чужих
  /// программ навсегда.
  static const none = Hotkey([]);

  bool get empty => mods.isEmpty && keys.isEmpty;

  Map<String, dynamic> toJson() => {'mods': mods, 'keys': keys, 'taps': taps};

  factory Hotkey.fromJson(Object? raw, Hotkey fallback) {
    if (raw is! Map) return fallback;
    final mods = (raw['mods'] as List?)?.map((e) => '$e').toList();
    if (mods == null) return fallback;
    final taps = (raw['taps'] as num?)?.toInt() ?? 1;
    final keys = (raw['keys'] as List?)?.map((e) => '$e').toList();
    if (keys != null) return Hotkey(mods, keys: keys, taps: taps);
    // Настройки прежних сборок: там клавиша была одна.
    final single = raw['key'] as String?;
    return Hotkey(mods, keys: single == null ? const [] : [single], taps: taps);
  }

  /// Как назвать клавишу человеку. Незнакомая приходит своим кодом
  /// («#57») — показываем его же, иначе назначить её было бы можно,
  /// а прочитать назначенное нет.
  ///
  /// Почти все клавиши здесь названы значками, и значок одинаков на любом
  /// языке. Слово всего одно — пробел, и его берём из перевода.
  static const _keyNames = {
    'return': '⏎',
    'enter': '⌤',
    'tab': '⇥',
    'escape': '⎋',
    'delete': '⌫',
    'forwarddelete': '⌦',
    'left': '←',
    'right': '→',
    'up': '↑',
    'down': '↓',
    'home': '↖',
    'end': '↘',
    'pageup': '⇞',
    'pagedown': '⇟',
  };

  static String keyLabel(String key) => key == 'space'
      ? currentL10n().keySpace
      : _keyNames[key] ?? key.toUpperCase();

  /// Сравнение по существу: порядок набора значения не имеет — «X+Y»
  /// и «Y+X» это одно сочетание. Нужно затем, чтобы не дать назначить
  /// одно и то же на два разных действия.
  ///
  /// Число стуков в счёт идёт: одиночное и двойное «fn» — разные жесты,
  /// и держать их на двух действиях можно.
  bool sameAs(Hotkey other) =>
      taps == other.taps &&
      _sameModifierSet(mods, other.mods) &&
      keys.toSet().difference(other.keys.toSet()).isEmpty &&
      other.keys.toSet().difference(keys.toSet()).isEmpty;

  /// Это сочетание лежит на дороге к [other]: чтобы нажать то, надо
  /// пройти через это.
  ///
  /// Клавиши нажимаются по одной, и всякий промежуточный набор система
  /// успевает увидеть. Значит сочетание, целиком входящее в другое,
  /// сработает раньше — и «Ctrl+Alt» на «держать и говорить» вместе
  /// с «Ctrl+Alt+Пробел» на «включить» давали запись, начинавшуюся
  /// до пробела. Хозяин это и описал: «Windows не дожидается пробела,
  /// просто берёт и запускает».
  ///
  /// Двойной стук по дороге не срабатывает: первое нажатие только
  /// взводит, а второго на пути к чужому сочетанию не случится.
  bool isPrefixOf(Hotkey other) =>
      !empty &&
      !isDouble &&
      !sameAs(other) &&
      _modifierSubset(mods, other.mods) &&
      keys.toSet().difference(other.keys.toSet()).isEmpty;

  /// Старое `ctrl` означает «любой Ctrl», а новый `leftctrl` — только
  /// физический левый. Они пересекаются и не должны назначаться двум
  /// действиям как будто это разные сочетания.
  static bool _sameModifierSet(List<String> a, List<String> b) =>
      a.length == b.length && _modifierSubset(a, b) && _modifierSubset(b, a);

  static bool _modifierSubset(List<String> a, List<String> b) => a.every(
        (wanted) => b.any((actual) => _modifiersCanCoincide(wanted, actual)),
      );

  static bool _modifiersCanCoincide(String a, String b) {
    final left = a.toLowerCase();
    final right = b.toLowerCase();
    if (left == right) return true;
    if (_modifierFamily(left) != _modifierFamily(right)) return false;
    // Два явно разных физических бока не совпадают. Общее старое имя
    // остаётся маской любого бока ради настроек прежних версий.
    return !_isSided(left) || !_isSided(right);
  }

  static bool _isSided(String mod) =>
      mod.startsWith('left') || mod.startsWith('right');

  static String _modifierFamily(String mod) {
    var value = mod;
    if (value.startsWith('left')) value = value.substring(4);
    if (value.startsWith('right')) value = value.substring(5);
    return switch (value) {
      'opt' || 'alt' => 'alt',
      'cmd' || 'win' => 'cmd',
      _ => value,
    };
  }

  /// Подпись для панели: «fn + ⌃», «fn + Пробел», «X + Y». Значки
  /// модификаторов рисует система: на macOS это ⌘ и ⌥, на Windows —
  /// слова Ctrl и Alt.
  String get label {
    if (empty) return currentL10n().hotkeyUnassigned;
    // Порядок клавиш наводим сами: захват приходит множеством, и без
    // этого подпись у одного и того же сочетания могла читаться по-разному.
    final named = [...keys.map(keyLabel)]..sort();
    final combo = os.shortcutLabel(mods, named);
    return isDouble ? currentL10n().hotkeyDoubleTap(combo) : combo;
  }
}

/// Режимы завершения фразы при голосовой активации:
/// - [hybrid]: мгновенно по слову завершения, но если пользователь забыл его сказать — через 2 с тишины.
/// - [closeWordOnly]: только по слову завершения (мгновенно, 0 мс).
/// - [silenceOnly]: только по тишине (через 2 с).
enum PhraseCompletionMode {
  hybrid,
  closeWordOnly,
  silenceOnly;

  static PhraseCompletionMode fromString(String? name) {
    if (name == null) return PhraseCompletionMode.hybrid;
    return PhraseCompletionMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => PhraseCompletionMode.hybrid,
    );
  }
}

/// Настройки диктовки лежат отдельно от общих: панель и главное окно —
/// разные изоляты, и одним файлом они затирали бы правки друг друга.
class DictationSettings {
  DictationSettings({
    this.enabled = true,
    this.model = '',
    this.prompt = '',
    Hotkey? hold,
    Hotkey? toggle,
    Hotkey? cancel,
    this.idleSeconds = 180,
    this.insert = true,
    bool hud = true,
    IndicatorMode? indicatorMode,
    this.punctuate = true,
    this.threads = 4,
    this.wakeWordEnabled = false,
    this.wakeWord = 'Джеф',
    this.closeWord = '',
    this.completionMode = PhraseCompletionMode.hybrid,
    this.voiceCalibrationEnabled = false,
    this.speakerProfilePath = '',
    this.speakerThreshold = 0.60,
    this.ownVoiceOnly = false,
    this.ownVoiceThreshold = 0.45,
  })  : indicatorMode = indicatorMode ?? (hud ? IndicatorMode.panel : IndicatorMode.off),
        hold = hold ?? Hotkey.holdDefault,
        toggle = toggle ?? Hotkey.toggleDefault,
        cancel = cancel ?? Hotkey.none;

  bool enabled;

  /// Пусто — берём модель из общих настроек приложения.
  String model;

  /// Подсказка модели своя: диктуют не то же, что расшифровывают.
  String prompt;
  Hotkey hold, toggle;

  /// Бросить начатое, не вставив ни буквы: запись выбрасывается, идущий
  /// счёт прерывается. По умолчанию не назначено — см. [Hotkey.none].
  Hotkey cancel;
  int idleSeconds;

  /// Вставлять готовый текст в активное окно. Выключено — текст только
  /// ложится в буфер обмена.
  bool insert;

  /// Плавающая панель записи поверх всех окон.
  IndicatorMode indicatorMode;
  bool get hud => indicatorMode != IndicatorMode.off;
  set hud(bool value) => indicatorMode = value ? IndicatorMode.panel : IndicatorMode.off;

  /// Дальше — своё распознавание, не общее с очередью: диктуют не то же,
  /// что расшифровывают, и общие значения устраивали бы разом обе стороны
  /// плохо. Языка здесь нет: диктовке он всегда «авто».
  bool punctuate;
  int threads;

  /// Голосовая активация (WakeWord / CloseWord).
  bool wakeWordEnabled;
  String wakeWord;
  String closeWord;
  PhraseCompletionMode completionMode;
  bool voiceCalibrationEnabled;
  String speakerProfilePath;
  double speakerThreshold;

  /// «Только мой голос»: перед распознаванием выбросить из фразы чужую
  /// речь (см. `core/diarization/own_voice.dart`). Без записанного
  /// образца голоса ничего не делает.
  bool ownVoiceOnly;

  /// Порог сходства с образцом голоса. Строже — меньше пропускает чужого,
  /// но чаще режет своё.
  double ownVoiceThreshold;

  static File get _file => File(os.join(supportDir, 'dictation.json'));

  static DictationSettings load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return DictationSettings(
        enabled: (j['enabled'] as bool?) ?? true,
        model: (j['model'] as String?) ?? '',
        // Пусто — берём запасную копию из библиотеки: настройки могли
        // не пережить переустановку, а собранный вручную список слов
        // терять нельзя (см. Prompts).
        prompt: _nonEmpty(j['prompt'] as String?) ?? Prompts.read(Prompts.dictation),
        hold: Hotkey.fromJson(j['hold'], Hotkey.holdDefault),
        toggle: Hotkey.fromJson(j['toggle'], Hotkey.toggleDefault),
        cancel: Hotkey.fromJson(j['cancel'], Hotkey.none),
        idleSeconds: (j['idleSeconds'] as int?) ?? 180,
        insert: (j['insert'] as bool?) ?? true,
        indicatorMode: IndicatorMode.fromValue(j['indicatorMode'], legacyHud: (j['hud'] as bool?) ?? true),
        punctuate: (j['punctuate'] as bool?) ?? true,
        threads: (j['threads'] as int?) ?? 4,
        wakeWordEnabled: (j['wakeWordEnabled'] as bool?) ?? false,
        wakeWord: (j['wakeWord'] as String?) ?? 'Джеф',
        closeWord: (j['closeWord'] as String?) ?? '',
        completionMode: PhraseCompletionMode.fromString(j['completionMode'] as String?),
        voiceCalibrationEnabled: (j['voiceCalibrationEnabled'] as bool?) ?? false,
        speakerProfilePath: (j['speakerProfilePath'] as String?) ?? '',
        speakerThreshold: (j['speakerThreshold'] as num?)?.toDouble() ?? 0.60,
        ownVoiceOnly: (j['ownVoiceOnly'] as bool?) ?? false,
        ownVoiceThreshold:
            (j['ownVoiceThreshold'] as num?)?.toDouble() ?? 0.45,
      );
    } catch (_) {
      return DictationSettings();
    }
  }

  void save() {
    try {
      Directory(supportDir).createSync(recursive: true);
      // Через временный файл и переименование — как и общие настройки:
      // падение посреди записи не должно стирать сочетания клавиш.
      Prompts.write(Prompts.dictation, prompt);
      writeJsonAtomically(_file, {
        'enabled': enabled,
        'model': model,
        'prompt': prompt,
        'hold': hold.toJson(),
        'toggle': toggle.toJson(),
        'cancel': cancel.toJson(),
        'idleSeconds': idleSeconds,
        'insert': insert,
        'hud': hud,
        'indicatorMode': indicatorMode.name,
        'punctuate': punctuate,
        'threads': threads,
        'wakeWordEnabled': wakeWordEnabled,
        'wakeWord': wakeWord,
        'closeWord': closeWord,
        'completionMode': completionMode.name,
        'voiceCalibrationEnabled': voiceCalibrationEnabled,
        'speakerProfilePath': speakerProfilePath,
        'speakerThreshold': speakerThreshold,
        'ownVoiceOnly': ownVoiceOnly,
        'ownVoiceThreshold': ownVoiceThreshold,
      });
    } catch (e) {
      stderr.writeln('tsukiko: не удалось сохранить настройки диктовки — $e');
    }
  }
}

String? _nonEmpty(String? text) => (text == null || text.isEmpty) ? null : text;

String modelSizeLabel(String path) {
  try {
    final gb = File(path).lengthSync() / (1024 * 1024 * 1024);
    return gb >= 1
        ? '${gb.toStringAsFixed(1).replaceAll('.', ',')} ГБ'
        : '${(gb * 1024).round()} МБ';
  } catch (_) {
    return '';
  }
}
