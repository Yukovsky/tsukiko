import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/diarization/diarization_models.dart';
import '../../core/settings.dart';
import '../../core/text.dart';
import '../../core/transcript.dart';
import '../../core/whisper.dart' show JobState;
import '../../platform/os.dart';
import '../queue/job.dart';
import '../queue/queue_bloc.dart';
import '../queue/queue_event.dart';
import '../../core/labels.dart';

/// Местное API: с tsukiko можно поговорить снаружи — из скрипта, из другой
/// программы, из нейросетевого агента.
///
/// **Почему HTTP на 127.0.0.1.** Unix-сокета на Windows нет, и половина
/// приложения осталась бы без API; stdio-режим требует запускать второй
/// экземпляр — а он не поднимется, приложение однооконное, да и модель
/// в памяти была бы вторая; MCP-сервер говорит только с теми агентами,
/// кто умеет MCP, и всё равно поверх чего-то ходит. `dart:io` умеет
/// HTTP сам, одинаково на обеих системах, и обратиться к нему может
/// что угодно — `curl`, `python`, `PowerShell`.
///
/// **Почему живёт здесь, рядом с очередью.** Модель — полтора гигабайта,
/// и двух её копий в памяти не бывает: очередь и диктовка уступают друг
/// другу через один общий механизм. API не заводит своего распознавания
/// вовсе — он кладёт файл в ту же очередь и смотрит, что с ним стало.
/// Поэтому сервер поднимается в изоляте главного окна, где очередь
/// и живёт. Закрытое в трей окно на это не влияет: движок Flutter
/// продолжает работать, а с ним и блок очереди.
///
/// **Чего здесь нет намеренно.**
///
/// Диктовки. Начать запись с микрофона по сети — это доступ к микрофону
/// по сети, и цена ошибки здесь не «неудобно», а «нас слушают». Вся
/// ценность диктовки в клавише под пальцем: пока её держат, идёт запись,
/// отпустили — текст встал в активное окно. Агенту от такого нет пользы,
/// а дыра получается настоящая.
///
/// Правки настроек. Модель, язык и подсказку API отдаёт, но не меняет:
/// иначе агент молча переставил бы приложение под себя, и человек увидел
/// бы чужие настройки, не зная почему. Настройки правит тот, кто смотрит
/// в окно.
const apiPort = 8756;

/// Ключи в `settings.json`. Ключ доступа лежит там же, где остальные
/// настройки: отдельный файл пришлось бы отдельно и переносить, и
/// подчищать, а прав на него всё равно ровно столько же — те же права
/// пользователя на свою папку.
const apiEnabledSetting = 'apiEnabled';

/// Порт. В окне его не спрашивают — 8756 свободен почти всегда, — но
/// если он всё-таки занят, руками в `settings.json` его можно сменить,
/// не переписывая приложение. Тем же ключом пользуются тесты: ноль
/// означает «любой свободный», и параллельные проверки не дерутся
/// за один порт.
const apiPortSetting = 'apiPort';
const apiKeySetting = 'apiKey';
const apiErrorSetting = 'apiError';

