import 'dart:async';
import 'dart:io';
import 'package:tsukiko/platform/os.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/features/dictation/dictation_history.dart';
import 'package:tsukiko/core/whisper.dart';

import '../../support/fake_os.dart';

/// Логика диктовки, которую до выноса из виджета проверять было нечем.
///
/// Родная сторона подменена: канал отвечает нашими значениями, и весь
/// разговор с macOS сводится к списку вызовов, который можно прочитать.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  useTempSupportDir('tsukiko-dictation-commands');

  late _FakeNative native;
  late _FakeServer server;
  late DictationCubit cubit;

  setUp(() {
    // Строки из кубита идут через currentL10n(), который читает системный
    // локаль. Тестовый движок отдаёт en_US — здесь же тексты сверены
    // с русским, поэтому закрепляем его явно.
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    // Мост в приложении один на изолят, и он это стережёт. Каждому тесту
    // нужен свой — снимаем сторожа.
    NativeBridge.debugReset();
    cubit = DictationCubit(NativeBridge(), server: server);
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  /// Дать очереди микрозадач провернуться: почти всё в кубите асинхронно.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('запись', () {
    test('видимость применяется к текущей записи сразу', () async {
      await cubit.start();
      final settings = DictationSettings.load();
      settings.hud = false;
      settings.save();
      await cubit.reloadSettingsForTesting();
      expect(native.hudStates.last, 'recording');
      expect(native.hudModes.last, 'off');
      expect(cubit.state.recording, isTrue);
      settings.hud = true;
      settings.save();
      await cubit.reloadSettingsForTesting();
      expect(native.hudStates.last, 'recording');
      expect(native.calls.where((call) => call == 'record').length, 1);
    });
    test(
      'редактор меняет все стили при записи и при незавершённой расшифровке',
      () async {
        await cubit.start();
        await settle();
        final binds = native.calls.where((call) => call == 'bind').length;
        Future<void> mode(IndicatorMode value) async {
          await binding.defaultBinaryMessenger.handlePlatformMessage(
            'tsukiko/dictation',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('hudMode', value.name),
            ),
            (_) {},
          );
          await settle();
          expect(DictationSettings.load().indicatorMode, value);
          expect(native.hudModes.last, value.name);
          expect(
            native.calls.where((call) => call == 'bind').length,
            binds,
            reason: 'appearance must preserve the held shortcut latch',
          );
        }

        for (final value in IndicatorMode.values.skip(1)) {
          await mode(value);
          expect(native.hudStates.last, 'recording');
          expect(cubit.state.recording, isTrue);
        }
        server.gate = Completer<String?>();
        final completion = cubit.stop();
        await settle();
        expect(cubit.state.processing, isTrue);
        for (final value in IndicatorMode.values) {
          await mode(value);
          expect(native.hudStates.last, 'transcribing');
          expect(cubit.state.processing, isTrue);
        }
        expect(native.calls.where((call) => call == 'record').length, 1);
        expect(native.calls.where((call) => call == 'stopRecord').length, 1);
        server.gate!.complete('Сохранённый результат');
        await completion;
      },
    );
    test('старая команда не перегружает модель подсказкой', () async {
      await Settings.save({
        textCommandsSetting: [
          const TextCommand('адрес офиса', 'Минск').toJson(),
        ],
        dictationCommandsEnabledSetting: true,
      });
      await cubit.reloadSettingsForTesting();

      expect(
        cubit.optionsForTesting.effectivePrompt,
        isNot(contains('адрес офиса')),
      );
    });

    test('начинается и переходит в распознавание', () async {
      await cubit.start();
      expect(cubit.state.phase, Phase.recording);
      expect(native.calls, contains('record'));

      await cubit.stop();
      expect(cubit.state.phase, Phase.idle);
    });

    test('второе нажатие во время записи ничего не начинает заново', () async {
      await cubit.start();
      final startedAt = cubit.state.elapsed;
      await cubit.start();
      expect(cubit.state.phase, Phase.recording);
      expect(cubit.state.elapsed, startedAt);
      // Микрофон просили ровно один раз.
      expect(native.calls.where((c) => c == 'record').length, 1);
    });

    test('отмена во время записи уходит молча и без вставки', () async {
      await cubit.start();
      await cubit.cancel();

      expect(cubit.state.phase, Phase.idle);
      expect(cubit.state.failure, isNull, reason: 'передумал — не беда');
      expect(native.calls, isNot(contains('paste')));
      expect(native.hudStates.last, 'hidden');
    });

    test('короткое нажатие не оставляет панель в «Записываю»', () async {
      // Между «нажали» и «микрофон пишет» проходит время. Клавишу успевали
      // отпустить в этом промежутке: stop видел покой и выходил, а start
      // следом ставил «запись» — и панель писала её вечно.
      native.recordDelay = const Duration(milliseconds: 60);

      final starting = cubit.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        cubit.state.phase,
        Phase.recording,
        reason: 'реакция видна сразу, пока система поднимает микрофон',
      );
      await cubit.stop();
      await starting;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(cubit.state.phase, Phase.idle, reason: 'микрофон уже молчит');
    });

    test(
      'ошибка запуска микрофона не выдаётся за сохранённую запись',
      () async {
        native.recordPath = '';

        await cubit.start();

        expect(cubit.state.phase, Phase.idle);
        expect(cubit.state.failure, contains('Не удалось запустить микрофон'));
        expect(native.hudStates.last, 'failed');
        expect(native.calls, isNot(contains('stopRecord')));
      },
    );

    test('отмена не из записи ничего не делает', () async {
      await cubit.cancel();
      expect(cubit.state.phase, Phase.idle);
      expect(native.calls, isNot(contains('stopRecord')));
    });
  });

  group('вставка текста', () {
    test('голосовая команда заменяется перед вставкой', () async {
      await Settings.save({
        textCommandsSetting: [
          const TextCommand('сказанное вслух', 'Минск, Немига, 1').toJson(),
        ],
        dictationCommandsEnabledSetting: true,
      });
      await cubit.reloadSettingsForTesting();

      await cubit.start();
      await cubit.stop();

      expect(cubit.state.last, 'Минск, Немига, 1');
      expect(native.pasted, 'Минск, Немига, 1');
    });

    test('удалённая во время записи команда уже не применяется', () async {
      await Settings.save({
        textCommandsSetting: [
          const TextCommand('сказанное вслух', 'старая замена').toJson(),
        ],
        dictationCommandsEnabledSetting: true,
      });
      await cubit.reloadSettingsForTesting();
      await cubit.start();

      await Settings.save({textCommandsSetting: const []});
      await cubit.reloadSettingsForTesting();
      await cubit.stop();

      expect(cubit.state.last, 'сказанное вслух');
      expect(native.pasted, 'сказанное вслух');
    });

    test(
      'выключатель диктовки оставляет распознанную фразу как есть',
      () async {
        await Settings.save({
          textCommandsSetting: [
            const TextCommand('сказанное вслух', 'замена').toJson(),
          ],
          dictationCommandsEnabledSetting: false,
        });
        await cubit.reloadSettingsForTesting();

        await cubit.start();
        await cubit.stop();

        expect(cubit.state.last, 'сказанное вслух');
        expect(native.pasted, 'сказанное вслух');
      },
    );

    test(
      'не удалась — текст не теряется, а уходит в буфер и в предупреждение',
      () async {
        native.pasteSucceeds = false;
        await cubit.start();
        await cubit.stop();

        // Раньше сторона macOS отвечала «получилось» всегда, и панель
        // показывала галочку над пропавшим текстом.
        expect(cubit.state.failure, contains('буфер обмена'));
        expect(
          cubit.state.failurePath,
          isNull,
          reason: 'запись тут ни при чём',
        );
        expect(native.hudStates.last, 'copied');
      },
    );

    test('удалась — панель говорит «Готово» и молчит про беду', () async {
      await cubit.start();
      await cubit.stop();

      expect(cubit.state.failure, isNull);
      expect(native.hudStates.last, 'done');
    });
  });

  group('отмена распознавания', () {
    test('работает только в фазе распознавания', () async {
      await cubit.abortTranscription();
      expect(native.calls, isNot(contains('hud')));

      await cubit.start();
      await cubit.abortTranscription();
      expect(
        cubit.state.phase,
        Phase.recording,
        reason: 'во время записи отменяют иначе — кнопкой «Отменить»',
      );
    });
  });

  group('очередь диктовок', () {
    Future<void> waitFor(bool Function() condition) async {
      // Windows process enumeration during startup can exceed 400 ms on CI.
      // Wait for the actual state, rather than depending on runner speed.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(condition(), isTrue);
    }

    for (final count in [5, 10]) {
      test('$count записей обрабатываются FIFO без перекрытия', () async {
        server.gate = Completer<String?>();
        final results = <Future<void>>[];
        for (var i = 0; i < count; i++) {
          native.recordPath = os.join(os.supportDir, 'queue-$i.wav');
          await cubit.start();
          results.add(cubit.stop());
          await waitFor(() => !cubit.state.recording);
        }
        await waitFor(() => server.paths.isNotEmpty);
        expect(server.paths.length, 1);
        expect(cubit.state.processing, isTrue);
        expect(cubit.state.pendingCount, count - 1);
        server.gate!.complete('first');
        server.gate = null;
        await Future.wait(results);
        expect(server.paths, [
          for (var i = 0; i < count; i++)
            os.join(os.supportDir, 'queue-$i.wav'),
        ]);
        expect(server.maxConcurrent, 1);
        expect(native.pastes.length, count);
        expect(native.pastes.first, 'first');
        expect(cubit.state.phase, Phase.idle);
        expect(cubit.state.pendingCount, 0);
        expect(server.holds, 0);
        await cubit.flushHistoryForTesting();
        expect(
          cubit.state.history.map((e) => e.text).toList(),
          native.pastes.reversed.toList(),
        );
        expect(DictationHistory.load(), cubit.state.history);
        expect(cubit.state.history.map((e) => e.id).toSet().length, count);
      });
    }

    test(
      'следующая ASR начинается во время защиты предыдущей вставки',
      () async {
        server.gate = Completer<String?>();
        await cubit.start();
        final first = cubit.stop();
        await waitFor(() => server.paths.length == 1);
        native.recordPath = os.join(os.supportDir, 'next-with-paste.wav');
        await cubit.start();
        final second = cubit.stop();
        await waitFor(() => cubit.state.pendingCount == 1);
        server.gate!.complete('first');
        server.gate = null;
        await first;
        var clipboardReady = false;
        unawaited(
          cubit.bridge.waitForPaste().then((_) {
            clipboardReady = true;
          }),
        );
        await waitFor(() => server.paths.length == 2);
        expect(clipboardReady, isFalse);
        expect(native.pastes, ['first']);
        await second;
        expect(native.pastes.length, 2);
        expect(server.maxConcurrent, 1);
      },
    );

    test('результат предыдущей не сбрасывает текущую запись', () async {
      server.gate = Completer<String?>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.paths.isNotEmpty);
      native.recordPath = os.join(os.supportDir, 'second.wav');
      await cubit.start();
      server.gate!.complete('first');
      await first;
      expect(cubit.state.recording, isTrue);
      expect(native.hudStates.last, 'recording');
      await cubit.cancel();
      expect(server.holds, 0);
    });

    test('отмена текущей записи оставляет прежнюю расшифровку', () async {
      server.gate = Completer<String?>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.paths.isNotEmpty);
      native.recordPath = os.join(os.supportDir, 'cancel.wav');
      await cubit.start();
      await cubit.cancel();
      expect(cubit.state.phase, Phase.transcribing);
      expect(server.shutdowns, 0);
      expect(native.hudStates.last, 'transcribing');
      server.gate!.complete('first');
      await first;
      expect(native.pasted, 'first');
      expect(server.paths.length, 1);
    });

    test(
      'отмена расшифровки не отменяет микрофон и не вставляет поздний результат',
      () async {
        server.gate = Completer<String?>();
        await cubit.start();
        final first = cubit.stop();
        await waitFor(() => server.paths.isNotEmpty);
        await cubit.start();
        await cubit.abortTranscription();
        server.gate!.complete('late');
        await first;
        expect(native.pastes, isEmpty);
        expect(cubit.state.recording, isTrue);
        await cubit.cancel();
        expect(server.holds, 0);
      },
    );

    test('очистка ожидающих сохраняет файлы и не трогает активную', () async {
      server.gate = Completer<String?>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.paths.isNotEmpty);
      native.recordPath = os.join(os.supportDir, 'waiting.wav');
      File(native.recordPath!).writeAsBytesSync(List.filled(64, 1));
      await cubit.start();
      final waiting = cubit.stop();
      await waitFor(() => cubit.state.pendingCount == 1);
      await cubit.clearPending();
      await waiting;
      expect(cubit.state.pendingCount, 0);
      expect(cubit.state.failurePath, isNotNull);
      expect(File(cubit.state.failurePath!).existsSync(), isTrue);
      expect(server.shutdowns, 0);
      server.gate!.complete('first');
      await first;
      expect(server.paths.length, 1);
      expect(server.holds, 0);
    });

    test('запуск ждёт закрытие WAV, повторная остановка безопасна', () async {
      native.stopGate = Completer<void>();
      await cubit.start();
      final stopped = cubit.stop();
      final next = cubit.start();
      await cubit.stop();
      expect(native.calls.where((c) => c == 'record').length, 1);
      expect(native.calls.where((c) => c == 'stopRecord').length, 1);
      native.stopGate!.complete();
      await next;
      await stopped;
      expect(cubit.state.recording, isTrue);
      await cubit.cancel();
      expect(server.holds, 0);
    });

    test('отмена во время загрузки модели не гасит следующую запись', () async {
      server.ensureUpCompleter = Completer<void>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.ensureUpCalls.isNotEmpty);
      final abort = cubit.abortTranscription();
      native.recordPath = os.join(os.supportDir, 'after-abort.wav');
      await cubit.start();
      final next = cubit.stop();
      await waitFor(() => cubit.state.pendingCount == 1);
      server.ensureUpCompleter!.complete();
      await abort;
      await Future.wait([first, next]);
      expect(server.shutdowns, 1);
      expect(server.paths, [os.join(os.supportDir, 'after-abort.wav')]);
      expect(native.pastes.length, 1);
      expect(server.holds, 0);
    });

    test('очередь в режиме буфера отдаёт результаты по отдельности', () async {
      final settings = DictationSettings.load()..insert = false;
      settings.save();
      await cubit.reloadSettingsForTesting();
      server.gate = Completer<String?>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.paths.isNotEmpty);
      await cubit.start();
      final next = cubit.stop();
      await waitFor(() => cubit.state.pendingCount == 1);
      server.gate!.complete('first');
      server.gate = null;
      await Future.wait([first, next]);
      expect(cubit.state.last, 'сказанное вслух');
      expect(cubit.state.history.map((e) => e.text), [
        'сказанное вслух',
        'first',
      ]);
      expect(native.pastes, isEmpty);
    });

    test('ошибка одной записи не блокирует следующую', () async {
      server.gate = Completer<String?>();
      await cubit.start();
      final first = cubit.stop();
      await waitFor(() => server.paths.isNotEmpty);
      native.recordPath = os.join(os.supportDir, 'after-failure.wav');
      await cubit.start();
      final next = cubit.stop();
      await waitFor(() => cubit.state.pendingCount == 1);
      server.gate!.completeError(StateError('engine failed'));
      server.gate = null;
      await Future.wait([first, next]);
      expect(native.pastes.length, 1);
      expect(cubit.state.phase, Phase.idle);
      expect(server.holds, 0);
    });
  });

  group('история и очередь', () {
    test('начальная история восстанавливает последний текст', () async {
      await cubit.close();
      final entry = DictationEntry(
        id: 'saved',
        text: 'Сохранённая фраза',
        createdAt: DateTime(2026, 10, 4),
      );
      DictationHistory.save([entry]);
      NativeBridge.debugReset();
      cubit = DictationCubit(NativeBridge(), server: server);
      expect(cubit.state.last, entry.text);
      expect(cubit.state.history, [entry]);
      await settle();
    });

    test(
      'сохранение сериализовано и не задерживает следующие расшифровки',
      () async {
        await cubit.close();
        final gate = Completer<void>();
        final snapshots = <List<DictationEntry>>[];
        NativeBridge.debugReset();
        cubit = DictationCubit(
          NativeBridge(),
          server: server,
          historyWriter: (entries) async {
            snapshots.add(entries);
            if (snapshots.length == 1) await gate.future;
          },
        );
        await cubit.start();
        await cubit.stop();
        await cubit.start();
        await cubit.stop();
        expect(cubit.state.history.length, 2);
        expect(server.paths.length, 2);
        expect(snapshots.length, 1);
        gate.complete();
        await cubit.flushHistoryForTesting();
        expect(snapshots.map((s) => s.length), [1, 2]);
      },
    );
    test('выход из панели ждёт последнее сохранение истории', () async {
      await cubit.close();
      final gate = Completer<void>();
      NativeBridge.debugReset();
      cubit = DictationCubit(
        NativeBridge(),
        server: server,
        historyWriter: (_) => gate.future,
      );
      await cubit.start();
      await cubit.stop();
      final quitting = cubit.quit();
      await settle();
      expect(native.calls, isNot(contains('quit')));
      gate.complete();
      await quitting;
      expect(native.calls, contains('quit'));
    });
    test('отмена и тишина не создают записей истории', () async {
      await cubit.start();
      await cubit.cancel();
      expect(cubit.state.history, isEmpty);
      server.text = '';
      await cubit.start();
      await cubit.stop();
      expect(cubit.state.history, isEmpty);
    });
    test(
      'очистка во время распознавания сохраняет следующий результат',
      () async {
        await cubit.start();
        await cubit.stop();
        expect(cubit.state.history.length, 1);
        server.gate = Completer<String?>();
        await cubit.start();
        final result = cubit.stop();
        await settle();
        await cubit.clearHistory();
        expect(cubit.state.history, isEmpty);
        expect(cubit.state.processing, isTrue);
        server.gate!.complete('После очистки');
        await result;
        await cubit.flushHistoryForTesting();
        expect(DictationHistory.load().map((e) => e.text), ['После очистки']);
      },
    );
    test('ошибка сохранения не блокирует доставку и распознавание', () async {
      await cubit.close();
      NativeBridge.debugReset();
      cubit = DictationCubit(
        NativeBridge(),
        server: server,
        historyWriter: (_) async =>
            throw FileSystemException('disk unavailable'),
      );
      await cubit.start();
      await cubit.stop();
      await cubit.flushHistoryForTesting();
      expect(native.pastes.length, 1);
      expect(cubit.state.history.length, 1);
      expect(cubit.state.historyError, isNotNull);
      expect(cubit.state.phase, Phase.idle);
    });
    test('неудачная очистка возвращает записи в панель', () async {
      await cubit.close();
      final entry = DictationEntry(
        id: 'saved',
        text: 'Текст',
        createdAt: DateTime(2026, 10, 4),
      );
      NativeBridge.debugReset();
      cubit = DictationCubit(
        NativeBridge(),
        server: server,
        initialHistory: [entry],
        historyWriter: (_) async =>
            throw FileSystemException('disk unavailable'),
      );
      await cubit.clearHistory();
      expect(cubit.state.history, [entry]);
      expect(cubit.state.historyError, isNotNull);
    });
    test(
      'история копируется после защищённой автоматической вставки',
      () async {
        await cubit.start();
        await cubit.stop();
        String? copied;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        try {
          final result = cubit.copyEntry(cubit.state.history.first.id);
          await settle();
          expect(copied, isNull);
          expect(await result, isTrue);
          expect(copied, cubit.state.history.first.text);
          expect(await cubit.copyEntry('missing'), isFalse);
        } finally {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        }
      },
    );
  });

  group('разрешения', () {
    test('одному «нет» не верим, третьему верим', () async {
      await settle();
      native.permitted = false;

      // Сразу после запуска система отвечает «нет» и тем, кто всё давно
      // разрешил: процесс ещё не осел. Плашка на пустом месте пугает зря.
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'первому отказу не верим');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'второму тоже');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isFalse, reason: 'третий отказ — уже правда');

      // А любому «да» верим сразу.
      native.permitted = true;
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue);
    });
  });

  group('состояние', () {
    test('равные снимки не заставляют панель перерисовываться', () {
      const a = DictationState(phase: Phase.idle, last: 'раз');
      const b = DictationState(phase: Phase.idle, last: 'раз');
      // На этом держится вся экономия: во время записи снимок приходит
      // десять раз в секунду, и одинаковые перерисовывать нечего.
      expect(a, b);
      expect(a.copyWith(last: 'два'), isNot(b));
    });

    test('очистка полей отличима от «не передали»', () {
      const withFailure = DictationState(
        failure: 'беда',
        failurePath: '/tmp/a.wav',
      );
      expect(withFailure.copyWith(last: 'x').failure, 'беда');
      expect(withFailure.copyWith(clearFailure: true).failure, isNull);
      expect(withFailure.copyWith(clearFailure: true).failurePath, isNull);
    });

    test('выбирать модель есть из чего при любом их числе', () {
      // Раньше здесь была пара «быстрая · точная», и выбор показывался,
      // только когда моделей ровно две. Одна или три — и переключателя
      // не было вовсе, хотя выбирать было из чего.
      expect(const DictationState().hasModels, isFalse);
      expect(const DictationState(models: ['/m.bin']).hasModels, isTrue);
      const three = DictationState(models: ['/a.bin', '/b.bin', '/c.bin']);
      expect(three.models.length, 3);
      // Список входит в сравнение состояний: без этого смена набора
      // моделей не доходила бы до перерисовки панели.
      expect(
        three == const DictationState(models: ['/a.bin', '/b.bin']),
        isFalse,
      );
    });
  });

  group('прогрев и запуск', () {
    test(
      'выбор модели при включённой диктовке запускает фоновый прогрев',
      () async {
        cubit.setEnabled(true);
        server.ensureUpCalls.clear();

        cubit.setModel('/path/to/test-model.bin');
        await cubit.bringingUpForTesting;

        expect(server.ensureUpCalls, isNotEmpty);
        expect(server.ensureUpCalls.last.model, '/path/to/test-model.bin');
      },
    );

    test(
      'включение диктовки при выбранной модели запускает фоновый прогрев',
      () async {
        cubit.setEnabled(false);
        cubit.setModel('/path/to/test-model.bin');
        server.ensureUpCalls.clear();

        cubit.setEnabled(true);
        await cubit.bringingUpForTesting;

        expect(server.ensureUpCalls, isNotEmpty);
        expect(server.ensureUpCalls.last.model, '/path/to/test-model.bin');
      },
    );

    test(
      'запись начинается сразу, даже если прогрев ещё не завершён',
      () async {
        final completer = Completer<void>();
        server.ensureUpCompleter = completer;

        // Запуск записи не должен блокироваться на ensureUp
        final starting = cubit.start();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cubit.state.phase, Phase.recording);
        expect(native.hudStates.last, 'recording');

        completer.complete();
        await starting;
        await cubit.stop();
        expect(cubit.state.phase, Phase.idle);
      },
    );

    test(
      'остановка сразу переходит в transcribing и дожидается прогрева',
      () async {
        final completer = Completer<void>();
        server.ensureUpCompleter = completer;

        final starting = cubit.start();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(cubit.state.phase, Phase.recording);
        await starting;

        // Вызываем stop, пока прогрев ещё заблокирован
        final stopping = cubit.stop();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cubit.state.phase, Phase.transcribing);
        expect(native.hudStates.last, 'transcribing');

        // Разрешаем прогрев завершиться
        completer.complete();
        await stopping;

        expect(cubit.state.phase, Phase.idle);
        expect(cubit.state.last, 'сказанное вслух');
      },
    );
  });
}

