import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import '../platform/os.dart' show os;
import 'library.dart'
    show defaultLibraryPath, promptsFileName, supportDir, writeJsonAtomically;

/// Расшифровщик берёт конкретную модель диктовки. Сам путь по-прежнему
/// дублируется в `model`, чтобы очередь и старые версии приложения всегда
/// получали готовое значение без разрешения ссылок.
const transcriberUsesDictationModelSetting = 'transcriberUsesDictationModel';

/// Имя порта, через который диктовка (изолят панели) отдаёт записанный
/// разговор очереди главного окна. Изоляты живут в одном процессе, и
/// [IsolateNameServer] связывает их напрямую — без файла и без сети.
const conversationInboxPort = 'app.yuko.tsukiko/conversation-inbox';

/// Хранение настроек на диске.
///
/// Файл настроек правят три изолята: главное окно, панель у строки меню и
/// окно настроек. Отсюда два независимых требования, и оба решаются здесь.
///
/// **Целость.** Запись идёт во временный файл рядом и переименованием
/// встаёт на место. `rename` на одной файловой системе атомарен, поэтому
/// читатель видит либо старый файл целиком, либо новый целиком. Раньше
/// файл переписывался на месте, и падение или полный диск посреди записи
/// оставляли обрезанный JSON — то есть стирали все настройки разом.
///
/// **Очередь.** «Прочитать → слить → записать» из двух изолятов сразу
/// теряет правку того, кто прочитал первым. Файловый замок для этого
/// не годится: POSIX-замки принадлежат процессу, а изоляты живут в одном
/// процессе — второй проходит сквозь замок первого, проверено. Поэтому
/// пишет всегда один изолят: кто первым занял имя в [IsolateNameServer],
/// тот и владеет файлом, остальные шлют ему правки портом и ждут ответа.
/// Читают при этом все напрямую — благодаря атомарной записи это безопасно.

/// Общие настройки приложения: обычный JSON в Application Support.
class Settings {
  Settings._();

  /// Имя порта владельца. Одно на приложение — иначе владельцев станет
  /// столько же, сколько имён.
  static const _writerName = 'app.yuko.tsukiko/settings-writer';

  static File get _file => File('$supportDir/settings.json');

  /// Наш порт, если владелец — этот изолят. Держим ссылку: закрытый
  /// ReceivePort перестал бы принимать правки соседей.
  static ReceivePort? _owned;

  static Map<String, dynamic> load() {
    try {
      return jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Слить [data] в файл, не тронув чужие ключи.
  ///
  /// Возвращается, когда правка действительно на диске: сразу после этого
  /// соседним окнам говорят перечитать файл, и читать они должны уже новое.
  static Future<void> save(Map<String, dynamic> data) async {
    final writer = _writer();
    if (writer == null) {
      _merge(data);
      return;
    }
    final reply = ReceivePort();
    writer.send([data, reply.sendPort]);
    try {
      await reply.first;
    } finally {
      reply.close();
    }
  }

  /// Порт владельца или null, если владелец — мы сами.
  static SendPort? _writer() {
    if (_owned != null) return null;

    final found = IsolateNameServer.lookupPortByName(_writerName);
    if (found != null) return found;

    // Имя занимается атомарно: если два изолята пришли сюда одновременно,
    // ровно один получит true, второй пойдёт искать заново.
    final rp = ReceivePort();
    if (!IsolateNameServer.registerPortWithName(rp.sendPort, _writerName)) {
      rp.close();
      // Владелец мог зарегистрироваться между поиском и попыткой. Если
      // его всё-таки нет, пишем сами: потерять правку хуже, чем разойтись
      // с соседом в невозможной гонке.
      return IsolateNameServer.lookupPortByName(_writerName);
    }
    _owned = rp;
    rp.listen((message) {
      final args = message as List;
      _merge((args[0] as Map).cast<String, dynamic>());
      (args[1] as SendPort).send(null);
    });
    return null;
  }

  static void _merge(Map<String, dynamic> data) {
    try {
      Directory(supportDir).createSync(recursive: true);
      writeJsonAtomically(_file, {...load(), ...data});
    } catch (e) {
      // Настройки не сохранились. Молчать нельзя: следующий запуск придёт
      // со старыми значениями, и человек решит, что приложение их не помнит.
      stderr.writeln('tsukiko: не удалось сохранить настройки — $e');
    }
  }
}

/// Подсказки модели — отдельно от всех прочих настроек.
///
/// Подсказка это не «настройка», а работа: список имён, терминов и слов,
/// которые модель иначе пишет как попало. Собирают его месяцами и по
/// одному слову. Всё остальное в settings.json переживает переустановку
/// плохо и не жалко: галки расставляются заново за минуту. Здесь не так —
/// а установщик Windows настройки при удалении стирает намеренно
/// (tool/installer.iss, RemoveOurSettings), и вместе с ними уносил и этот
/// список.
///
/// Поэтому подсказки лежат там же, где расшифровки, — в библиотеке.
/// Она и по смыслу сделанная человеком работа, и по обращению: установщик
/// про неё спрашивает отдельно и по умолчанию не трогает.
///
/// Настройки остаются главными: в них подсказка и читается, и пишется
/// по-прежнему. Здесь — запасная копия, из которой берут, когда в
/// настройках пусто.
class Prompts {
  Prompts._();

  /// Подсказка расшифровщика и подсказка диктовки — разные: диктуют
  /// не то же, что расшифровывают.
  static const transcriber = 'transcriber';
  static const dictation = 'dictation';

  static String get _dir =>
      (Settings.load()['libraryPath'] as String?) ?? defaultLibraryPath;

  static File get _file => File(os.join(_dir, promptsFileName));

  static String read(String which) {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return (j[which] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Пустую подсказку в пустую библиотеку не пишем: заводить папку ради
  /// файла с двумя пустыми строками незачем. Стереть уже написанное при
  /// этом можно — файл в таком случае уже есть.
  static void write(String which, String text) {
    try {
      final dir = Directory(_dir);
      if (text.isEmpty && !_file.existsSync()) return;
      if (read(which) == text) return;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final was = <String, dynamic>{};
      try {
        was.addAll(
          jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>,
        );
      } catch (_) {}
      writeJsonAtomically(_file, {...was, which: text});
    } catch (e) {
      stderr.writeln(
        'tsukiko: подсказка не сохранилась рядом с расшифровками — $e',
      );
    }
  }
}
