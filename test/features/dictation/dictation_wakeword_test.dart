import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/audio_stream_source.dart';
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/speech_verifier.dart';
import 'package:tsukiko/core/wakeword/wakeword_service.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-dictation-wakeword');

  late _FakeNative native;
  late _FakeServer server;
  late FakeSherpaEngine engine;
  late FakeAudioStreamSource audioSource;
  late WakeWordService wakeWordService;
  late DictationCubit cubit;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    engine = FakeSherpaEngine();
    audioSource = FakeAudioStreamSource(permissionGranted: true);
    wakeWordService = WakeWordService(
      audioSource: audioSource,
      engine: engine,
      verifier: _EnterVerifier(),
    );

    NativeBridge.debugReset();
    cubit = DictationCubit(
      NativeBridge(),
      server: server,
      wakeWordService: wakeWordService,
    );
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('при включении wakeWord в настройках сервис запускает прослушивание', () async {
    expect(wakeWordService.isRunning, isFalse);

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
      closeWord: 'стоп',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    expect(wakeWordService.isRunning, isTrue);
    expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
    expect(engine.configuredWakeWord, 'Джеф');
    expect(engine.configuredCloseWord, 'стоп');
  });

  test('срабатывание WakeWord запускает запись диктовки', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    expect(cubit.state.recording, isFalse);

    // Имитируем триггер WakeWord от сервиса
    wakeWordService.onWakeWordTriggered?.call();
    await settle();

    expect(cubit.state.recording, isTrue);
    expect(wakeWordService.state, WakeWordListeningState.listeningCloseWordOrSilence);
  });

  test('срабатывание CloseWord останавливает запись и отрезает хвостовое слово', () async {
    server.text = 'Запиши встречу на завтра стоп.';

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
      closeWord: 'стоп',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    // Запускаем запись
    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(cubit.state.recording, isTrue);

    // Имитируем триггер CloseWord от сервиса
    wakeWordService.onCloseWordTriggered?.call();
    await cubit.stream.firstWhere((s) => s.phase == Phase.idle);

      expect(cubit.state.recording, isFalse);
      // Хвостовое слово «стоп.» должно быть отрезано из итогового текста
      expect(cubit.state.last, 'Запиши встречу на завтра');
      expect(native.pasted, 'Запиши встречу на завтра');
    },
  );

  test(
    'center останавливает запись и отправляет текст ровно один раз',
    () async {
      final sample = KeywordTemplate(
        durationSamples: 8000,
        frames: [for (var i = 0; i < 20; i++) Float32List(12)],
      );
      expect(
        SpeakerProfile(
          name: 'user',
          dimension: 192,
          embeddings: const [],
          enterWord: 'center',
          enterTemplates: [sample, sample, sample],
          enterSpellings: ['centre'],
        ).save(),
        isTrue,
      );
      DictationSettings(
        wakeWordEnabled: true,
        closeWord: 'стоп',
        enterWord: 'center',
        completionMode: PhraseCompletionMode.closeWordOnly,
      ).save();
      await cubit.reloadSettingsForTesting();
      await settle();
      expect(engine.configuredEnterWord, 'center');
      server.text = 'Найди документ. Centre.';
      await cubit.start();
      expect(cubit.state.recording, isTrue);
      final completed = cubit.stream.firstWhere(
        (s) => s.phase == Phase.idle && s.last == 'Найди документ.',
      );
      engine.queuedDetection = KeywordDetection(
        keyword: 'center',
        samples: Float32List(8000),
      );
      audioSource.pushSamples(Float32List(1600));
      await completed.timeout(const Duration(seconds: 4));
      expect(native.pasted, 'Найди документ.');
      expect(native.calls.where((c) => c == 'pressReturn'), hasLength(1));
      expect(
        native.calls.indexOf('paste'),
        lessThan(native.calls.indexOf('pressReturn')),
      );
    },
  );

  test(
    'при ручной остановке обычное слово в конце не отправляет текст',
    () async {
      DictationSettings(
        wakeWordEnabled: true,
        closeWord: 'стоп',
        enterWord: 'center',
        completionMode: PhraseCompletionMode.closeWordOnly,
      ).save();
      await cubit.reloadSettingsForTesting();
      server.text = 'Go to the center.';
      await cubit.start();
      await cubit.stop();
      expect(native.pasted, 'Go to the center.');
      expect(native.calls, isNot(contains('pressReturn')));
    },
  );

  test('таймаут тишины останавливает запись', () async {
    server.text = 'Привет мир';

    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(cubit.state.recording, isTrue);

    // Срабатывает таймаут тишины
    wakeWordService.onSilenceTimeoutTriggered?.call();
    await cubit.stream.firstWhere((s) => s.phase == Phase.idle);

    expect(cubit.state.recording, isFalse);
    expect(cubit.state.last, 'Привет мир');
  });

  test('отмена диктовки возвращает сервис в режим ожидания WakeWord', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();

    wakeWordService.onWakeWordTriggered?.call();
    await settle();
    expect(wakeWordService.state, WakeWordListeningState.listeningCloseWordOrSilence);

    await cubit.cancel();
    await settle();
    expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
  });

  test('выключение wakeWord в настройках останавливает сервис', () async {
    DictationSettings(
      wakeWordEnabled: true,
      wakeWord: 'Джеф',
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();
    expect(wakeWordService.isRunning, isTrue);

    DictationSettings(
      wakeWordEnabled: false,
    ).save();
    await cubit.reloadSettingsForTesting();
    await settle();
    expect(wakeWordService.isRunning, isFalse);
  });

  group('комбинации запуска и остановки (голос / клавиатура)', () {
    test('старт голосом (WakeWord) -> финиш клавиатурой', () async {
      DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        closeWord: 'стоп',
      ).save();
      await cubit.reloadSettingsForTesting();
      await settle();

      // Старт голосом
      wakeWordService.onWakeWordTriggered?.call();
      await settle();
      expect(cubit.state.recording, isTrue);
      expect(wakeWordService.startedByVoice, isTrue);

      // Финиш клавиатурой
      await cubit.stop();

      expect(cubit.state.recording, isFalse);
      expect(cubit.state.phase, Phase.idle);
      expect(wakeWordService.startedByVoice, isFalse);
      expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
    });

    test('старт клавиатурой -> финиш голосом (CloseWord)', () async {
      server.text = 'текст с клавиатуры стоп.';
      DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
        closeWord: 'стоп',
      ).save();
      await cubit.reloadSettingsForTesting();
      await settle();

      // Старт клавиатурой (startedByVoice = false)
      await cubit.start();
      await settle();
      expect(cubit.state.recording, isTrue);
      expect(wakeWordService.startedByVoice, isFalse);

      // Финиш голосом по CloseWord
      wakeWordService.onCloseWordTriggered?.call();
      await cubit.stream.firstWhere((s) => s.phase == Phase.idle);

      expect(cubit.state.recording, isFalse);
      expect(cubit.state.last, 'текст с клавиатуры');
      expect(wakeWordService.startedByVoice, isFalse);
      expect(wakeWordService.state, WakeWordListeningState.listeningWakeWord);
    });

    test('старт клавиатурой -> сервис отмечает startedByVoice = false', () async {
      DictationSettings(
        wakeWordEnabled: true,
        wakeWord: 'Джеф',
      ).save();
      await cubit.reloadSettingsForTesting();
      await settle();

      await cubit.start();
      await settle();
      expect(cubit.state.recording, isTrue);
      expect(wakeWordService.startedByVoice, isFalse);

      await cubit.stop();
      expect(cubit.state.recording, isFalse);
      expect(cubit.state.phase, Phase.idle);
    });
  });
}

class _FakeServer extends WhisperServer {
  String? text = 'распознанный текст';

  @override
  bool get up => false;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async => text;

  @override
  Future<void> shutdown() async {}

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

class _EnterVerifier extends SpeechVerifier {
  @override
  bool get isAvailable => true;

  @override
  Future<void> prepare({
    required String wakeWord,
    String closeWord = '',
  }) async {}

  @override
  Future<bool?> confirmKeyword(
    Float32List samples,
    String keyword, {
    required bool isClose,
    List<String> spellings = const [],
  }) async => isClose && keyword == 'center' && spellings.contains('centre');
}

class _FakeNative {
  final calls = <String>[];
  String? pasted;
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'record':
              return '/tmp/test_dict.wav';
            case 'stopRecord':
              return null;
            case 'level':
              return 0.2;
            case 'permissions':
              return true;
            case 'pressReturn':
              return true;
            case 'paste':
              pasted = (call.arguments as Map)['text'] as String?;
              return true;
            case 'hud':
              return null;
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