/// Подставной сервер: настоящий поднял бы процесс и прочитал в память
/// полтора гигабайта модели — в тестах это ни к чему.
class _FakeServer extends WhisperServer {
  /// Что «распознала» модель. null — не удалось, как при обрыве.
  String? text = 'сказанное вслух';
  var shutdowns = 0;
  final ensureUpCalls = <RunOptions>[];
  Completer<void>? ensureUpCompleter;
  Completer<String?>? gate;
  final paths = <String>[];
  int concurrent = 0, maxConcurrent = 0, holds = 0;

  @override
  bool get up => false;

  @override
  Future<void> get ready async {
    await ensureUpCompleter?.future;
  }

  @override
  Future<void> ensureUp(RunOptions o) async {
    ensureUpCalls.add(o);
    if (ensureUpCompleter != null) {
      await ensureUpCompleter!.future;
    }
  }

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async {
    paths.add(wav);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      return gate == null ? text : await gate!.future;
    } finally {
      concurrent--;
    }
  }

  @override
  Future<void> shutdown() async => shutdowns++;

  @override
  void hold() {
    holds++;
  }

  @override
  void release() {
    holds--;
  }

  @override
  Future<int> footprintMb() async => 0;
}

/// Подставная родная сторона: отвечает на вызовы канала и запоминает их.
class _FakeNative {
  final calls = <String>[];
  final hudStates = <String>[];
  final hudModes = <String>[];

  bool permitted = true;
  bool pasteSucceeds = true;
  String? pasted;
  final pastes = <String>[];
  Completer<void>? stopGate;

  /// Насколько система тянет с ответом «микрофон готов».
  Duration recordDelay = Duration.zero;
  String? recordPath = '/tmp/тест-диктовки.wav';

  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'record':
              if (recordDelay > Duration.zero) {
                await Future<void>.delayed(recordDelay);
              }
              return recordPath;
            case 'stopRecord':
              await stopGate?.future;
              return null;
            case 'level':
              return 0.3;
            case 'permissions':
              return permitted;
            case 'paste':
              pasted = (call.arguments as Map)['text'] as String?;
              pastes.add(pasted!);
              return pasteSucceeds;
            case 'hud':
              hudStates.add((call.arguments as Map)['state'] as String);
              hudModes.add((call.arguments as Map)['mode'] as String);
              return null;
            case 'requestModel':
              return true;
            case 'trash':
              return true;
            default:
              return null;
          }
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