/// Новый ключ доступа. `Random.secure()` — системный источник случайности,
/// обычный `Random` предсказуем по значению и в ключах ему не место.
String newApiKey() {
  final r = Random.secure();
  return base64Url
      .encode(List<int>.generate(24, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

class ApiServer {
  ApiServer(this._bloc);

  final QueueBloc _bloc;
  HttpServer? _http;
  String _key = '';

  /// Порт, на котором сервер слушает на самом деле. Ноль — не слушает.
  int get port => _http?.port ?? 0;

  /// Последняя пожаловавшаяся ошибка. Нужна, чтобы не писать одно и то же
  /// в настройки по кругу: запись зовёт «перечитать», перечитывание зовёт
  /// [sync], и без этой памяти получилась бы вечная карусель.
  String _reported = '';

  /// Привести сервер в согласие с настройками. Зовётся при создании
  /// очереди и на каждое «настройки изменились».
  Future<void> sync() async {
    final s = Settings.load();
    final on = (s[apiEnabledSetting] as bool?) ?? false;
    final key = (s[apiKeySetting] as String?) ?? '';
    if (!on || key.isEmpty) return stop();

    // Ключ мог смениться при уже поднятом сервере — перезапускать ради
    // этого нечего, проверка ключа читает поле на каждом запросе.
    _key = key;
    if (_http != null) return;

    try {
      // Только петля, и именно `loopbackIPv4`: `anyIPv4` открыл бы порт
      // всей сети, и любой сосед по кафе получил бы доступ к микрофону
      // и файлам этой машины.
      final http = await HttpServer.bind(
          InternetAddress.loopbackIPv4, (s[apiPortSetting] as int?) ?? apiPort);
      _http = http;
      http.listen(_handle, onError: (Object _) {});
      await _report('');
    } catch (e) {
      // Порт занят или система не дала его слушать. Молчать нельзя:
      // человек включил галку, а снаружи «соединение отвергнуто», и
      // виноватым выглядит агент.
      await _report('$e');
    }
  }

  Future<void> stop() async {
    final http = _http;
    _http = null;
    _key = '';
    await http?.close(force: true);
  }

  /// Сказать окну настроек, работает ли API. Пишем только на перемену —
  /// иначе запись сама себя и вызовет по кругу.
  Future<void> _report(String problem) async {
    if (problem == _reported) return;
    _reported = problem;
    await Settings.save({apiErrorSetting: problem});
    await _bloc.bridge.settingsChanged();
  }

  // ── охрана ────────────────────────────────────────────────────────────────

  /// Почему запрос не будет исполнен. null — будет.
  ///
  /// Три замка, и каждый закрывает свою беду.
  ///
  /// **Origin.** Страница в браузере может обратиться к 127.0.0.1, и
  /// человек об этом не узнает. Браузер обязан поставить в такой запрос
  /// заголовок `Origin`, и подделать его со стороны страницы нельзя.
  /// Значит, `Origin` есть — запрос пришёл со страницы, и мы его не берём.
  /// `curl`, `python` и агент никакого `Origin` не ставят.
  ///
  /// **Host.** Подмена DNS (rebinding) сводит чужое имя на 127.0.0.1 —
  /// тогда браузер считает страницу «своей» для этого имени и `Origin`
  /// может не поставить вовсе. Но `Host` в таком запросе — имя нападающего,
  /// а не петля.
  ///
  /// **Ключ.** Всё остальное: любая программа на этой же машине.
  (int, String)? _deny(HttpRequest req) {
    if (req.headers.value('origin') != null) {
      return (403, 'запросы из браузера не принимаются');
    }
    final host = (req.headers.value('host') ?? '').split(':').first;
    if (host != '127.0.0.1' && host != 'localhost') {
      return (403, 'обращаться нужно по адресу 127.0.0.1');
    }
    final given = (req.headers.value('authorization') ?? '')
        .replaceFirst(RegExp('^Bearer ', caseSensitive: false), '');
    if (!_sameKey(given)) {
      return (401, 'нужен ключ доступа: заголовок Authorization: Bearer <ключ>');
    }
    return null;
  }

  /// Сравнение за одно и то же время при любом ответе: обычное `==`
  /// выходит на первом несовпавшем знаке, и по времени ответа ключ
  /// подбирается посимвольно.
  bool _sameKey(String given) {
    if (_key.isEmpty) return false;
    var diff = given.length ^ _key.length;
    for (var i = 0; i < given.length; i++) {
      diff |= given.codeUnitAt(i) ^ _key.codeUnitAt(i % _key.length);
    }
    return diff == 0;
  }

  /// Годится ли файл в расшифровку. Возвращает путь без ссылок или жалобу.
  ///
  /// Просить расшифровать `/etc/passwd` бессмысленно — но попытка сама
  /// по себе отвечает, есть такой файл или нет, а это уже разведка чужой
  /// машины. Поэтому три условия: расширение звуковое, файл настоящий,
  /// и лежит он там, где человек держит свои записи, — в домашней папке
  /// или во временной. Ссылки разворачиваем до проверки: иначе ссылка
  /// в домашней папке провела бы куда угодно.
  (String?, String?) _audioFile(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return (null, 'нужен путь к файлу: {"file": "/путь/к/записи.m4a"}');
    }
    String path;
    try {
      path = File(raw).resolveSymbolicLinksSync();
    } catch (_) {
      return (null, 'файла нет: $raw');
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return (null, 'это не файл: $raw');
    }
    final dot = path.lastIndexOf('.');
    if (dot < 0 || !audioExt.contains(path.substring(dot).toLowerCase())) {
      return (null, 'расшифровывают звук, а это ${dot < 0 ? 'файл без расширения' : path.substring(dot)}');
    }
    final allowed = [os.home, Directory.systemTemp.path];
    if (!allowed.any((dir) => path.startsWith(dir + Platform.pathSeparator))) {
      return (null, 'файл вне домашней и временной папки — такие не берём');
    }
    return (path, null);
  }

  // ── разбор запросов ───────────────────────────────────────────────────────

  Future<void> _handle(HttpRequest req) async {
    try {
      final deny = _deny(req);
      if (deny != null) return await _send(req, deny.$1, {'error': deny.$2});

      final path = req.uri.path;
      if (req.method == 'GET' && path == '/status') {
        return await _send(req, 200, _status());
      }
      if (req.method == 'GET' && path == '/models') {
        return await _send(req, 200, _models());
      }
      if (path == '/transcribe' && req.method == 'POST') {
        return await _postTranscribe(req);
      }
      if (path == '/transcribe' && req.method == 'GET') {
        return await _getTranscribe(req);
      }
      await _send(req, 404, {
        'error': 'нет такого метода',
        'methods': ['GET /status', 'GET /models', 'POST /transcribe', 'GET /transcribe'],
      });
    } catch (e) {
      await _send(req, 500, {'error': '$e'});
    }
  }

  Future<void> _send(HttpRequest req, int code, Map<String, Object?> body) async {
    final res = req.response;
    res.statusCode = code;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    // Явно в UTF-8, а не через `write`: тот берёт кодировку из заголовка,
    // и по умолчанию она latin-1. Стоит когда-нибудь тронуть Content-Type,
    // и весь русский текст молча уехал бы в вопросительные знаки — а
    // заметно это только на настоящей записи, не на «Ping.aiff».
    res.add(utf8.encode(const JsonEncoder.withIndent('  ').convert(body)));
    await res.close();
  }

  Map<String, Object?> _status() {
    final s = _bloc.state;
    return {
      'app': appName,
      'version': appVersion,
      'engine': s.whisperFound,
      'running': s.running,
      'options': s.defaults.toJson(),
      'formats': [for (final f in exportFormats) f.id],
      'queue': [
        for (final j in s.jobs) {'id': j.path, 'state': j.state.name, 'progress': j.progress},
      ],
    };
  }

  Map<String, Object?> _models() {
    return {
      'current': _bloc.state.defaults.model,
      'models': [
        for (final p in _bloc.state.models) {'path': p, 'name': os.basename(p)},
      ],
      // Модель «Нескольких голосов». Не установлена — скачается при первой
      // же записи с `diarize`; `downloadMb` говорит, сколько это.
      'speakerModels': {
        'installed': DiarizationModels.isInstalled,
        'model': DiarizationModels.file,
        'downloadMb': DiarizationModels.downloadMb(),
      },
    };
  }

  /// Поставить запись в очередь и вернуться, не дожидаясь текста.
  ///
  /// Именно не дожидаясь: часовая лекция считается десятками минут, и
  /// соединение столько не живёт — его закроет либо клиент, либо любая
  /// прокладка по дороге. Ответ отдаёт `id`, по нему спрашивают дальше.
  Future<void> _postTranscribe(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final json = body.trim().isEmpty
        ? const <String, Object?>{}
        : jsonDecode(body) as Map<String, Object?>;
    final (path, problem) = _audioFile(json['file']);
    if (path == null) return _send(req, 400, {'error': problem});

    if (!_bloc.state.whisperFound) {
      return _send(req, 503, {'error': 'движок whisper.cpp не найден'});
    }

    // Голоса — по желанию запроса: `"diarize": true`. Не сказано — как
    // в общих настройках приложения. Число голосов модель находит сама
    // (до восьми), задать его нечем.
    final diarize = json['diarize'];
    if (diarize != null && diarize is! bool) {
      return _send(req, 400, {'error': '«diarize» — true или false'});
    }

    if (_job(path) == null) {
      _bloc.add(FilesAdded([path]));
      if (await _until(() => _job(path), const Duration(seconds: 5)) == null) {
        return _send(req, 500, {'error': 'файл не встал в очередь'});
      }
    }
    if (diarize is bool) {
      _bloc.add(JobOptionsEdited(path, (o) => o.copyWith(diarize: diarize)));
    }
    final started = await _start(path);
    if (started != null) return _send(req, started.$1, {'error': started.$2});
    final job = _job(path);
    if (job == null) return _send(req, 500, {'error': 'запись пропала из очереди'});
    await _send(req, 200, job.report(formatById('txt')));
  }

  /// Тронуть очередь, если она стоит. Возвращает жалобу, если тронуться
  /// не вышло.
  Future<(int, String)?> _start(String path) async {
    if (_bloc.state.running || (_job(path)?.done ?? true)) return null;
    _bloc.add(const RunRequested());
    await _until(
      () => _bloc.state.running ||
          _bloc.state.ask != null ||
          (_job(path)?.done ?? true),
      const Duration(seconds: 5),
      until: true,
    );
    final ask = _bloc.state.ask;
    if (ask == null || _bloc.state.running) return null;

    // «Модель занята диктовкой, продолжить?» отвечаем «да» сами: занята
    // она тем, что просто лежит в памяти, — отдать её ничего не стоит,
    // и ровно это очередь делает, когда диктовка начинается по-настоящему.
    // Остальные вопросы (нет движка, не выбрана модель) агенту не решить —
    // их пересказываем как есть.
    if (!ask.confirm) {
      _bloc.add(const AskDismissed());
      return (409, '${ask.title}. ${ask.message}');
    }
    _bloc.add(const RunConfirmed(true));
    await _until(() => _bloc.state.running || (_job(path)?.done ?? true),
        const Duration(seconds: 10), until: true);
    return null;
  }

  /// Что с записью и, если готова, её текст.
  ///
  /// `wait` — сколько секунд подождать готовности, не отпуская соединение.
  /// Короткая запись успевает за это время целиком, и тогда одного захода
  /// хватает на всё; для долгой это просто длинный опрос — ждём и
  /// возвращаем то, что есть.
  Future<void> _getTranscribe(HttpRequest req) async {
    final q = req.uri.queryParameters;
    final path = q['id'];
    if (path == null) return _send(req, 400, {'error': 'нужен id из POST /transcribe'});
    var job = _job(path);
    if (job == null) return _send(req, 404, {'error': 'такой записи в очереди нет'});

    // Очередь могла добежать до конца ровно между добавлением файла и
    // запуском — тогда никто её больше не тронет, и опрос вечно видел бы
    // «в очереди». Толкаем сами.
    if (!job.done && !_bloc.state.running && job.state != JobState.paused) {
      await _start(path);
    }

    final wait = (int.tryParse(q['wait'] ?? '') ?? 0).clamp(0, 60);
    if (wait > 0) {
      await _until(() => _job(path)?.finished ?? true, Duration(seconds: wait),
          until: true);
    }
    job = _job(path);
    if (job == null) return _send(req, 404, {'error': 'запись убрали из очереди'});
    await _send(req, 200, job.report(formatById(q['format'] ?? 'txt')));
  }

  // ── мелочи ────────────────────────────────────────────────────────────────

  Job? _job(String path) =>
      _bloc.state.jobs.where((j) => j.path == path).firstOrNull;

  /// Дождаться, пока [check] перестанет отдавать null (или отдаст true,
  /// если [until]). Опросом, а не подпиской на поток блока: ждать надо
  /// не «следующего состояния», а определённого — а событий между ними
  /// проходит сколько угодно, и подписка превращалась бы в ту же проверку,
  /// только с подвохом в виде пропущенного первого состояния.
  Future<T?> _until<T>(T? Function() check, Duration limit,
      {bool until = false}) async {
    final deadline = DateTime.now().add(limit);
    while (true) {
      final v = check();
      if (until ? v == true : v != null) return v;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

extension on Job {
  /// Досчитано до конца или упало — спрашивать дальше нечего.
  bool get finished =>
      done || state == JobState.failed || state == JobState.cancelled;

  /// Запись как её видит API.
  Map<String, Object?> report(ExportFormat format) {
    final t = transcript;
    return {
      'id': path,
      'file': path,
      'name': name,
      'state': state.name,
      'progress': progress,
      'done': done,
      if (detail != null) 'detail': detail,
      if (t != null) ...{
        'language': t.lang,
        'segments': t.segments.length,
        'format': format.id,
        'text': renderFor(format, t, name: name),
        // Голоса — только если их больше одного: иначе ответ тот же, что
        // и без режима.
        if (t.hasSpeakers) ...{
          'speakers': [for (final s in t.speakers) s.toJson()],
          'fragments': [
            for (final s in t.segments)
              {
                'from': s.from,
                'to': s.to,
                'text': s.text,
                'speaker': s.speaker,
                'overlap': s.overlap,
              },
          ],
        },
      } else if (raw != null)
        'text': raw,
    };
  }
}
