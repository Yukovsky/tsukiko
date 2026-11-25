import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-settings-wakeword');

  late _FakeNative native;
  late SettingsCubit cubit;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    NativeBridge.debugReset();
    cubit = SettingsCubit(NativeBridge());
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test(
    'начальные настройки голосовой активации соответствуют значениям по умолчанию',
    () {
      expect(cubit.state.wakeWordEnabled, isFalse);
      expect(cubit.state.wakeWord, 'Джеф');
      expect(cubit.state.closeWord, isEmpty);
      expect(cubit.state.completionMode, PhraseCompletionMode.hybrid);
      expect(cubit.state.voiceCalibrationEnabled, isFalse);
      expect(cubit.state.speakerThreshold, 0.60);
      expect(cubit.state.speakerProfileExists, isFalse);
    },
  );

  test('setWakeWordEnabled включает и выключает активацию', () async {
    cubit.setWakeWordEnabled(true);
    await settle();
    expect(cubit.state.wakeWordEnabled, isTrue);

    // Проверяем сохранение на диске
    final loaded = DictationSettings.load();
    expect(loaded.wakeWordEnabled, isTrue);

    cubit.setWakeWordEnabled(false);
    await settle();
    expect(cubit.state.wakeWordEnabled, isFalse);
    expect(DictationSettings.load().wakeWordEnabled, isFalse);
  });

  test(
    'setWakeWord обновляет слово активации и сбрасывает пустое на «Джеф»',
    () async {
      cubit.setWakeWord('Ассистент');
      await settle();
      expect(cubit.state.wakeWord, 'Ассистент');
      expect(DictationSettings.load().wakeWord, 'Ассистент');

      cubit.setWakeWord('   ');
      await settle();
      expect(cubit.state.wakeWord, 'Джеф');
      expect(DictationSettings.load().wakeWord, 'Джеф');
    },
  );

  test('setCloseWord обновляет завершающее слово', () async {
    cubit.setCloseWord('готово');
    await settle();
    expect(cubit.state.closeWord, 'готово');
    expect(DictationSettings.load().closeWord, 'готово');
  });

  test('setCompletionMode меняет режим завершения фразы', () async {
    cubit.setCompletionMode(PhraseCompletionMode.closeWordOnly);
    await settle();
    expect(cubit.state.completionMode, PhraseCompletionMode.closeWordOnly);
    expect(
      DictationSettings.load().completionMode,
      PhraseCompletionMode.closeWordOnly,
    );

    cubit.setCompletionMode(PhraseCompletionMode.silenceOnly);
    await settle();
    expect(cubit.state.completionMode, PhraseCompletionMode.silenceOnly);
    expect(
      DictationSettings.load().completionMode,
      PhraseCompletionMode.silenceOnly,
    );
  });

  test(
    'setVoiceCalibrationEnabled и setSpeakerThreshold сохраняют параметры калибровки',
    () async {
      cubit.setVoiceCalibrationEnabled(true);
      cubit.setSpeakerThreshold(0.72);
      await settle();

      expect(cubit.state.voiceCalibrationEnabled, isTrue);
      expect(cubit.state.speakerThreshold, 0.72);

      final loaded = DictationSettings.load();
      expect(loaded.voiceCalibrationEnabled, isTrue);
      expect(loaded.speakerThreshold, closeTo(0.72, 0.001));
    },
  );

  test(
    'создание, обнаружение и удаление профиля голоса обновляет speakerProfileExists',
    () async {
      expect(cubit.state.speakerProfileExists, isFalse);

      // Создаём и сохраняем профиль
      final profile = SpeakerProfile(
        name: 'user',
        dimension: 192,
        embeddings: const [],
        wakeTemplates: [
          for (var i = 0; i < 3; i++)
            KeywordTemplate(
              durationSamples: 8000,
              frames: [for (var f = 0; f < 20; f++) Float32List(12)],
            ),
        ],
      );
      profile.save();

      cubit.refreshSpeakerProfile();
      await settle();
      expect(cubit.state.voiceCalibrationEnabled, isTrue);
      expect(cubit.state.speakerProfileExists, isTrue);

      // Удаляем через кубит
      cubit.deleteSpeakerProfile();
      await settle();
      expect(cubit.state.speakerProfileExists, isFalse);
      expect(SpeakerProfile.exists(), isFalse);
    },
  );

  test('раздельная калибровка и удаление трёх голосовых команд', () async {
    cubit.setWakeWord('Джеф');
    cubit.setCloseWord('готово');
    cubit.setEnterWord('center');
    await settle();
    expect(cubit.state.wakeProfileExists, isFalse);
    expect(cubit.state.closeProfileExists, isFalse);
    expect(cubit.state.enterProfileExists, isFalse);
    expect(cubit.state.speakerProfileExists, isFalse);

    final dummyTemplate = KeywordTemplate(
      durationSamples: 8000,
      frames: [for (var f = 0; f < 20; f++) Float32List(12)],
    );
    final profile = SpeakerProfile(
      name: 'user',
      dimension: 192,
      embeddings: const [],
      wakeWord: 'Джеф',
      closeWord: 'готово',
      enterWord: 'center',
      wakeTemplates: [dummyTemplate, dummyTemplate, dummyTemplate],
      closeTemplates: [dummyTemplate, dummyTemplate, dummyTemplate],
      enterTemplates: [dummyTemplate, dummyTemplate, dummyTemplate],
    );
    profile.save();

    cubit.refreshSpeakerProfile();
    await settle();
    expect(cubit.state.wakeProfileExists, isTrue);
    expect(cubit.state.closeProfileExists, isTrue);
    expect(cubit.state.enterProfileExists, isTrue);
    expect(cubit.state.speakerProfileExists, isTrue);

    // Удаляем только слово завершения: активация должна сохраниться
    cubit.deleteCloseProfile();
    await settle();
    expect(cubit.state.wakeProfileExists, isTrue);
    expect(cubit.state.closeProfileExists, isFalse);
    // Если closeWord не пуст, но профиль удалён, speakerProfileExists отражает готовность
    final loaded = SpeakerProfile.load();
    expect(loaded, isNotNull);
    expect(loaded!.hasWakeCalibration, isTrue);
    expect(loaded.hasCloseCalibration, isFalse);
    expect(loaded.hasEnterTemplatesFor('center'), isTrue);

    // Удаляем слово активации
    cubit.deleteWakeProfile();
    await settle();
    expect(cubit.state.wakeProfileExists, isFalse);
    expect(SpeakerProfile.load()?.hasWakeCalibration ?? false, isFalse);
    expect(cubit.state.enterProfileExists, isTrue);

    cubit.setEnterWord('submit');
    expect(cubit.state.enterProfileExists, isFalse);
    cubit.setEnterWord('center');
    expect(cubit.state.enterProfileExists, isTrue);
    cubit.deleteEnterProfile();
    expect(cubit.state.enterProfileExists, isFalse);
    expect(SpeakerProfile.exists(), isFalse);
  });
}

class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => null);
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
