import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/acoustic_feature_extractor.dart';
import 'package:tsukiko/core/wakeword/adaptive_noise_filter.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/speech_verifier.dart';

void main() {
  group('AdaptiveNoiseFilter (Room Noise Floor & Speech Gating)', () {
    late AdaptiveNoiseFilter filter;

    setUp(() {
      filter = AdaptiveNoiseFilter();
    });

    Float32List makeSine({
      required double freq,
      required double amp,
      int length = 1600,
    }) {
      final list = Float32List(length);
      for (var i = 0; i < length; i++) {
        list[i] = amp * math.sin(2 * math.pi * freq * i / 16000);
      }
      return list;
    }

    Float32List makeNoise({required double amp, int length = 1600}) {
      final list = Float32List(length);
      final rnd = math.Random(42);
      for (var i = 0; i < length; i++) {
        list[i] = (rnd.nextDouble() * 2 - 1) * amp;
      }
      return list;
    }

    test('тихий комнатный шум адаптирует noiseFloor и даёт level ~ 0.0', () {
      // Подаём постоянный комнатный шум (например, вентилятор) с амплитудой ~0.005 (-46 dB)
      final roomNoise = makeNoise(amp: 0.005);
      for (var i = 0; i < 20; i++) {
        filter.update(roomNoise);
      }

      // После адаптации фона шум комнаты не должен определяться как речь
      expect(filter.isSpeech(roomNoise), isFalse);
      expect(filter.meterLevel, lessThan(0.10));
    });

    test('громкий голос выше порога фона (+4..+22 dB) активирует isSpeech', () {
      // Сначала адаптируем к фону
      final background = makeNoise(amp: 0.002);
      for (var i = 0; i < 20; i++) {
        filter.update(background);
      }

      // Резко звучит голос на частоте 220 Гц с громкостью 0.2
      final voice = makeSine(freq: 220, amp: 0.2);
      var speechDetected = false;
      for (var i = 0; i < 5; i++) {
        if (filter.isSpeech(voice)) speechDetected = true;
      }

      expect(speechDetected, isTrue);
      expect(filter.meterLevel, greaterThan(0.20));
    });

    test('reset сбрасывает фон и уровень', () {
      final background = makeNoise(amp: 0.002);
      for (var i = 0; i < 20; i++) {
        filter.update(background);
      }
      final voice = makeSine(freq: 200, amp: 0.3);
      filter.update(voice);
      filter.update(voice);
      expect(filter.meterLevel, greaterThan(0));

      filter.reset();
      expect(filter.meterLevel, equals(0.0));
      expect(filter.noiseFloorDb, equals(-50.0));
    });
  });

  group('AcousticFeatureExtractor & Speaker Verification', () {
    Float32List makeVoiceSignal({required double f0, int length = 16000}) {
      final list = Float32List(length);
      for (var i = 0; i < length; i++) {
        // Синтезируем голос с основным тоном F0 и гармониками
        final t = i / 16000;
        final h1 = math.sin(2 * math.pi * f0 * t);
        final h2 = 0.5 * math.sin(2 * math.pi * 2 * f0 * t);
        final h3 = 0.25 * math.sin(2 * math.pi * 3 * f0 * t);
        list[i] = (h1 + h2 + h3) * 0.3;
      }
      return list;
    }

    test('извлекает 192-мерный L2-нормализованный вектор', () {
      final voice = makeVoiceSignal(f0: 150);
      final emb = AcousticFeatureExtractor.extract(voice);

      expect(emb.length, equals(192));

      // Проверяем L2 норму: должна быть близка к 1.0
      double normSq = 0.0;
      for (var x in emb) {
        normSq += x * x;
      }
      expect(math.sqrt(normSq), closeTo(1.0, 0.01));
    });

    test('один и тот же голос даёт высокое косинусное сходство (> 0.85)', () {
      final sample1 = makeVoiceSignal(f0: 160, length: 16000);
      final sample2 = makeVoiceSignal(
        f0: 162,
        length: 16000,
      ); // чуть варьируется тон

      final emb1 = AcousticFeatureExtractor.extract(sample1);
      final emb2 = AcousticFeatureExtractor.extract(sample2);

      final sim = SpeakerProfile.cosineSimilarity(emb1, emb2);
      expect(sim, greaterThan(0.85));
    });

    test(
      'разные голоса (низкий мужской vs высокий женский) дают низкое сходство',
      () {
        final male = makeVoiceSignal(f0: 110, length: 16000); // 110 Гц
        final female = makeVoiceSignal(f0: 250, length: 16000); // 250 Гц

        final embMale = AcousticFeatureExtractor.extract(male);
        final embFemale = AcousticFeatureExtractor.extract(female);

        final sim = SpeakerProfile.cosineSimilarity(embMale, embFemale);
        expect(sim, lessThan(0.65));
      },
    );

    test(
      'SpeakerProfile.calculateOptimalThreshold корректно вычисляет порог',
      () {
        final s1 = makeVoiceSignal(f0: 150);
        final s2 = makeVoiceSignal(f0: 152);
        final s3 = makeVoiceSignal(f0: 148);

        final emb1 = AcousticFeatureExtractor.extract(s1);
        final emb2 = AcousticFeatureExtractor.extract(s2);
        final emb3 = AcousticFeatureExtractor.extract(s3);

        final threshold = SpeakerProfile.calculateOptimalThreshold([
          emb1,
          emb2,
          emb3,
        ]);
        expect(threshold, inInclusiveRange(0.52, 0.75));
      },
    );
  });

  group('SpeechVerifier Keyword Matching', () {
    test('второй этап: слово активации — с допуском, завершение — одно', () {
      // Spellings whisper base produced for the spoken wake word "Джев".
      for (final heard in ['Дев', 'Джев.', '- Джеев.', 'Древ.', 'Джефф,']) {
        expect(SpeechVerifier.matchesSpokenKeyword(heard, 'Джев'), isTrue);
      }
      expect(SpeechVerifier.matchesSpokenKeyword('Джинсы', 'Джев'), isFalse);
      expect(SpeechVerifier.matchesSpokenKeyword('М-м-м', 'Джев'), isFalse);
      expect(SpeechVerifier.matchesOnlyCommand('Пока.', 'Пока'), isTrue);
      expect(SpeechVerifier.matchesOnlyCommand('Пока. Пока!', 'Пока'), isTrue);
      for (final phrase in ['Всем пока.', 'Я пока', 'Пока что', 'Пора']) {
        expect(SpeechVerifier.matchesOnlyCommand(phrase, 'Пока'), isFalse);
      }
    });

    test(
      'с выученными написаниями слово принимается только точно и первым',
      () {
        const learned = ['джеф', 'дев'];
        bool wake(String heard) => SpeechVerifier.matchesSpokenKeyword(
          heard,
          'Джев',
          spellings: learned,
        );
        expect(wake('Джефф, напиши письмо.'), isTrue);
        expect(wake('Дев.'), isTrue);
        expect(wake('Джев'), isTrue);
        // Видео упомянуло имя посреди фразы и созвучные слова из сессии.
        expect(wake('Понятно, что это за Джефф такой.'), isFalse);
        for (final heard in ['Джеп', 'Джек', 'Джем', 'Джет', 'Дже', 'Жев']) {
          expect(wake(heard), isFalse, reason: heard);
        }
        expect(wake('Джефри'), isFalse);
      },
    );

    test('без написаний старый допуск только для первого слова', () {
      expect(
        SpeechVerifier.matchesSpokenKeyword('Джеев, привет', 'Джев'),
        isTrue,
      );
      expect(SpeechVerifier.matchesSpokenKeyword('это Джев', 'Джев'), isFalse);
    });

    test('язык без пробелов сверяется по началу', () {
      expect(
        SpeechVerifier.matchesSpokenKeyword('小月你好', '小月', spellings: ['小月']),
        isTrue,
      );
      expect(
        SpeechVerifier.matchesSpokenKeyword('你好小月', '小月', spellings: ['小月']),
        isFalse,
      );
      expect(SpeechVerifier.keywordLanguage('ツキコ'), 'ja');
      expect(SpeechVerifier.keywordLanguage('小月'), 'zh');
      expect(SpeechVerifier.keywordLanguage('Jarvis'), 'en');
    });

    test('слово завершения с написаниями', () {
      expect(
        SpeechVerifier.matchesOnlyCommand(
          'Стоп. Стоп!',
          'Стоп',
          spellings: ['стоп'],
        ),
        isTrue,
      );
      expect(
        SpeechVerifier.matchesOnlyCommand('Сто', 'Стоп', spellings: ['стоп']),
        isFalse,
      );
      expect(SpeechVerifier.spellingKey('Джеффф!'), 'джеф');
      expect(SpeechVerifier.spellingKey('Ёлка.'), 'елка');
    });

    test('калибровка требует только ключевое слово', () {
      expect(SpeechVerifier.matchesOnlyKeyword('Джеф.', 'Джеф'), isTrue);
      expect(SpeechVerifier.matchesOnlyKeyword('Джефф', 'Джеф'), isTrue);
      expect(SpeechVerifier.matchesOnlyKeyword('Джеф привет', 'Джеф'), isFalse);
      expect(SpeechVerifier.matchesOnlyKeyword('стопка', 'стоп'), isFalse);
    });

    test('отбрасывает тишину и ограничивает длину образца', () {
      expect(
        SpeechVerifier.prepareCalibrationSamples(Float32List(16000)),
        isEmpty,
      );
      final sample = Float32List(16000);
      for (var i = 4000; i < 12000; i++) {
        sample[i] = i.isEven ? 0.2 : -0.2;
      }
      final prepared = SpeechVerifier.prepareCalibrationSamples(sample);
      expect(prepared.length, lessThan(sample.length));
      expect(prepared.length, greaterThan(8000));
    });

    test('выделяет одно слово без нажатия и долгих пауз', () {
      final sample = Float32List(16000 * 3);
      for (var i = 3200; i < 3680; i++) {
        sample[i] = i.isEven ? 0.08 : -0.08; // button click
      }
      for (var i = 16000; i < 24000; i++) {
        sample[i] = 0.16 * math.sin(2 * math.pi * 240 * i / 16000);
      }
      final word = SpeechVerifier.prepareIsolatedKeywordSamples(sample);
      expect(word.length, inInclusiveRange(8000, 11000));
      expect(KeywordTemplate.fromCalibrationAudio(sample), isNotNull);
      for (var i = 32000; i < 40000; i++) {
        sample[i] = 0.16 * math.sin(2 * math.pi * 240 * i / 16000);
      }
      expect(SpeechVerifier.prepareIsolatedKeywordSamples(sample), isEmpty);
    });

    test(
      'распознаёт варианты слова «Джеф» и «Джефф» на русском и английском',
      () {
        expect(SpeechVerifier.matchesKeyword('Джефф', 'Джеф'), isTrue);
        expect(SpeechVerifier.matchesKeyword('джеф', 'Джефф'), isTrue);
        expect(SpeechVerifier.matchesKeyword('Джеф привет', 'Джеф'), isTrue);
        expect(
          SpeechVerifier.matchesKeyword('скажи jeff пожалуйста', 'Джеф'),
          isTrue,
        );
        expect(SpeechVerifier.matchesKeyword('деф', 'Джеф'), isFalse);
        expect(
          SpeechVerifier.matchesKeyword('привет как дела', 'Джеф'),
          isFalse,
        );
      },
    );

    test('распознаёт слово завершения «выполняй»', () {
      expect(SpeechVerifier.matchesKeyword('выполняй', 'выполняй'), isTrue);
      expect(
        SpeechVerifier.matchesKeyword('текст фразы выполняй', 'выполняй'),
        isTrue,
      );
      expect(SpeechVerifier.matchesKeyword('выполни', 'выполняй'), isFalse);
      expect(
        SpeechVerifier.matchesKeyword('текст без ключевого', 'выполняй'),
        isFalse,
      );
    });
  });
}
