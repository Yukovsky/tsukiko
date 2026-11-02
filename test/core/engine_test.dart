import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/core/library.dart';
import 'package:tsukiko/core/models.dart';
import 'package:tsukiko/core/recognition.dart';
import 'package:tsukiko/core/text.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/core/labels.dart';

import '../support/fake_os.dart';

void main() {
  test('Metal failure can restart whisper-server without GPU', () {
    const options = RunOptions(model: '/models/large.bin', lang: 'auto', threads: 4);
    expect(serverArgs(options, 1234), isNot(contains('-ng')));
    expect(serverArgs(options, 1234, noGpu: true), contains('-ng'));
  });

  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding подменяет HttpOverrides и заворачивает
  // любой HttpClient в фальшивый 400 — а этот файл настоящую сеть
  // и проверяет (Download, whisper-server). Возвращаем обычные сокеты.
  HttpOverrides.global = null;
  // Строки идут через currentL10n(), который читает системный локаль.
  // Тестовый движок отдаёт en_US — здесь же тексты сверены с русским,
  // поэтому закрепляем его явно.
  setUp(() =>
      binding.platformDispatcher.localesTestValue = const [Locale('ru')]);

  _hotkeyTaps();

  test('таймкоды', () {
    expect(fmtTs(0), '00:00:00.000');
    expect(fmtTs(3723456), '01:02:03.456');
    expect(fmtTs(3723456, msSep: ','), '01:02:03,456');
  });

  test('рендер текста и субтитров', () {
    const segs = [Segment(0, 1500, 'раз'), Segment(1500, 3000, 'два')];
    expect(renderPlain(segs, false), 'раз\nдва');
    expect(renderPlain(segs, true).startsWith('[00:00:00.000 → 00:00:01.500]  раз'), isTrue);
    expect(renderSrt(segs).split('\n')[1], '00:00:00,000 --> 00:00:01,500');
    expect(renderFor(formatMarkdown, const Transcript('ru', segs), name: 'x.ogg').contains('раз'), isTrue);
  });

  test('аргументы whisper-cli', () {
    final args = buildArgs(
      const RunOptions(model: '/m.bin', lang: 'ru', threads: 6, maxLen: 42),
      '/a.wav',
      '/out',
    );
    expect(args.take(6).toList(), ['-m', '/m.bin', '-l', 'ru', '-t', '6']);
    expect(args.contains('-oj'), isTrue);
    expect(args.contains('-ml'), isTrue);
    expect(args.last, '/a.wav');
    // VAD не подключается без файла модели
    expect(
      buildArgs(const RunOptions(model: 'm', lang: 'auto', threads: 4, vad: true),
              '/a.wav', '/o')
          .contains('--vad'),
      isFalse,
    );
  });

  test('аргументы nemo-speech', () {
    const options = RunOptions(
      model: '/models/nemotron.gguf',
      lang: 'ru',
      threads: 8,
      prompt: 'Цукика, Немотрон',
      punctuate: false,
    );
    final args = buildNemoArgs(options, '/audio.wav', '/result.json');
    expect(args.take(2), ['transcribe', '/audio.wav']);
    expect(args[args.indexOf('--model') + 1], options.model);
    expect(args[args.indexOf('--output') + 1], '/result.json');
    expect(args[args.indexOf('--format') + 1], 'json');
    expect(args, contains('--no-warmup'));
    expect(args[args.indexOf('--language') + 1], 'ru');
    expect(args, contains('--no-punctuation'));
    expect(args[args.indexOf('--speech-context') + 1], options.prompt);
    expect(args[args.indexOf('--speech-context-boost') + 1], '3');
    expect(args, isNot(contains('8')),
        reason: 'nemo-speech сам управляет потоками своего backend');

    final automatic = buildNemoArgs(
      const RunOptions(model: 'm.gguf', lang: 'auto', threads: 4),
      '/audio.wav',
      '/result.json',
    );
    expect(automatic, isNot(contains('--language')));
    expect(automatic, isNot(contains('--speech-context')),
        reason: 'затравка Whisper не является словарём NeMo');

    final parakeet = buildNemoArgs(
      options.copyWith(model: '/models/parakeet-tdt-0.6b-v3.q8_0.gguf'),
      '/audio.wav',
      '/result.json',
    );
    expect(parakeet, isNot(contains('--speech-context')),
        reason: 'Parakeet TDT принимает флаг, но подсказку игнорирует');
  });

  test('затравка на пунктуацию', () {
    // по умолчанию — подсказка на языке записи
    const ru = RunOptions(model: 'm', lang: 'ru', threads: 4);
    expect(const RunOptions(model: 'm', lang: 'auto', threads: 4)
        .effectivePrompt, isEmpty);
    expect(buildArgs(ru, '/a.wav', '/o').contains('--prompt'), isTrue);
    expect(ru.effectivePrompt, contains('правилам русского языка'));
    // Затравка не должна наводить модель на диалог и на субтитры: оттуда
    // приходили и тире в начале реплики, и «Продолжение следует…».
    expect(ru.effectivePrompt, isNot(contains('тире')));
    expect(ru.effectivePrompt.toLowerCase(), isNot(contains('расшифровк')));
    expect(ru.effectivePrompt.toLowerCase(), isNot(contains('субтитр')));
    expect(
      const RunOptions(model: 'm', lang: 'en', threads: 4).effectivePrompt,
      contains('punctuation'),
    );
    expect(
      const RunOptions(model: 'm', lang: 'en', threads: 4).effectivePrompt,
      isNot(contains('dashes')),
    );
    // своя подсказка важнее затравки
    expect(
      const RunOptions(model: 'm', lang: 'ru', threads: 4, prompt: 'Минина, Сытый двор')
          .effectivePrompt,
      'Минина, Сытый двор',
    );
    // выключено — подсказки нет вовсе
    expect(
      buildArgs(const RunOptions(model: 'm', lang: 'ru', threads: 4, punctuate: false),
              '/a.wav', '/o')
          .contains('--prompt'),
      isFalse,
    );
  });

  test('живой разбор строк whisper-cli', () {
    final s = parseSegmentLine('[00:00:01.500 --> 00:00:24.720]   Ну давайце, вось. ');
    expect(s, isNotNull);
    expect(s!.from, 1500);
    expect(s.to, 24720);
    expect(s.text, 'Ну давайце, вось.');
    // прогресс и служебные строки сегментами не считаются
    expect(parseSegmentLine('whisper_print_progress_callback: progress =  40%'), isNull);
    expect(parseSegmentLine('[00:00:00.000 --> 00:00:02.000]   '), isNull);
  });

  test('разбор json от whisper', () {
    final json = jsonEncode({
      'result': {'language': 'be'},
      'transcription': [
        {
          'offsets': {'from': 0, 'to': 900},
          'text': ' прывітанне ',
        }
      ],
    });
    final t = parseWhisperJson(json);
    expect(t.lang, 'be');
    expect(t.segments.single.text, 'прывітанне');
    expect(t.segments.single.to, 900);
  });

  test('разбор json от NeMo собирает слова в фрагменты', () {
    final json = jsonEncode({
      'text': 'Первое предложение. После паузы второе',
      'duration': 3.4,
      'languages': ['ru-RU'],
      'words': [
        {'word': 'Первое', 'start': 0.1, 'end': 0.5, 'confidence': 0.9},
        {'word': 'предложение.', 'start': 0.5, 'end': 1.1, 'confidence': 0.8},
        {'word': 'После', 'start': 2.0, 'end': 2.4, 'confidence': 0.9},
        {'word': 'паузы', 'start': 2.4, 'end': 2.8, 'confidence': 0.9},
        {'word': 'второе', 'start': 2.8, 'end': 3.4, 'confidence': 0.9},
      ],
    });
    final transcript = parseNemoJson(json);
    expect(transcript.lang, 'ru');
    expect(transcript.segments, hasLength(2));
    expect(transcript.segments.first.text, 'Первое предложение.');
    expect(transcript.segments.first.from, 100);
    expect(transcript.segments.first.to, 1100);
    expect(transcript.segments.last.text, 'После паузы второе');
    expect(transcript.segments.last.from, 2000);
    expect(transcript.segments.last.to, 3400);
  });

  test('ответ NeMo без времён остаётся доступным как один фрагмент', () {
    final transcript = parseNemoJson(jsonEncode({
      'text': 'Короткая фраза',
      'duration': 1.25,
      'language': 'ru',
      'words': [],
    }));
    expect(transcript.lang, 'ru');
    expect(transcript.segments.single.text, 'Короткая фраза');
    expect(transcript.segments.single.to, 1250);
  });

  test('разбор json от NeMo определяет язык по тексту при ? или auto или unknown', () {
    final ruTranscript = parseNemoJson(jsonEncode({
      'text': 'Проверка кириллицы',
      'language': '?',
      'words': [],
    }));
    expect(ruTranscript.lang, 'ru');

    final ruFromWords = parseNemoJson(jsonEncode({
      'text': '',
      'language': '?',
      'words': [
        {'word': 'Привет', 'start': 0, 'end': 500},
        {'word': 'мир', 'start': 500, 'end': 1000},
      ],
    }));
    expect(ruFromWords.lang, 'ru');

    final ruUnknown = parseNemoJson(jsonEncode({
      'text': 'Распознанный текст на русском',
      'language': 'unknown',
      'words': [],
    }));
    expect(ruUnknown.lang, 'ru');

    final ruNormalized = parseNemoJson(jsonEncode({
      'text': 'Текст',
      'language': 'ru-RU',
      'words': [],
    }));
    expect(ruNormalized.lang, 'ru');

    final ruFromLanguagesList = parseNemoJson(jsonEncode({
      'text': 'Текст',
      'languages': ['ru-ru'],
      'words': [],
    }));
    expect(ruFromLanguagesList.lang, 'ru');

    final enTranscript = parseNemoJson(jsonEncode({
      'text': 'Hello world testing english',
      'language': 'auto',
      'words': [],
    }));
    expect(enTranscript.lang, 'en');

    final enUnknown = parseNemoJson(jsonEncode({
      'text': 'Some english words spoken',
      'language': 'unknown',
      'words': [],
    }));
    expect(enUnknown.lang, 'en');

    final noLetters = parseNemoJson(jsonEncode({
      'text': '123 456 ... !!!',
      'language': '?',
      'words': [],
    }));
    expect(noLetters.lang, '?');
  });

  test('форматы экспорта различимы и не зависят от настроек вида', () {
    const t = Transcript('ru', [Segment(0, 1500, 'раз'), Segment(1500, 3000, 'два')]);

    // чистый текст — без единой цифры таймкода
    final plain = renderAs(formatPlainText, t);
    expect(plain, 'раз\nдва');
    expect(plain.contains('00:00'), isFalse);

    // текст с таймкодами — тот же текст, но с метками
    expect(renderAs(formatTimedText, t), contains('[00:00:00.000'));
    expect(renderAs(formatTimedText, t), contains('раз'));

    // у каждого формата своё окончание имени файла
    expect(formatPlainText.fileName('Запись'), 'Запись.txt');
    expect(formatTimedText.fileName('Запись'), 'Запись (таймкоды).txt');
    expect(formatSrt.fileName('Запись'), 'Запись.srt');
    expect(exportFormats.map((f) => f.fileName('x')).toSet().length,
        exportFormats.length);

    expect(renderAs(formatVtt, t).startsWith('WEBVTT'), isTrue);
    expect(renderAs(formatJson, t), contains('"language": "ru"'));
    expect(renderFor(formatMarkdown, t, name: 'Запись.ogg'), contains('# Запись.ogg'));
    expect(formatById('txt-ts').label, 'Текст с таймкодами');
  });

  test('расшифровка с метками переходит между форматами', () {
    const srt = '1\n00:00:01,000 --> 00:00:02,500\nраз\n';
    final timed = readTranscript('речь.srt', srt).parsed;
    expect(timed, isNotNull);
    expect(renderAs(formatVtt, timed!), startsWith('WEBVTT'));
    expect(renderAs(formatJson, timed), contains('"from": 1000'));
    expect(renderAs(formatMarkdown, timed), contains('**[00:00:01.000]**'));

    expect(readTranscript('речь.txt', 'раз два').parsed, isNull,
        reason: 'без меток границы субтитров не восстановить');
  });

  test('раскладка библиотеки: месяц, папка записи, номера при совпадении', () {
    final root = Directory.systemTemp.createTempSync('tsukiko_lib').path;
    final when = DateTime(2026, 8, 2);
    expect(monthFolder(when), '2026-08');

    // один формат — файл прямо в папке месяца
    final one = planPlacement(root: root, stem: 'Запись', formatCount: 1, now: when);
    // Через os.join, а не «/»: на Windows разделитель другой, и
    // проверка ловила бы не раскладку библиотеки, а сам разделитель.
    expect(one.dir, os.join(root, '2026-08'));
    expect(one.pathFor('.txt'), os.join(root, '2026-08', 'Запись.txt'));

    // имя занято — добавляем номер, старое не трогаем
    Directory(one.dir).createSync(recursive: true);
    File(os.join(one.dir, 'Запись.txt')).writeAsStringSync('старое');
    expect(freeStem(one.dir, 'Запись', '.txt'), 'Запись 2');
    expect(File(os.join(one.dir, 'Запись.txt')).readAsStringSync(), 'старое');

    // форматов несколько — у записи своя папка
    final many = planPlacement(root: root, stem: 'Запись', formatCount: 3, now: when);
    expect(many.dir, os.join(root, '2026-08', 'Запись'));
    expect(many.pathFor('.srt'),
        os.join(os.join(root, '2026-08', 'Запись'), 'Запись.srt'));

    // и папка нумеруется, если такая уже есть
    Directory(many.dir).createSync(recursive: true);
    expect(
      planPlacement(root: root, stem: 'Запись', formatCount: 3, now: when).dir,
      os.join(root, '2026-08', 'Запись 2'),
    );

    Directory(root).deleteSync(recursive: true);
  });

  test('обзор библиотеки: только расшифровки, новое сверху, две ступени вглубь',
      () {
    final root = Directory.systemTemp.createTempSync('tsukiko_scan').path;
    final month = Directory(os.join(root, '2026-08'))..createSync();
    // Запись, сохранённая в нескольких форматах, лежит в своей папке —
    // это вторая ступень, и до неё обход обязан доставать.
    final own = Directory(os.join(month.path, 'Совещание'))..createSync();

    File(os.join(month.path, 'Разговор.txt')).writeAsStringSync('раз');
    File(os.join(own.path, 'Совещание.srt')).writeAsStringSync('два');
    // Исходный звук в списке расшифровок делать нечего.
    File(os.join(month.path, 'Разговор.m4a')).writeAsStringSync('звук');

    final found = scanLibrary(root);
    expect(found.map((e) => e.name).toSet(), {'Разговор.txt', 'Совещание.srt'},
        reason: 'звук — не расшифровка, а вложенная папка записи — да');

    // Новое сверху: по этому списку и возвращаются к недавней работе.
    File(os.join(month.path, 'Разговор.txt'))
        .setLastModifiedSync(DateTime(2026, 8, 1));
    File(os.join(own.path, 'Совещание.srt'))
        .setLastModifiedSync(DateTime(2026, 8, 9));
    expect(scanLibrary(root).first.name, 'Совещание.srt');

    // Папка относительно корня — то, по чему запись узнают через полгода.
    final deep = scanLibrary(root).firstWhere((e) => e.name == 'Совещание.srt');
    expect(deep.folderIn(root), os.join('2026-08', 'Совещание'));

    // Своё хозяйство в списке расшифровок не место: подсказки и указатель
    // на записи лежат в библиотеке нарочно, но расшифровками от этого
    // не становятся.
    File(os.join(root, promptsFileName)).writeAsStringSync('{}');
    File(os.join(root, Sources.fileName)).writeAsStringSync('{}');
    final names = scanLibrary(root).map((e) => e.name).toSet();
    expect(names.contains(promptsFileName), isFalse);
    expect(names.contains(Sources.fileName), isFalse);

    // Пропавшей папки не бывает бедой: список просто пуст.
    Directory(root).deleteSync(recursive: true);
    expect(scanLibrary(root), isEmpty);
  });

  test('пустая запись отличается от записи со звуком', () {
    // Ровно тот файл, на котором движок говорит «failed to read the
    // frames of the audio data»: заголовок AVAudioRecorder на четыре
    // килобайта и нулевой кусок data. Спасать в нём нечего, распознавать
    // тоже — и сказать об этом надо словами, а не полутора экранами
    // про тензоры.
    final dir = Directory.systemTemp.createTempSync('tsukiko_wav');
    Uint8List riff(int dataBytes) {
      final b = BytesBuilder();
      void tag(String t) => b.add(t.codeUnits);
      void u32(int v) => b.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255]);
      tag('RIFF');
      u32(36 + dataBytes);
      tag('WAVE');
      tag('fmt ');
      u32(16);
      b.add([1, 0, 1, 0]);
      u32(16000);
      u32(32000);
      b.add([2, 0, 16, 0]);
      tag('data');
      u32(dataBytes);
      b.add(List.filled(dataBytes, 0));
      return b.toBytes();
    }

    final empty = File(os.join(dir.path, 'пусто.wav'))..writeAsBytesSync(riff(0));
    final full = File(os.join(dir.path, 'звук.wav'))..writeAsBytesSync(riff(64));
    expect(wavHasAudio(empty.path), isFalse);
    expect(wavHasAudio(full.path), isTrue);

    // Не RIFF — не наше дело: m4a и mp3 разбирает движок сам, и «не знаю»
    // здесь честнее выдуманного ответа.
    final other = File(os.join(dir.path, 'чужое.m4a'))
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));
    expect(wavHasAudio(other.path), isTrue);
    expect(wavHasAudio(os.join(dir.path, 'нет-такого.wav')), isTrue);

    dir.deleteSync(recursive: true);
  });

  test('расшифровка помнит свою запись и находит её на новом месте', () {
    final root = Directory.systemTemp.createTempSync('tsukiko_src').path;
    final month = Directory(os.join(root, '2026-09'))..createSync(recursive: true);
    final transcript = os.join(month.path, 'Совещание.txt');
    final audio = File(os.join(month.path, 'Совещание.m4a'))
      ..writeAsStringSync('звук');

    Sources.remember(root, [transcript], audio.path);
    final link = Sources.of(root, transcript)!;
    expect(link.path, audio.path);
    expect(Sources.locate(root, link, transcript), audio.path);

    // Записи не стало — врать про неё нельзя.
    audio.deleteSync();
    expect(Sources.locate(root, link, transcript), isNull);

    // А вот переезд в папку спасённых записей находим сами: туда её
    // кладёт диктовка, и заглянуть туда дешевле, чем спрашивать.
    final rescued = Directory(os.join(root, rescuedFolderName))..createSync();
    final moved = File(os.join(rescued.path, 'Совещание.m4a'))
      ..writeAsStringSync('звук');
    expect(Sources.locate(root, link, transcript), moved.path);

    // Однофамилец не годится: размер сверяем именно затем.
    moved.writeAsStringSync('совсем другая запись');
    expect(Sources.locate(root, link, transcript), isNull);

    // Ключ — путь относительно корня: библиотеку можно переложить
    // целиком, и связи останутся целы.
    final away = Directory.systemTemp.createTempSync('tsukiko_src2').path;
    Directory(os.join(root, '2026-09')).renameSync(os.join(away, '2026-09'));
    File(os.join(root, Sources.fileName)).copySync(os.join(away, Sources.fileName));
    expect(Sources.of(away, os.join(away, '2026-09', 'Совещание.txt'))?.path,
        audio.path);

    Directory(root).deleteSync(recursive: true);
    Directory(away).deleteSync(recursive: true);
  });

  test('по записи находятся все её готовые форматы', () {
    final root = Directory.systemTemp.createTempSync('tsukiko_src').path;
    final month = Directory(os.join(root, '2026-09'))..createSync(recursive: true);
    final audio = File(os.join(root, 'Совещание.m4a'))
      ..writeAsStringSync('звук');
    final txt = File(os.join(month.path, 'Совещание.txt'))
      ..writeAsStringSync('текст');
    final srt = File(os.join(month.path, 'Совещание.srt'))
      ..writeAsStringSync('субтитры');
    Sources.remember(root, [txt.path, srt.path], audio.path);

    expect(Sources.transcriptsFor(root, audio.path).toSet(), {txt.path, srt.path});

    srt.deleteSync();
    expect(Sources.transcriptsFor(root, audio.path), [txt.path],
        reason: 'старая служебная связь не возвращает пропавший файл');
    Directory(root).deleteSync(recursive: true);
  });

  test('папка по умолчанию — в Документах, строчными', () {
    expect(appName, 'tsukiko');
    expect(defaultLibraryPath.endsWith(os.join('Documents', appName)), isTrue);
  });








  test('числительные согласуются с числом', () {
    expect(segmentsLabel(1), '1 фрагмент');
    expect(segmentsLabel(3), '3 фрагмента');
    expect(segmentsLabel(5), '5 фрагментов');
    expect(segmentsLabel(11), '11 фрагментов');
    expect(segmentsLabel(21), '21 фрагмент');
    expect(segmentsLabel(112), '112 фрагментов');
    expect(recordsLabel(2), '2 записи');
    expect(wordsLabel(1), '1 слово');
    expect(wordCount('  раз  два   три '), 3);
    expect(wordCount(''), 0);
  });

  test('длительность без лишних нулей', () {
    expect(humanDuration(7000), '0:07');
    expect(humanDuration(247000), '4:07');
    expect(humanDuration(3723000), '1:02:03');
  });

  test('языки называются словами, а не кодами', () {
    expect(languageName('be'), 'Беларуская');
    expect(languageName('auto'), 'Определять автоматически');
    // неизвестный код не должен ронять интерфейс
    expect(languageName('xx'), 'XX');
  });

  test('коды языков нормализуются', () {
    expect(normalizeLanguageCode('ru-ru'), 'ru');
    expect(normalizeLanguageCode('ru-RU'), 'ru');
    expect(normalizeLanguageCode('ru_RU'), 'ru');
    expect(normalizeLanguageCode('RU-RU'), 'ru');
    expect(normalizeLanguageCode('  ru-ru  '), 'ru');
    expect(normalizeLanguageCode('en-US'), 'en');
    expect(normalizeLanguageCode('en_gb'), 'en');
    expect(normalizeLanguageCode('de-DE'), 'de');
    expect(normalizeLanguageCode('ja-JP'), 'ja');
    expect(normalizeLanguageCode('auto'), 'auto');
    expect(normalizeLanguageCode('AUTO'), 'auto');
    expect(normalizeLanguageCode(''), 'auto');
    expect(normalizeLanguageCode('   '), 'auto');
    expect(normalizeLanguageCode('unknown'), 'unknown');
    expect(normalizeLanguageCode('xyz-ABC'), 'xyz');

    expect(languageName('ru'), 'Русский');
    expect(languageName('ru-ru'), 'Русский');
    expect(languageName('ru-RU'), 'Русский');
    expect(languageName('ru_RU'), 'Русский');
    expect(languageName('RU-RU'), 'Русский');
    expect(languageName('en'), 'English');
    expect(languageName('en-US'), 'English');
    expect(languageName('en_gb'), 'English');
    expect(languageName('unknown'), 'UNKNOWN');
    expect(languageName('xx'), 'XX');
  });

  test('свои настройки записи: копия, отличия, обратная совместимость', () {
    const base = RunOptions(model: '/a.bin', lang: 'auto', threads: 4);
    final own = base.copyWith(lang: 'be', maxLen: 42);

    expect(own.model, base.model);
    expect(own.diffAgainst(base), ['язык', 'длина фрагмента']);
    expect(base.diffAgainst(base), isEmpty);

    // круг через JSON ничего не теряет
    final back = RunOptions.fromJson(own.toJson(), base);
    expect(back.diffAgainst(own), isEmpty);

    // в старом файле настроек новых ключей нет — берём из общих
    expect(RunOptions.fromJson({'lang': 'ru'}, base).threads, 4);
  });

  test('открытие субтитров превращает их в обычную расшифровку', () {
    const srt = '1\n'
        '00:00:00,000 --> 00:00:01,500\n'
        'раз\n'
        '\n'
        '2\n'
        '00:00:01,500 --> 00:00:03,000\n'
        'два\n'
        'два с половиной\n';
    final t = parseSubtitles(srt)!;
    expect(t.segments.length, 2);
    expect(t.segments.first.text, 'раз');
    expect(t.segments.first.to, 1500);
    expect(t.segments.last.text, 'два два с половиной');

    // VTT и наш собственный «текст с таймкодами» — тем же разбором
    expect(parseSubtitles(renderVtt(t.segments))!.segments.length, 2);
    final timed = parseSubtitles(renderPlain(t.segments, true))!;
    expect(timed.segments.map((s) => s.text).toList(), ['раз', 'два два с половиной']);
    expect(timed.segments.first.from, 0);

    // и, значит, открытые субтитры можно пересохранить в другой формат
    expect(renderAs(formatPlainText, timed), 'раз\nдва два с половиной');

    // обычный текст субтитрами не притворяется
    expect(parseSubtitles('просто текст\nбез таймкодов'), isNull);
  });

  // Системный звук и afconvert есть только на macOS. На Windows ту же
  // работу делает ffmpeg, и проверять её надо там, где он лежит.
  test('afconvert делает wav из системного звука', skip: !Platform.isMacOS, () async {
    final out = '${Directory.systemTemp.path}/tsukiko_test.wav';
    final res = await os.toWav('/System/Library/Sounds/Ping.aiff', out);
    expect(res, out);
    expect(File(out).lengthSync() > 1000, isTrue);
    File(out).deleteSync();
  });

  // ── диктовка ──────────────────────────────────────────────────────────────

  test('расшифровку фразы склеиваем в строку, а галлюцинации отбрасываем', () {
    // сервер отдаёт текст сегментами, в поле ввода это должно попасть одной фразой
    expect(tidyDictated(' раз\n два  три \n'), 'раз два три');
    expect(tidyDictated(''), '');
    // на тишине whisper сочиняет — всё, что целиком в скобках, не речь
    expect(tidyDictated(' [BLANK_AUDIO] '), '');
    expect(tidyDictated('(музыка)'), '');
    expect(tidyDictated('*звук двигателя*'), '');
    // а скобки внутри фразы — обычный текст
    expect(tidyDictated('привет (кажется)'), 'привет (кажется)');

    // Выдумки на тишине выбрасываются целиком: сказано этого не было.
    expect(tidyDictated('Продолжение следует...'), '');
    expect(tidyDictated('Спасибо за просмотр!'), '');
    expect(tidyDictated('  субтитры сделал DimaTorzok '), '');
    expect(tidyDictated('Субтитры: DimaTorzok'), '');
    expect(tidyDictated('DimaTorzok'), '');
    expect(tidyDictated('To be continued...'), '');
    expect(tidyDictated('Конец фильма.'), '');
    expect(tidyDictated('Thanks for watching!'), '');
    expect(tidyDictated('Like and subscribe!'), '');

    // Прилипшие в хвосте галлюцинации срезаются (кейс пользователя):
    expect(
      tidyDictated('...бери какой-нибудь другой цвет. Субтитры сделал DimaTorzok'),
      '...бери какой-нибудь другой цвет.',
    );
    expect(
      tidyDictated('бери какой-нибудь другой цвет, субтитры сделал DimaTorzok'),
      'бери какой-нибудь другой цвет',
    );
    expect(
      tidyDictated('бери какой-нибудь другой цвет — продолжение следует'),
      'бери какой-нибудь другой цвет',
    );
    expect(
      tidyDictated('Привет! Продолжение следует...'),
      'Привет!',
    );
    expect(
      tidyDictated('бери какой-нибудь другой цвет. Спасибо за просмотр, ставьте лайки!'),
      'бери какой-нибудь другой цвет.',
    );

    // Но когда фраза сказана всерьёз — она полностью остаётся:
    expect(
      tidyDictated('здесь продолжение следует из предыдущего'),
      'здесь продолжение следует из предыдущего',
    );
    expect(
      tidyDictated('Фильм интересный, продолжение следует ждать осенью'),
      'Фильм интересный, продолжение следует ждать осенью',
    );
    expect(
      tidyDictated('спасибо за внимание к деталям'),
      'спасибо за внимание к деталям',
    );

    // Ведущее тире модель ставит, приняв надиктованное за прямую речь.
    expect(tidyDictated('— привет'), 'привет');
    expect(tidyDictated('-- ну вот'), 'ну вот');
    // А тире внутри фразы — обычный знак.
    expect(tidyDictated('привет — это я'), 'привет — это я');
  });

  test('детекция и удаление всех видов галлюцинаций субтитров и тишины', () {
    // 1. Субтитры и авторство (standalone)
    expect(looksLikeSilenceHallucination('Субтитры сделал DimaTorzok'), isTrue);
    expect(looksLikeSilenceHallucination('субтитры делал DimaTorzok'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры добавил Alex'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры подготовил Иван'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры перевел Пётр'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры перевёл Пётр'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры создал Alex'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры оформил Alex'), isTrue);
    expect(looksLikeSilenceHallucination('Субтитры: DimaTorzok'), isTrue);
    expect(looksLikeSilenceHallucination('субтитры - DimaTorzok'), isTrue);
    expect(looksLikeSilenceHallucination('dimatorzok'), isTrue);
    expect(looksLikeSilenceHallucination('DimaTorzok'), isTrue);
    expect(looksLikeSilenceHallucination('Редактор субтитров А.Синецкая корректор А.Егорова'), isTrue);
    expect(looksLikeSilenceHallucination('Редактор субтитров: А.Синецкая'), isTrue);
    expect(looksLikeSilenceHallucination('Автор субтитров: Alex'), isTrue);
    expect(looksLikeSilenceHallucination('Русские субтитры'), isTrue);
    expect(looksLikeSilenceHallucination('Перевод и субтитры: Студия'), isTrue);
    expect(looksLikeSilenceHallucination('Перевод на русский язык: Studio'), isTrue);
    expect(looksLikeSilenceHallucination('Перевод текста'), isTrue);
    expect(looksLikeSilenceHallucination('Subtitles by John Doe'), isTrue);
    expect(looksLikeSilenceHallucination('Translated by Jane Doe'), isTrue);

    // 2. Окончания и титры фильмов (standalone)
    expect(looksLikeSilenceHallucination('Продолжение следует'), isTrue);
    expect(looksLikeSilenceHallucination('Продолжение следует...'), isTrue);
    expect(looksLikeSilenceHallucination('«Продолжение следует»'), isTrue);
    expect(looksLikeSilenceHallucination('To be continued...'), isTrue);
    expect(looksLikeSilenceHallucination('[To be continued]'), isTrue);
    expect(looksLikeSilenceHallucination('Конец фильма.'), isTrue);
    expect(looksLikeSilenceHallucination('Конец серии.'), isTrue);
    expect(looksLikeSilenceHallucination('Конец связи.'), isTrue);
    expect(looksLikeSilenceHallucination('The end'), isTrue);

    // 3. Концовки видео и призывы к подписке (standalone)
    expect(looksLikeSilenceHallucination('Спасибо за просмотр!'), isTrue);
    expect(looksLikeSilenceHallucination('Спасибо всем за просмотр!'), isTrue);
    expect(looksLikeSilenceHallucination('Спасибо за внимание!'), isTrue);
    expect(looksLikeSilenceHallucination('Большое спасибо за внимание.'), isTrue);
    expect(looksLikeSilenceHallucination('Подписывайтесь на канал!'), isTrue);
    expect(looksLikeSilenceHallucination('Не забудьте подписаться!'), isTrue);
    expect(looksLikeSilenceHallucination('Не забудьте подписаться на канал и поставить лайк!'), isTrue);
    expect(looksLikeSilenceHallucination('Ставьте лайки!'), isTrue);
    expect(looksLikeSilenceHallucination('Thanks for watching!'), isTrue);
    expect(looksLikeSilenceHallucination('Thank you for watching!'), isTrue);
    expect(looksLikeSilenceHallucination('Subscribe to my channel!'), isTrue);
    expect(looksLikeSilenceHallucination('Please subscribe!'), isTrue);
    expect(looksLikeSilenceHallucination('Like and subscribe!'), isTrue);
    expect(looksLikeSilenceHallucination('Please like and subscribe!'), isTrue);
    expect(looksLikeSilenceHallucination("Don't forget to subscribe!"), isTrue);

    // 4. Осмысленная речь НЕ считается галлюцинацией
    expect(looksLikeSilenceHallucination('здесь продолжение следует из предыдущего'), isFalse);
    expect(looksLikeSilenceHallucination('Фильм интересный, продолжение следует ждать осенью'), isFalse);
    expect(looksLikeSilenceHallucination('в конце фильма герои встречаются'), isFalse);
    expect(looksLikeSilenceHallucination('спасибо за внимание к деталям'), isFalse);
    expect(looksLikeSilenceHallucination('подписывайтесь на канал поставки'), isFalse);
    expect(looksLikeSilenceHallucination('редактор субтитров в этой программе работает отлично'), isFalse);
    expect(looksLikeSilenceHallucination('я поставил лайки всем постам'), isFalse);
    expect(looksLikeSilenceHallucination('thanks for watching out for me'), isFalse);

    // 5. Очистка прилипших галлюцинаций (stripSilenceHallucinations)
    // Хвостовые:
    expect(
      stripSilenceHallucinations('...бери какой-нибудь другой цвет. Субтитры сделал DimaTorzok'),
      '...бери какой-нибудь другой цвет.',
    );
    expect(
      stripSilenceHallucinations('бери какой-нибудь другой цвет, субтитры сделал DimaTorzok'),
      'бери какой-нибудь другой цвет',
    );
    expect(
      stripSilenceHallucinations('бери какой-нибудь другой цвет. Редактор субтитров А.Синецкая'),
      'бери какой-нибудь другой цвет.',
    );
    expect(
      stripSilenceHallucinations('бери какой-нибудь другой цвет. Subtitles by John'),
      'бери какой-нибудь другой цвет.',
    );
    expect(
      stripSilenceHallucinations('бери какой-нибудь другой цвет. Translated by Jane'),
      'бери какой-нибудь другой цвет.',
    );
    expect(
      stripSilenceHallucinations('бери какой-нибудь другой цвет. Конец фильма'),
      'бери какой-нибудь другой цвет.',
    );
    expect(
      stripSilenceHallucinations('Привет! Спасибо за просмотр, ставьте лайки!'),
      'Привет!',
    );
    expect(
      stripSilenceHallucinations('Take another color. Like and subscribe!'),
      'Take another color.',
    );
    expect(
      stripSilenceHallucinations('бери другой цвет. Спасибо за просмотр! Подписывайтесь на канал.'),
      'бери другой цвет.',
    );

    // Начальные:
    expect(
      stripSilenceHallucinations('Субтитры сделал DimaTorzok. Привет мир!'),
      'Привет мир!',
    );
    expect(
      stripSilenceHallucinations('Продолжение следует... Привет мир!'),
      'Привет мир!',
    );
    expect(
      stripSilenceHallucinations('Спасибо за просмотр! Начнем урок.'),
      'Начнем урок.',
    );

    // Полная галлюцинация сводится к пустой строке:
    expect(stripSilenceHallucinations('Субтитры сделал DimaTorzok'), '');
    expect(stripSilenceHallucinations('Продолжение следует...'), '');
    expect(stripSilenceHallucinations('Спасибо за просмотр!'), '');

    // Осмысленная речь остаётся нетронутой:
    expect(
      stripSilenceHallucinations('Фильм интересный, продолжение следует ждать осенью'),
      'Фильм интересный, продолжение следует ждать осенью',
    );
    expect(
      stripSilenceHallucinations('здесь продолжение следует из предыдущего'),
      'здесь продолжение следует из предыдущего',
    );
  });

  test('разбор сегментов очищает прилипшие галлюцинации и отбрасывает чистые выдумки', () {
    // whisper parseSegmentLine
    expect(
      parseSegmentLine('[00:00:01.000 --> 00:00:05.000]   Субтитры сделал DimaTorzok'),
      isNull,
    );
    expect(
      parseSegmentLine('[00:00:01.000 --> 00:00:05.000]   Продолжение следует...'),
      isNull,
    );
    final cleanedSeg = parseSegmentLine(
      '[00:00:01.000 --> 00:00:05.000]   ...бери какой-нибудь другой цвет. Субтитры сделал DimaTorzok',
    );
    expect(cleanedSeg, isNotNull);
    expect(cleanedSeg!.text, '...бери какой-нибудь другой цвет.');

    // whisper parseWhisperJson
    final whisperJson = jsonEncode({
      'result': {'language': 'ru'},
      'transcription': [
        {
          'offsets': {'from': 0, 'to': 2000},
          'text': 'Первое предложение.',
        },
        {
          'offsets': {'from': 2000, 'to': 4000},
          'text': 'Субтитры сделал DimaTorzok',
        },
        {
          'offsets': {'from': 4000, 'to': 6000},
          'text': 'Второе предложение. Спасибо за просмотр!',
        },
      ],
    });
    final whisperTranscript = parseWhisperJson(whisperJson);
    expect(whisperTranscript.segments, hasLength(2));
    expect(whisperTranscript.segments[0].text, 'Первое предложение.');
    expect(whisperTranscript.segments[1].text, 'Второе предложение.');

    // nemo parseNemoJson
    final nemoJson = jsonEncode({
      'text': 'Первое предложение. Субтитры сделал DimaTorzok',
      'duration': 4.0,
      'languages': ['ru-RU'],
      'words': [
        {'word': 'Первое', 'start': 0.1, 'end': 0.5},
        {'word': 'предложение.', 'start': 0.5, 'end': 1.0},
        {'word': 'Субтитры', 'start': 2.0, 'end': 2.5},
        {'word': 'сделал', 'start': 2.5, 'end': 3.0},
        {'word': 'DimaTorzok', 'start': 3.0, 'end': 3.5},
      ],
    });
    final nemoTranscript = parseNemoJson(nemoJson);
    expect(nemoTranscript.segments, hasLength(1));
    expect(nemoTranscript.segments.single.text, 'Первое предложение.');
  });

  test('подписи сочетаний читаются как в системе', () {
    // Сочетание по умолчанию — не одно на все системы: на Windows
    // клавиши fn у программ нет вовсе, и сочетание с ней там никогда
    // бы не сработало.
    if (Platform.isMacOS) {
      expect(Hotkey.holdDefault.label, 'fn + ⌃');
      expect(Hotkey.toggleDefault.label, 'fn + Пробел');
    }
    expect(Hotkey.holdDefault.mods, os.defaultHold.mods);
    expect(Hotkey.toggleDefault.keys, os.defaultToggle.keys);
    expect(const Hotkey([], keys: ['f13']).label, 'F13');
    expect(const Hotkey([]).label, 'Не назначено');

    // Годится любая клавиша и любое их число: раньше обычную букву
    // в одиночку назначить было нельзя вовсе.
    expect(const Hotkey([], keys: ['y']).label, 'Y');
    expect(const Hotkey([], keys: ['x', 'y']).label, 'X + Y');
    // Модификаторы каждая система пишет по-своему: на macOS значками
    // и строчным «fn», на Windows словами — «Fn». Спрашиваем у неё же.
    expect(const Hotkey(['fn'], keys: ['o']).label,
        '${os.modifierLabel('fn')} + O');
    // Порядок клавиш не зависит от того, в каком их нажали.
    expect(const Hotkey([], keys: ['y', 'x']).label,
        const Hotkey([], keys: ['x', 'y']).label);
    // Незнакомую клавишу называем её кодом — назначить можно любую.
    expect(const Hotkey([], keys: ['#57']).label, '#57');
    // круг через JSON ничего не теряет
    final back = Hotkey.fromJson(Hotkey.toggleDefault.toJson(), Hotkey.holdDefault);
    expect(back.label, Hotkey.toggleDefault.label);
    // мусор в файле настроек не должен ронять диктовку: возвращается
    // умолчание, а какое оно — дело системы (на Windows fn нет вовсе)
    expect(Hotkey.fromJson('чепуха', Hotkey.holdDefault).label,
        Hotkey.holdDefault.label);
    // настройки прежних сборок: там клавиша была одна
    expect(
      Hotkey.fromJson({'mods': ['fn'], 'key': 'space'}, Hotkey.holdDefault).keys,
      ['space'],
    );
  });


  test('VAD-модель качается из своего репозитория и не путается с речевой', () {
    // В ggerganov/whisper.cpp файла silero нет вовсе — оттуда приходит 404.
    expect(vadModelUrl, contains('ggml-org/whisper-vad'));
    expect(vadModelUrl.endsWith(vadModelFile), isTrue);
    // Ложится туда же, куда смотрит findModels(), — иначе её нечем подхватить.
    expect(vadModelPath, os.join(supportDir, 'models', vadModelFile));
    // Но в списке моделей распознавания ей не место: выбрав её, человек
    // получил бы пустую расшифровку.
    expect(looksLikeSpeechModel(vadModelFile), isFalse);
    expect(looksLikeSpeechModel('ggml-large-v3-turbo.bin'), isTrue);
    expect(looksLikeSpeechModel('Nemotron-3-Diarization.q8_0.gguf'), isFalse);
    expect(looksLikeSpeechModel('parakeet-tdt-0.6b-v3.q8_0.gguf'), isTrue);
    expect(
        looksLikeSpeechModel(
            'nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'),
        isTrue);
    expect(looksLikeSpeechModel('ggml-tiny.bin.part'), isFalse);
    expect(looksLikeSpeechModel('заметки.txt'), isFalse);
  });

  test('каталог моделей: ссылки в один репозиторий, файлы в свою папку', () {
    expect(modelCatalog.length, 8);
    for (final m in modelCatalog) {
      expect(looksLikeSpeechModel(m.file), isTrue, reason: m.file);
      // Ложится в папку, которую findModels() уже просматривает, — иначе
      // скачанное не появится в списке.
      expect(m.path, os.join(supportDir, 'models', m.file));
      expect(Uri.parse(m.url).host, 'huggingface.co');
      expect(m.mb, greaterThan(0));
      expect(m.about, isNotEmpty);
      expect(m.engine, engineForModel(m.file));
    }
    // Имена не повторяются: иначе две строки каталога боролись бы за один файл.
    expect(modelCatalog.map((m) => m.file).toSet().length, modelCatalog.length);
    // Размер читается человеком: мегабайты до гигабайта, дальше гигабайты.
    expect(modelCatalog.first.size, '74 МБ');
    expect(sizeLabelMb(1549), '1,5 ГБ');
    final nemo = modelCatalog[6];
    expect(nemo.file, 'nemotron-3.5-asr-streaming-0.6b.q8_0.gguf');
    expect(nemo.engine, RecognitionEngine.nemoSpeechCpp);
    expect(nemo.languages, ModelLanguageScope.fortyPlus);
    expect(nemo.focus, ModelFocus.live);
    expect(nemo.supportsPrompt, isTrue);
    expect(nemo.url, contains('nvidia/nemotron-3.5-asr-streaming-0.6b'));
    expect(nemo.url, contains('1c8deaecc64b91f034d73e08dd8b64625eb3395d'));
    final parakeet = modelCatalog.last;
    expect(parakeet.file, 'parakeet-tdt-0.6b-v3.q8_0.gguf');
    expect(parakeet.engine, RecognitionEngine.nemoSpeechCpp);
    expect(parakeet.languages, ModelLanguageScope.european25);
    expect(parakeet.focus, ModelFocus.fast);
    expect(parakeet.supportsPrompt, isFalse);
    expect(parakeet.url, contains('nvidia/parakeet-tdt-0.6b-v3'));
    expect(parakeet.url, contains('541d1f99c6b0c3cd0b11a95167540bb8edefd82b'));
  });

  test('модель везде называется одинаково', () {
    // Каталог, панель и инспектор берут имя из одной функции.
    expect(modelCatalog.map((m) => m.title).toList(),
        ['Tiny', 'Base', 'Small', 'Medium', 'Large v3 Turbo', 'Large v3',
          'Nemotron 3.5 ASR Streaming 0.6b', 'Parakeet TDT 0.6b v3']);
    expect(modelDisplayName('/x/ggml-large-v3-turbo.bin'), 'Large v3 Turbo');
    // Чужой файл: модель из папки соседнего приложения.
    expect(
        modelDisplayName(
            '/Users/x/Library/Application Support/com.example.речь/models/ggml-large.bin'),
        'Large');
    expect(modelDisplayName('/x/ggml-small.en.bin'), 'Small En');
    expect(
        modelDisplayName(
            '/x/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'),
        'Nemotron 3.5 ASR Streaming 0.6b');
    expect(modelDisplayName('/x/parakeet-tdt-0.6b-v3.q8_0.gguf'),
        'Parakeet TDT 0.6b v3');
    // Квантование и версии остаются как есть — их не «причёсывают».
    expect(modelDisplayName('/x/ggml-large-v3-q5_0.bin'), 'Large v3 q5_0');
    // Даже совсем не ggml-файл не должен показываться пустотой.
    expect(modelDisplayName('/x/my-model.bin'), 'My Model');
    expect(modelDisplayName('/x/ggml-.bin'), 'ggml-.bin');
  });

  test('загрузка не выдаёт недокачанное за готовый файл', () async {
    final dir = Directory.systemTemp.createTempSync('tsukiko_dl');
    final dest = '${dir.path}/ggml-tiny.bin';
    // В сеть не ходим: закрытый порт проходит тот же путь, что и обрыв связи.
    final failed = Download('http://127.0.0.1:9/нет.bin', dest);
    expect(await failed.run(), isNull);
    expect(File(dest).existsSync(), isFalse);
    // Кнопка повтора без объяснения бесполезна: причина нужна словами,
    // а не текстом исключения.
    expect(failed.error, 'нет связи с 127.0.0.1');

    // Ответ сервера — совсем другая беда, и звучать должна иначе.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      r.response.statusCode = 404;
      r.response.close();
    });
    final missing = Download('http://127.0.0.1:${server.port}/нет.bin', dest);
    expect(await missing.run(), isNull);
    expect(missing.error, '127.0.0.1 ответил 404');
    await server.close(force: true);

    // Уже готовый файл повторно не качается.
    File(dest).writeAsStringSync('уже есть');
    expect(await Download('http://127.0.0.1:9/нет.bin', dest).run(), dest);
    dir.deleteSync(recursive: true);
  });

  test('свободный порт достаётся от ядра и повторно не выдаётся', () async {
    final a = await freePort(), b = await freePort();
    expect(a, greaterThan(1024));
    expect(a, isNot(b));
  });

  test('whisper-server держит модель и распознаёт фразу за доли секунды',
      () async {
    // Это единственный тест, который поднимает настоящий сервер: без него
    // проверить главную идею (модель живёт между фразами) нечем.
    final models = findModels();
    if (findWhisperServer() == null || models.isEmpty) return;

    // Настоящая короткая речь проверяет весь путь ответа сервера.
    final wav = File('test/fixtures/ru_smoke.wav').absolute.path;

    await withTempSupportDir('tsukiko-real-server', () async {
      // И путь модели тоже должен носить временную метку. Старые сборки
      // приложения узнавали свой сервер по папке данных целиком; если
      // оставить здесь настоящий путь модели, соседний тест уборки увидит
      // его в аргументах и всё равно примет процесс за своего сироту.
      final isolatedModel = os.join(os.modelsDir, os.basename(models.first));
      Link(isolatedModel).createSync(models.first);
      final server = WhisperServer(idleTimeout: const Duration(seconds: 30));
      try {
        await server.ensureUp(RunOptions(
            model: isolatedModel, lang: 'ru', threads: 4, punctuate: false));
        expect(server.up, isTrue);
        expect(await server.waitReady(timeout: const Duration(seconds: 60)), isTrue);

        // Модель в памяти — значит процесс весит как она сама, а не как заглушка.
        expect(await server.footprintMb(), greaterThan(200));

        // Первая фраза уже на прогретой модели: секунда с запасом.
        final started = DateTime.now();
        final recognized = await server.transcribe(wav, lang: 'ru');
        expect(recognized?.toLowerCase(), contains('привет'));
        expect(DateTime.now().difference(started).inSeconds, lessThan(10));

        // Таймер простоя сдвигается каждым обращением.
        expect(server.untilUnload!.inSeconds, greaterThan(25));

        // Главное: пока идёт запись, простой не считается вовсе. Иначе модель
        // выгружалась посреди длинной фразы, и надиктованное пропадало.
        server.idleTimeout = const Duration(milliseconds: 300);
        server.hold();
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(server.up, isTrue, reason: 'аренда обязана пережить таймаут');
        expect(server.untilUnload, isNull);

        // Отпущенная аренда возвращает всё как было: память не наша.
        server.release();
        expect(server.untilUnload!.inMilliseconds, lessThan(400));
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(server.up, isFalse);
      } finally {
        await server.shutdown();
      }
      expect(server.up, isFalse);
      expect(server.untilUnload, isNull);
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('сирота узнаётся по метке в аргументах, а чужой сервер — нет', () {
    final processes = <ProcListing>[
      (
        pid: 501,
        rssKb: 1657392,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '--tmp-dir $serverMark'
      ),
      (
        pid: 502,
        rssKb: 42000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/чужая.bin --port 9000'
      ),
      (
        pid: 503,
        rssKb: 1600000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '-vm ${os.join(supportDir, 'models/silero.bin')}'
      ),
      (
        pid: 504,
        rssKb: 1500000,
        args: '/opt/homebrew/bin/whisper-server -m /Users/x/m.bin '
            '--tmp-dir $legacyServerMark'
      ),
      (
        pid: 506,
        rssKb: 900000,
        args: '/opt/homebrew/bin/nemo-speech serve --asr-model /Users/x/m.gguf '
            '--cors-origin $serverMark'
      ),
      (pid: 505, rssKb: 9000, args: '/Applications/Чужое.app/Contents/MacOS/Чужое'),
    ];
    final ours = ourServersIn(processes);
    // Свои — по нынешней метке, по папке приложения и по метке прежних
    // сборок. Чужой whisper-server и чужое приложение остаются нетронутыми.
    expect(ours.map((s) => s.pid), [501, 503, 504, 506]);
    expect(ours.first.rssKb, 1657392);
  });

  // Подставной сервер поднимается через /bin/sh: на Windows оболочки
  // с таким именем нет вовсе. Само правило — «свой узнаётся по метке
  // в аргументах» — проверяет соседний тест, и он идёт всюду.
  test('забытый сервер находится без pid-файла и гасится наверняка',
      skip: !Platform.isMacOS, () async {
    // Настоящий whisper-server ради этого не поднимаем: проверять надо две
    // вещи — что процесс с нашей меткой виден в ps и что упрямый процесс
    // всё-таки гибнет. «trap "" TERM» — это и есть поведение
    // whisper-server, из-за которого сирота жила часами.
    final fake = await Process.start('/bin/sh', [
      '-c',
      'trap "" TERM; sleep 30 # whisper-server $serverMark',
    ]);
    addTearDown(() => Process.killPid(fake.pid, ProcessSignal.sigkill));

    final found = ourServersIn(await os.listProcesses()).map((s) => s.pid);
    expect(found, contains(fake.pid), reason: 'pid-файла нет, а процесс виден');

    expect(processAlive(fake.pid), isTrue);
    // SIGTERM его не берёт — из-за этого сервер и оставался жить.
    Process.killPid(fake.pid, ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(processAlive(fake.pid), isTrue);

    expect(await killForSure(fake.pid), isTrue);
    expect(processAlive(fake.pid), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('в модель распознавания годится не всякий .bin', () {
    final dir = Directory.systemTemp.createTempSync('tsukiko_model');
    addTearDown(() => dir.deleteSync(recursive: true));

    // Метка ggml на диске — «lmgg», следом размер словаря числом.
    List<int> head(int vocab) => [
          ...'lmgg'.codeUnits,
          vocab & 0xFF,
          (vocab >> 8) & 0xFF,
          (vocab >> 16) & 0xFF,
          (vocab >> 24) & 0xFF,
        ];
    File file(String name, List<int> bytes) =>
        File('${dir.path}/$name')..writeAsBytesSync(bytes);

    final junk = file('модель.bin', List.filled(30 * 1024 * 1024, 7));
    expect(modelFileProblem(junk.path), contains('не модель распознавания'));

    // Модель тишины — тоже ggml, но словарь у неё в десять слов.
    final vad = file('ggml-silero.bin', [...head(10), ...List.filled(900000, 0)]);
    expect(modelFileProblem(vad.path), contains('тишины'));

    final tiny = file('ggml-tiny.bin', head(51865));
    expect(modelFileProblem(tiny.path), contains('слишком мал'));

    final good = file('ggml-ok.bin',
        [...head(51865), ...List.filled(30 * 1024 * 1024, 0)]);
    expect(modelFileProblem(good.path), isNull);

    final gguf = file('nemotron.gguf', 'GGUF'.codeUnits);
    gguf.openSync(mode: FileMode.append)
      ..truncateSync(30 * 1024 * 1024)
      ..closeSync();
    expect(modelFileProblem(gguf.path), isNull);

    final fakeGguf = file('подделка.gguf', 'NOPE'.codeUnits);
    fakeGguf.openSync(mode: FileMode.append)
      ..truncateSync(30 * 1024 * 1024)
      ..closeSync();
    expect(modelFileProblem(fakeGguf.path), contains('не модель распознавания'));

    expect(engineForModel(good.path), RecognitionEngine.whisperCpp);
    expect(engineForModel(gguf.path), RecognitionEngine.nemoSpeechCpp);

    expect(modelFileProblem('${dir.path}/нет.bin'), contains('больше нет'));

    // И на настоящих файлах, если они есть на этой машине.
    for (final m in findModels()) {
      expect(modelFileProblem(m), isNull, reason: m);
    }
    if (File(vadModelPath).existsSync()) {
      expect(modelFileProblem(vadModelPath), isNotNull);
    }
  });
}

void _hotkeyTaps() {
  group('физические модификаторы', () {
    test('левая и правая стороны различаются, старое общее имя совместимо',
        () {
      const left = Hotkey(['leftctrl']);
      const right = Hotkey(['rightctrl']);
      const legacy = Hotkey(['ctrl']);

      expect(left.sameAs(right), isFalse);
      expect(left.sameAs(legacy), isTrue,
          reason: 'старый Ctrl срабатывает и от левого Ctrl');
      expect(right.sameAs(legacy), isTrue);
      expect(left.label, contains('L'));
      expect(right.label, contains('R'));
    });

    test('одиночная клавиша требует согласия, двойной стук — нет', () {
      expect(const Hotkey(['leftctrl']).requiresExclusiveConsent, isTrue);
      expect(const Hotkey([], keys: ['y']).requiresExclusiveConsent, isTrue);
      expect(
          const Hotkey(['leftctrl'], taps: 2).requiresExclusiveConsent, isFalse);
      expect(
        const Hotkey(['leftctrl'], keys: ['space'])
            .requiresExclusiveConsent,
        isFalse,
      );
    });
  });

  group('двойное нажатие', () {
    test('число стуков хранится и читается', () {
      const twice = Hotkey(['fn'], taps: 2);
      expect(twice.isDouble, isTrue);
      final back = Hotkey.fromJson(twice.toJson(), Hotkey.holdDefault);
      expect(back.taps, 2);
      expect(back.mods, ['fn']);
      // Настройки прежних сборок про стуки не знали — там нажатие одно.
      expect(
        Hotkey.fromJson({'mods': ['fn'], 'keys': ['space']}, Hotkey.holdDefault)
            .taps,
        1,
      );
    });

    test('одиночное и двойное — разные жесты', () {
      // Иначе на два действия нельзя было бы повесить одни и те же клавиши.
      expect(const Hotkey(['fn']).sameAs(const Hotkey(['fn'], taps: 2)), isFalse);
      expect(const Hotkey(['fn'], taps: 2).label, contains('дважды'));
    });
  });

  group('сочетание на дороге к другому', () {
    test('входящее целиком срабатывает раньше', () {
      // Ровно та пара, что стояла умолчанием на Windows: чтобы нажать
      // Ctrl+Alt+Пробел, надо пройти через Ctrl+Alt, — и «держать
      // и говорить» начинало запись, не дожидаясь пробела.
      const hold = Hotkey(['ctrl', 'alt']);
      const toggle = Hotkey(['ctrl', 'alt'], keys: ['space']);
      expect(hold.isPrefixOf(toggle), isTrue);
      expect(toggle.isPrefixOf(hold), isFalse);
      // Порядок в наборе значения не имеет.
      expect(const Hotkey(['alt', 'ctrl']).isPrefixOf(toggle), isTrue);
      // Само себе дорогой не считается: это «уже назначено», другая беда.
      expect(hold.isPrefixOf(const Hotkey(['alt', 'ctrl'])), isFalse);
      // Разные наборы модификаторов друг другу не мешают.
      expect(hold.isPrefixOf(const Hotkey(['ctrl', 'shift'], keys: ['space'])),
          isFalse);
      // Двойной стук по дороге не срабатывает: первое нажатие только
      // взводит, а второго на пути к чужому сочетанию не случится.
      expect(const Hotkey(['ctrl', 'alt'], taps: 2).isPrefixOf(toggle), isFalse);
      // Пустое сочетание не мешает никому.
      expect(const Hotkey([]).isPrefixOf(toggle), isFalse);
    });

    test('умолчания этой системы такой пары не образуют', () {
      // Проверка на обе системы разом: на той, где идёт тест, берутся
      // её собственные умолчания. Форму макосной пары однажды уже
      // перенесли на Windows без её смысла — и получили приставку.
      final hold = Hotkey.holdDefault;
      final toggle = Hotkey.toggleDefault;
      expect(hold.isPrefixOf(toggle), isFalse);
      expect(toggle.isPrefixOf(hold), isFalse);
      expect(hold.sameAs(toggle), isFalse);
    });
  });


  test('окно не наследует текст предыдущего — иначе повтор кормит сам себя', () {
    const hint = 'Минина, Сытый двор, Рында';
    final args = buildArgs(
        const RunOptions(model: 'm', lang: 'ru', threads: 4, prompt: hint),
        '/a.wav', '/o');
    expect(args.contains('-mc'), isTrue);
    expect(args[args.indexOf('-mc') + 1], '0');
    // Комплектный движок отделяет initial prompt от нулевого бюджета
    // истории: подсказка должна быть и передана, и возвращена в каждое
    // окно. Иначе все три флага формально есть, но словарь не действует.
    expect(args.contains('--carry-initial-prompt'), isTrue);
    expect(args[args.indexOf('--prompt') + 1], hint);
  });

  test('движок работает под своим именем и остаётся тем же движком', () {
    final exe = findWhisper();
    if (exe == null) return;
    final named = runnableWhisper(exe, recognizerExeName);
    expect(named, isNotNull);
    expect(os.basename(named!), recognizerExeName);
    if (named != exe) {
      // Системный движок зовут не так — ведём к нему ссылку. Ссылка,
      // а не копия: копия теряет свои библиотеки. И ведёт туда же, куда
      // ведёт поиск, иначе запустился бы вчерашний движок.
      expect(Link(named).targetSync(), exe);
    }
    // Второй заход не спотыкается о готовую ссылку.
    expect(runnableWhisper(exe, recognizerExeName), named);
  });

  test('свой движок лежит внутри приложения и главнее системного', () {
    // В тестах приложения нет — есть только системный, если он вообще
    // установлен. Проверяем само правило: свой берётся из бандла, а поиск
    // по системе остаётся запасным путём.
    expect(bundledEngine(recognizerExeName), isNull,
        reason: 'тест бежит не из .app');
    expect(engineIsOurs, isFalse);
    expect(findWhisper(), os.findExecutable('whisper-cli'));
    // Своему движку ссылка не нужна: он уже назван как надо.
    expect(runnableWhisper('/x/$recognizerExeName', recognizerExeName),
        '/x/$recognizerExeName');
  });

  group('несработавшая сборка движка вычёркивается на весь сеанс', () {
    useTempSupportDir('tsukiko-engine');
    setUp(forgetDeadEngines);
    tearDown(forgetDeadEngines);

    test('после вычёркивания берётся следующая по списку', () {
      // Vulkan-сборку роняет старый драйвер видеокарты — не на запуске
      // приложения, а на каждой записи. Без вычёркивания она выбиралась
      // бы снова и снова, и распознавание не работало бы никогда.
      Directory(os.engineDir).createSync(recursive: true);
      final names = os.engineNames(recognizerExeName);
      if (names.length < 2) return; // на macOS сборка одна, выбирать не из чего
      for (final name in names) {
        File(os.join(os.engineDir, name)).writeAsStringSync('');
      }
      final first = bundledEngine(recognizerExeName);
      expect(first, os.join(os.engineDir, names.first));

      expect(engineFailedToStart(first!, recognizerExeName), isTrue);
      expect(bundledEngine(recognizerExeName), os.join(os.engineDir, names[1]));

      // Вычеркнули все — предлагать больше нечего, и об этом честно
      // сообщается: зовущему незачем пробовать ещё раз.
      for (final name in names.skip(1)) {
        engineFailedToStart(os.join(os.engineDir, name), recognizerExeName);
      }
      expect(bundledEngine(recognizerExeName), isNull);
    });

    test('павший сервер диктовки вычёркивает свою сборку, а не молчит', () async {
      // Ровно то, что случилось на машине хозяина: Vulkan-сборка сервера
      // диктовки падает сразу после запуска, порт не открывается никогда.
      // Раньше `transcribe` видел мёртвый процесс и возвращал «не
      // распознал», не дойдя до вычёркивания, — и следующая фраза
      // поднимала ту же сборку заново. Проверяем, что теперь сборка
      // вычёркивается: после попытки предлагать больше нечего.
      Directory(os.engineDir).createSync(recursive: true);
      // Программа, которая мгновенно завершается: точная модель павшего
      // движка. Своей писать нельзя — тесты идут и на Windows, где нет
      // ни shell-скриптов, ни chmod.
      final quick = Platform.isWindows
          ? os.join(Platform.environment['SystemRoot'] ?? r'C:\Windows',
              'System32', 'hostname.exe')
          : '/bin/echo';
      if (!File(quick).existsSync()) return;
      for (final name in os.engineNames(dictationExeName)) {
        final path = os.join(os.engineDir, name);
        File(quick).copySync(path);
        if (!Platform.isWindows) await Process.run('chmod', ['+x', path]);
      }
      expect(bundledEngine(dictationExeName), isNotNull);

      final server = WhisperServer();
      final model = os.join(os.modelsDir, 'ggml-fake.bin');
      File(model).writeAsStringSync('');
      await server.ensureUp(RunOptions(model: model, lang: 'ru', threads: 1));
      // Ждём, пока процесс действительно умрёт: в жизни между подъёмом
      // сервера и расшифровкой лежит вся запись, и к её концу павшей
      // сборки давно нет. Без этого ожидания тест ловил бы гонку, а не
      // ту самую дыру.
      for (var i = 0; i < 200 && server.up; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.up, isFalse, reason: 'подсадная сборка должна была умереть');
      expect(await server.transcribe(model), isNull);
      expect(bundledEngine(dictationExeName), isNull,
          reason: 'все сборки, которые не поднялись, должны быть вычеркнуты');
      await server.shutdown();
    });
  });

  test('продолжение считает с места остановки, а не с начала записи', () {
    const o = RunOptions(model: 'm', lang: 'ru', threads: 4);
    expect(buildArgs(o, '/a.wav', '/o').contains('-ot'), isFalse);
    final again = buildArgs(o, '/a.wav', '/o', from: 600000);
    expect(again[again.indexOf('-ot') + 1], '600000');
  });

  test('подряд идущий повтор сворачивается в один сегмент', () {
    final segs = [
      const Segment(0, 1000, 'Начало.'),
      for (var i = 0; i < 5; i++) Segment(1000 + i * 1000, 2000 + i * 1000, 'Врезок.'),
      const Segment(7000, 8000, 'Конец.'),
      const Segment(8000, 9000, 'Да.'),
      const Segment(9000, 10000, 'Да.'),
    ];
    final out = collapseRepeats(segs);
    expect(out.map((s) => s.text).toList(),
        ['Начало.', 'Врезок.', 'Конец.', 'Да.', 'Да.']);
    expect(out[1].from, 1000);
    expect(out[1].to, 6000);
  });
}
