import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core/logger.dart';
import 'os.dart';

/// Windows: как здесь устроено всё, что описано в `os.dart`.
///
/// Ничего, кроме этого файла, про пути реестра, `tasklist`, `taskkill`,
/// `explorer` и `ffmpeg` на Windows знать не должно.
class WindowsOs implements Os {
  @override
  String get platformId => 'windows';

  @override
  String get home =>
      Platform.environment['USERPROFILE'] ??
      (Platform.environment['HOMEDRIVE'] != null &&
              Platform.environment['HOMEPATH'] != null
          ? '${Platform.environment['HOMEDRIVE']}${Platform.environment['HOMEPATH']}'
          : r'C:\');

  @override
  String get supportDir =>
      join(Platform.environment['APPDATA'] ?? home, bundleId);

  @override
  String get defaultLibraryPath => join(documentsDir, appName);

  @override
  String get documentsDir {
    final docs = join(home, 'Documents');
    if (Directory(docs).existsSync()) return docs;
    final oneDriveDocs = join(home, 'OneDrive', 'Documents');
    if (Directory(oneDriveDocs).existsSync()) return oneDriveDocs;
    return docs;
  }

  @override
  List<String> get sharedModelDirs => [
        join(home, '.cache', 'whisper'),
        if (Platform.environment['LOCALAPPDATA'] != null)
          join(Platform.environment['LOCALAPPDATA']!, 'whisper'),
        if (Platform.environment['LOCALAPPDATA'] != null)
          join(Platform.environment['LOCALAPPDATA']!, 'NeMoSpeech', 'models'),
      ];

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  String join(String a, [String? b, String? c]) => [a, ?b, ?c].join(r'\');

  @override
  String basename(String path) {
    final norm = path.replaceAll('/', r'\');
    final at = norm.lastIndexOf(r'\');
    return at < 0 ? norm : norm.substring(at + 1);
  }

  @override
  String dirname(String path) {
    final norm = path.replaceAll('/', r'\');
    final at = norm.lastIndexOf(r'\');
    return at <= 0 ? norm : norm.substring(0, at);
  }

  // ── чем считать ───────────────────────────────────────────────────────────

  /// Поиск исполняемого файла на Windows с учётом стандартных расширений (.exe, .cmd, .bat).
  @override
  String? findExecutable(String name) {
    final extensions = name.contains('.') ? [''] : ['', '.exe', '.cmd', '.bat'];
    final dirs = [
      ...?Platform.environment['PATH']?.split(';'),
      if (Platform.environment['LOCALAPPDATA'] != null)
        join(Platform.environment['LOCALAPPDATA']!, 'Programs'),
      if (Platform.environment['ProgramFiles'] != null)
        Platform.environment['ProgramFiles']!,
    ];

    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      for (final ext in extensions) {
        final path = join(dir, '$name$ext');
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  /// Где внутри самого приложения лежит движок whisper.cpp на Windows.
  ///
  /// У Windows это папка Engine рядом с .exe (или сама папка рядом с исполняемым файлом).
  @override
  String get engineDir {
    final appDir = dirname(Platform.resolvedExecutable);
    final sub = join(appDir, 'Engine');
    return Directory(sub).existsSync() ? sub : appDir;
  }

  /// Fn на Windows программам не видна: её разбирает прошивка
  /// клавиатуры. Берём то, что видно и не занято системой: Ctrl+Alt
  /// держать, Ctrl+Shift+Пробел переключать. Win+H занят своей диктовкой
  /// Windows, Alt+Shift — переключением языка ввода.
  ///
  /// Второе — не Ctrl+Alt+Пробел, хотя так и просилось. Ctrl+Alt целиком
  /// входит в Ctrl+Alt+Пробел, а клавиши нажимаются по одной: по дороге
  /// к пробелу набор проходит через Ctrl+Alt, и «держать и говорить»
  /// срабатывало раньше — запись начиналась, не дожидаясь пробела.
  /// Наборы модификаторов у пары обязаны различаться, а не вкладываться
  /// друг в друга; на macOS так и есть ({fn, ctrl} против {fn}+пробел),
  /// и сюда перенесли форму той пары, а не её смысл.
  ///
  /// Ctrl+Shift как переключатель раскладки в нынешней Windows по
  /// умолчанию не назначен — там для языка ввода стоит левый Alt+Shift,
  /// а сочетание смены раскладки не занято вовсе. Если человек его себе
  /// назначил, сочетание можно сменить: настройка на то и есть.
  @override
  ({List<String> mods, List<String> keys}) get defaultHold =>
      (mods: const ['ctrl', 'alt'], keys: const []);

  @override
  ({List<String> mods, List<String> keys}) get defaultToggle =>
      (mods: const ['ctrl', 'shift'], keys: const ['space']);

  /// Vulkan-сборку можно запускать, только если в системе есть загрузчик
  /// Vulkan.
  ///
  /// Это не придирка, а условие запуска: ggml зовёт `vkGetInstanceProcAddr`
  /// напрямую и линкуется с `vulkan-1.dll` неявно, поэтому без неё Windows
  /// убивает процесс ещё до первой строки кода — до всякого «а поищу-ка я
  /// видеокарту». Своей обработки ошибок движку тут не достанется.
  ///
  /// Обратное неверно: загрузчик есть, а видеокарты подходящей нет — это
  /// уже не беда. Тогда ggml не находит устройство, ловит своё исключение
  /// и считает на процессоре тем же самым бинарником.
  ///
  /// Загрузчик кладут драйверы — и NVIDIA, и AMD, и Intel. Нет его там,
  /// где нет и драйвера: чистая установка на базовом видеоадаптере,
  /// виртуальные машины, серверные сборки Windows.
  ///
  /// Проверка эта необходимая, но не достаточная, и на том стоит: она
  /// дешёвая — одна проверка файла, — а недостаточность закрыта в другом
  /// месте. Сломанный или слишком старый драйвер при живой библиотеке
  /// роняет `ggml_vk_instance_init` изнутри, и увидеть это можно только
  /// запуском. Кто не запустился, тот и вычёркивается: см.
  /// `engineFailedToStart` в `core/library.dart`.
  late final bool _vulkanUsable = File(join(
          Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'System32',
          'vulkan-1.dll'))
      .existsSync();

  /// Сборок движка две, и выбор между ними — не вкус, а совместимость.
  ///
  /// Vulkan берётся первым: он ускоряет на любой видеокарте — NVIDIA, AMD,
  /// Intel, — и при этом ничего не тянет за собой. CUDA дала бы то же
  /// самое только на NVIDIA и ценой сотен мегабайт своих библиотек
  /// (официальная сборка whisper.cpp с CUDA 12.4 весит 640 МБ против 8 МБ
  /// процессорной).
  ///
  /// Имя без суффикса — последнее в списке: так подхватится и сборка,
  /// сделанная руками, и та, что осталась от прежних версий.
  @override
  List<String> engineNames(String base) {
    if (base == 'nemo-speech') {
      return [
        if (_vulkanUsable) join('nemo-vulkan', 'bin', '$base.exe'),
        join('nemo-cpu', 'bin', '$base.exe'),
        '$base.exe',
        base,
      ];
    }
    return [
      if (_vulkanUsable) '$base-vulkan.exe',
      '$base-cpu.exe',
      '$base.exe',
      base,
    ];
  }

  // ── путь для чужой программы ──────────────────────────────────────────────

  /// Короткое имя Windows для пути: `C:\Users\Роман\…` →
  /// `C:\Users\ROMAN~1\…`. Зачем это нужно — разобрано в `os.dart`.
  ///
  /// Считаем один раз на путь: модель и папка с временными файлами
  /// не меняются весь сеанс, а каждый вызов — это обращение к файловой
  /// системе.
  @override
  String processPath(String path) =>
      _shortPaths[path] ??= _toShortPath(path);

  final _shortPaths = <String, String>{};

  static bool _isAscii(String s) => s.codeUnits.every((c) => c < 128);

  String _toShortPath(String path) {
    // Латиница и так доедет: не трогаем и в файловую систему не ходим.
    if (_isAscii(path)) return path;
    final whole = _shortNameOf(path);
    if (whole != null) return whole;
    // Короткое имя есть только у того, что существует: `-of` — это
    // основа имени будущего файла, а не файл. Сокращаем папку, имя
    // дописываем своё — наши имена и так из латиницы.
    final dir = _shortNameOf(dirname(path));
    return dir == null ? path : join(dir, basename(path));
  }

  /// Короткое имя или null, если его нет.
  ///
  /// Null возвращается в двух случаях, и оба законные: файла нет вовсе,
  /// либо создание имён 8.3 на этом томе выключено (`fsutil 8dot3name
  /// query`) — тогда Windows отдаёт длинный путь как есть. Отличать их
  /// незачем: и там, и там сделать мы ничего не можем, а звать сюда
  /// с пустыми руками не надо.
  String? _shortNameOf(String path) {
    try {
      final wide = path.toNativeUtf16();
      try {
        // Сначала спрашиваем длину: она возвращается вместе с нулём
        // на конце, и меньшего буфера не хватит.
        final need = _getShortPathName(wide, nullptr, 0);
        if (need == 0) return null;
        final out = calloc<Uint16>(need);
        try {
          final got = _getShortPathName(wide, out.cast<Utf16>(), need);
          if (got == 0 || got >= need) return null;
          final short = out.cast<Utf16>().toDartString();
          // Имён 8.3 на томе нет — Windows молча вернула то же самое.
          // Отдавать это как «сокращённое» нельзя: пусть зовущий видит,
          // что короткого имени не нашлось.
          return _isAscii(short) ? short : null;
        } finally {
          calloc.free(out);
        }
      } finally {
        calloc.free(wide);
      }
    } catch (_) {
      // Kernel32 не открылся, памяти не хватило — что угодно. Длинный
      // путь хуже короткого, но лучше исключения посреди расшифровки.
      return null;
    }
  }

  static final _getShortPathName = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
          Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)>(
      'GetShortPathNameW');

  // ── чем система рисует и что она спрашивает ───────────────────────────────

  @override
  bool get hasWindowMaterial => false;

  @override
  bool get hasSystemMenuBar => false;

  @override
  bool get needsAccessibilityPermission => false;

  // ── как система называет свои вещи ────────────────────────────────────────

  @override
  Future<void> openUrl(String url) async {
    // Через проводник, а не `start`: `start` — команда оболочки, и ей
    // нужен cmd со своими правилами разбора кавычек.
    await Process.run('explorer.exe', [url]);
  }

  @override
  String get fileManagerName => 'Проводник';

  static const _modLabels = {
    'fn': 'Fn',
    'ctrl': 'Ctrl',
    'leftctrl': 'L Ctrl',
    'rightctrl': 'R Ctrl',
    'alt': 'Alt',
    'opt': 'Alt',
    'leftalt': 'L Alt',
    'rightalt': 'R Alt',
    'shift': 'Shift',
    'leftshift': 'L Shift',
    'rightshift': 'R Shift',
    'cmd': 'Win',
    'win': 'Win',
    'leftwin': 'L Win',
    'rightwin': 'R Win',
  };

  static const _modOrder = [
    'leftctrl', 'rightctrl', 'ctrl',
    'leftalt', 'rightalt', 'alt',
    'leftshift', 'rightshift', 'shift',
    'leftwin', 'rightwin', 'win',
    'fn',
  ];

  @override
  String modifierLabel(String mod) => _modLabels[mod.toLowerCase()] ?? mod;

  @override
  String get appIconAreaName => 'панель задач';

  @override
  String get settingsShortcut => 'Ctrl+,';

  @override
  String shortcutLabel(List<String> mods, [List<String> keys = const []]) {
    final ordered = [
      ..._modOrder.where(mods.contains),
      ...mods.where((m) => !_modOrder.contains(m)),
    ];
    return [...ordered.map(modifierLabel), ...keys].join(' + ');
  }

  @override
  String menuShortcut(List<String> mods, [String key = '']) {
    // ⌘ в пункте меню — это Ctrl, а не клавиша Windows: системные
    // сочетания с ней приложению не достаются. Тот же обмен делает
    // `menu_shortcuts.dart`, когда развешивает эти сочетания взаправду,
    // и расходиться подписи с делом не должны.
    final swapped = [for (final m in mods) m == 'cmd' ? 'ctrl' : m];
    final ordered = [
      ..._modOrder.where(swapped.contains),
      ...swapped.where((m) => !_modOrder.contains(m)),
    ];
    return [
      ...ordered.map(modifierLabel),
      if (key.isNotEmpty) _keyLabel(key),
    ].join('+');
  }

  /// Windows пишет имена клавиш словами: значков вроде ⌫ здесь не знают.
  static const _keyNames = {
    'backspace': 'Backspace',
    'delete': 'Delete',
    'enter': 'Enter',
    'return': 'Enter',
    'escape': 'Esc',
    'tab': 'Tab',
    'space': 'Space',
  };

  String _keyLabel(String key) =>
      _keyNames[key.toLowerCase()] ??
      (key.length == 1 ? key.toUpperCase() : key);

  // ── звук ──────────────────────────────────────────────────────────────────

  /// Перекладывание любого звука в 16 кГц моно WAV через ffmpeg.
  ///
  /// Сначала проверяется легковесный встроенный ffmpeg.exe из engineDir,
  /// затем системный ffmpeg из PATH. Если короткие имена 8.3 на томе
  /// выключены, звук временно перекладывается под латинским именем:
  /// ffmpeg на Windows получает argv в системной кодировке и путь вроде
  /// `F:\Загрузки\голос.ogg` иначе не открывается. Рабочая папка передаётся
  /// Windows отдельным wide-string полем, а в argv остаются только ASCII-имена.
  ///
  /// Ошибку конвертации показываем явно: MP4 нельзя передавать движку как WAV.
  @override
  Future<String> toWav(String src, String dst) async {
    final bundledFfmpeg = join(engineDir, 'ffmpeg.exe');
    final systemFfmpeg = findExecutable('ffmpeg');
    final hasBundled = File(bundledFfmpeg).existsSync();
    var ffmpeg = hasBundled ? bundledFfmpeg : (systemFfmpeg ?? 'ffmpeg');

    Directory? staging;
    var input = processPath(src);
    var output = processPath(dst);
    String? workingDirectory;
    try {
      if (!_isAscii(input) || !_isAscii(output)) {
        staging = await Directory.systemTemp.createTemp('tsukiko-audio-');
        final srcName = basename(src);
        final dot = srcName.lastIndexOf('.');
        final suffix = dot < 0 ? '' : srcName.substring(dot).toLowerCase();
        final safeSuffix = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(suffix)
            ? suffix
            : '';
        final inputName = 'input$safeSuffix';
        await File(src).copy(join(staging.path, inputName));
        input = inputName;
        output = 'output.wav';
        workingDirectory = staging.path;
      }
      final ffmpegArgs = [
        '-y',
        '-i',
        input,
        '-vn',
        '-ar',
        '16000',
        '-ac',
        '1',
        '-c:a',
        'pcm_s16le',
        output,
      ];
      var r = await Process.run(
        ffmpeg,
        ffmpegArgs,
        workingDirectory: workingDirectory,
      );

      // Если встроенный ffmpeg завершился из-за отсутствия DLL (-1073741515 / 0xC0000135)
      // или другой ошибки запуска, и в системе есть свой ffmpeg — пробуем его.
      if (r.exitCode != 0 && hasBundled && systemFfmpeg != null && systemFfmpeg != bundledFfmpeg) {
        Log.warn(
          'OS',
          'Встроенный ffmpeg завершился с кодом ${r.exitCode}, '
          'пробуем системный ffmpeg: $systemFfmpeg',
        );
        ffmpeg = systemFfmpeg;
        r = await Process.run(
          ffmpeg,
          ffmpegArgs,
          workingDirectory: workingDirectory,
        );
      }

      if (r.exitCode != 0) {
        final errText = (r.stderr as String).trim();
        final isDllNotFound = r.exitCode == -1073741515 || r.exitCode == 0xC0000135;
        final detail = isDllNotFound
            ? 'не найдена библиотека DLL (STATUS_DLL_NOT_FOUND 0xC0000135). $errText'
            : errText;
        Log.error('OS', 'ffmpeg не преобразовал аудио (${r.exitCode}): $detail');
        throw StateError('ffmpeg не преобразовал аудио (${r.exitCode}): $detail');
      }
      if (staging != null) {
        final made = File(join(staging.path, output));
        if (!made.existsSync()) {
          throw StateError('ffmpeg завершился без выходного WAV-файла');
        }
        await made.copy(dst);
      }
      if (!File(dst).existsSync()) {
        throw StateError('ffmpeg завершился без выходного WAV-файла');
      }
      return dst;
    } catch (error, st) {
      Log.error('OS', 'Не удалось подготовить звук из $src: $error', error, st);
      throw StateError('Не удалось подготовить звук из $src: $error');
    } finally {
      try {
        if (staging?.existsSync() ?? false) {
          staging!.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  // ── процессы ──────────────────────────────────────────────────────────────

  @override
  bool isAlive(int pid) {
    try {
      final r = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
      final out = (r.stdout as String).trim();
      return out.isNotEmpty &&
          out.contains('$pid') &&
          !out.contains('No tasks') &&
          !out.contains('нет задач');
    } catch (_) {
      return false;
    }
  }

  @override
  void signal(int pid, {bool force = false}) {
    try {
      Process.runSync('taskkill', [if (force) '/F', '/PID', '$pid']);
    } catch (_) {}
  }

  /// Перечень процессов — вместе с их командными строками.
  ///
  /// Именно с ними, и это здесь главное. `tasklist` отдаёт только имя
  /// образа, а по имени свой сервер от чужого не отличить: у двух копий
  /// одной программы оно одинаковое. Свой узнаётся по метке в аргументах
  /// (см. `ourServersIn`), и без аргументов забытый сервер диктовки
  /// не нашёлся бы никогда — полтора гигабайта висели бы в памяти
  /// до перезагрузки.
  ///
  /// Поэтому PowerShell и CIM, а не `tasklist`. И не `wmic`: его из
  /// Windows 11 убрали. Зовётся это редко — при запуске и при подметании,
  /// — так что цена запуска PowerShell тут не в счёт.
  @override
  Future<List<ProcListing>> listProcesses() async {
    try {
      final proc = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        // Своё разделение полей: в командной строке бывают и запятые,
        // и кавычки, и CSV пришлось бы разбирать по-настоящему.
        r'Get-CimInstance Win32_Process | ForEach-Object { '
            r'"$($_.ProcessId)|$([int]($_.WorkingSetSize/1024))|$($_.CommandLine)" }',
      ]);
      final lines = proc.stdout
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .toList();
      final errors = proc.stderr.drain<void>();
      final code = await proc.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      final output = await lines;
      await errors;
      if (code != 0) return const [];
      final out = <ProcListing>[];
      for (final line in output) {
        final at = line.indexOf('|');
        if (at < 0) continue;
        final rest = line.indexOf('|', at + 1);
        if (rest < 0) continue;
        final pid = int.tryParse(line.substring(0, at).trim());
        if (pid == null) continue;
        out.add((
          pid: pid,
          rssKb: int.tryParse(line.substring(at + 1, rest).trim()) ?? 0,
          args: line.substring(rest + 1).trim(),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<int> footprintMb(int pid) async {
    try {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      final out = (r.stdout as String).trim();
      if (out.isEmpty || !out.contains('$pid')) return 0;
      final cols = out.split('","').map((s) => s.replaceAll('"', '').trim()).toList();
      if (cols.length >= 5) {
        final memStr = cols[4].replaceAll(RegExp(r'[^\d]'), '');
        final memKb = int.tryParse(memStr) ?? 0;
        return (memKb / 1024).round();
      }
    } catch (_) {}
    return 0;
  }

  // ── система ───────────────────────────────────────────────────────────────

  @override
  Future<bool> reveal(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return false;
      if (type == FileSystemEntityType.directory) {
        // Папку проводник открывает одним доводом, и здесь всё честно:
        // путь в кавычках — это по-прежнему путь.
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('powershell', revealCommand,
            environment: {revealPathVar: path});
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Чем показать файл в проводнике — так, чтобы он его ещё и выделил.
  ///
  /// Казалось бы, дела на одну строку: `explorer /select,<путь>`. Но
  /// Dart на Windows **всегда** берёт каждый довод в кавычки, без
  /// исключений (проверено на сборке: `["/c","echo","/select,C:\a b\c.txt"]`
  /// доезжает как `"/select,C:\a b\c.txt"`). Проводник получает
  /// закавыченное целиком, ключа `/select,` в нём не узнаёт и открывает
  /// «Документы» — ровно то, на что жаловались: «Показать запись»
  /// открывала не ту папку и ничего не выделяла.
  ///
  /// Обойти это в самом Dart нечем: командную строку он собирает сам.
  /// Поэтому командную строку для проводника собирает PowerShell —
  /// он тут уже есть, им же перечисляются процессы.
  ///
  /// Кавычек внутри команды нет ни одной, и это главное: своих кавычек
  /// Dart не экранирует, и первая же попытка написать `"` сломала бы всю
  /// строку. Кавычки вокруг пути собираются из `[char]34`, а сам путь
  /// приходит переменной окружения — то есть не попадает в разбор
  /// PowerShell вовсе и может содержать что угодно.
  ///
  /// Отдельными константами, а не строкой на месте, чтобы их можно было
  /// проверить тестом, не открывая проводник.
  static const revealPathVar = 'TSUKIKO_REVEAL_PATH';

  static const revealCommand = [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Start-Process explorer.exe -ArgumentList '
        "('/select,' + [char]34 + \$env:$revealPathVar + [char]34)",
  ];

  @override
  void onTerminate(void Function() onSignal) {
    // ProcessSignal.sigterm на Windows не поддерживается и бросает UnsupportedError.
    // Перехватываем SIGINT (Ctrl+C / закрытие консоли).
    try {
      ProcessSignal.sigint.watch().listen((_) => onSignal());
    } catch (_) {}
  }
}
