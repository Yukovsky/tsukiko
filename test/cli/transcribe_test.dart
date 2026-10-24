import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/cli/transcribe.dart';
import 'package:tsukiko/platform/os.dart';

import '../support/fake_os.dart';

/// `tsukiko-transcribe` — расшифровка без приложения.
///
/// Сам счёт здесь не проверяется: он идёт теми же `buildArgs` и тем же
/// разбором, что и в приложении, и проверен в `test/core/engine_test.dart`
/// на настоящем движке. Проверяется то, что у этой программы своё:
/// разбор командной строки, откуда берутся настройки и как она отвечает
/// на «а всё ли готово».
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-cli');

  test('ядро расшифровки собирается без Flutter', () {
    // Не педантизм, а условие существования: `dart compile exe` не
    // соберёт ничего, что тянет package:flutter, а из этих файлов растёт
    // tsukiko-transcribe. Стоит кому-нибудь дописать сюда подпись через
    // currentL10n() — и программа расшифровки перестанет собираться.
    // Узнать об этом лучше здесь, чем на выпуске.
    final pure = [
      'lib/core/whisper.dart',
      'lib/core/transcript.dart',
      'lib/core/speakers.dart',
      'lib/core/diarization/wav_samples.dart',
      'lib/core/library.dart',
      'lib/core/recognition.dart',
      'lib/cli/transcribe.dart',
      'lib/platform/os.dart',
      'lib/platform/os_macos.dart',
      'lib/platform/os_windows.dart',
    ];
    for (final f in pure) {
      // Именно импорт, а не любое упоминание: про Flutter в этих файлах
      // написано прозой, и как раз затем, чтобы его сюда не втащили.
      expect(File(f).readAsStringSync(), isNot(contains("import 'package:flutter")),
          reason: '$f тянет Flutter — tsukiko-transcribe больше не соберётся');
      // Нативной библиотеки sherpa у программы расшифровки тоже нет:
      // разметка голосов живёт в `core/diarization/diarizer.dart`.
      expect(File(f).readAsStringSync(), isNot(contains("import 'package:sherpa")),
          reason: '$f тянет sherpa-onnx — ему не место в tsukiko-transcribe');
    }
  });

  group('командная строка', () {
    test('файл и формат', () {
      final a = parseArgs(['--format', 'srt', '/tmp/раз.m4a']);
      expect(a.problem, isNull);
      expect(a.format, 'srt');
      expect(a.files, ['/tmp/раз.m4a']);
    });

    test('молчаливого отказа не бывает: на каждую беду своя жалоба', () {
      expect(parseArgs([]).problem, contains('какой файл'));
      expect(parseArgs(['--format', 'docx', 'а.m4a']).problem, contains('docx'));
      expect(parseArgs(['--выдумка', 'а.m4a']).problem, contains('незнакомый'));
      expect(parseArgs(['а.m4a', 'б.m4a']).problem, contains('один файл'));
      expect(parseArgs(['--lang']).problem, isNotNull);
    });

    test('--speakers: «auto» или число', () {
      expect(parseArgs(['а.m4a']).speakers, isNull);
      expect(parseArgs(['--speakers', 'auto', 'а.m4a']).speakers, 0);
      expect(parseArgs(['--speakers', '3', 'а.m4a']).speakers, 3);
      expect(
        parseArgs(['--speakers', 'много', 'а.m4a']).problem,
        contains('--speakers'),
      );
    });

    test('--status и --help файла не требуют', () {
      expect(parseArgs(['--status']).problem, isNull);
      expect(parseArgs(['--help']).problem, isNull);
    });
  });

  group('настройки', () {
    test('ключ командной строки главнее файла настроек', () {
      File(os.join(os.supportDir, 'settings.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"lang":"ru","threads":8,"model":"/нет.bin"}');
      final o = optionsFrom(parseArgs(['--lang', 'en', 'а.m4a']));
      expect(o.lang, 'en');
      expect(o.threads, 8);
    });

    test('ключ --prompt дополняет подсказку модели', () {
      final o = optionsFrom(parseArgs(['--prompt', 'Gemini, Claude', 'а.m4a']));
      expect(o.prompt, 'Gemini, Claude');
    });

    test('без файла настроек программа всё равно знает, чем считать', () {
      final o = optionsFrom(parseArgs(['а.m4a']));
      expect(o.lang, 'auto');
      expect(o.threads, greaterThanOrEqualTo(2));
    });

    test('выбранная в приложении модель берётся, если она на месте', () {
      final model = File(os.join(os.modelsDir, 'ggml-tiny.bin'))
        ..writeAsStringSync('модель');
      File(os.join(os.supportDir, 'settings.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"model": ${_json(model.path)}}');
      expect(optionsFrom(parseArgs(['а.m4a'])).model, model.path);
    });

    test('пропавшая модель заменяется той, что лежит в папке', () {
      File(os.join(os.modelsDir, 'ggml-base.bin')).writeAsStringSync('модель');
      // Модель распознавания пауз речью не занимается — в замену не годится.
      File(os.join(os.modelsDir, 'ggml-silero-v5.1.2.bin'))
          .writeAsStringSync('пауза');
      File(os.join(os.supportDir, 'settings.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"model":"/которой/нет.bin"}');
      expect(optionsFrom(parseArgs(['а.m4a'])).model,
          os.join(os.modelsDir, 'ggml-base.bin'));
    });

    test('GGUF-модель NeMo тоже берётся из папки приложения', () {
      final model = File(os.join(os.modelsDir, 'parakeet.gguf'))
        ..writeAsStringSync('GGUF');
      File(os.join(os.supportDir, 'settings.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"model":"/которой/нет.bin"}');
      expect(optionsFrom(parseArgs(['а.m4a'])).model, model.path);
    });
  });

  test('«что установлено» отвечает и без модели, и без приложения', () async {
    final s = await status();
    // Главное — что ответ есть и он про готовность: скилл по нему
    // объясняет человеку, чего не хватает.
    expect(s['app'], appName);
    expect(s.containsKey('ready'), isTrue);
    expect(s.containsKey('engineKind'), isTrue);
    expect(s['modelExists'], isFalse);
    expect(s['appApi'], isFalse);
  });
}

String _json(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
