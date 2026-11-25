import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/sherpa_engine.dart';

Float32List utterance(List<double> tones, {double speed = 1}) {
  const sampleRate = 16000;
  final toneSamples = (sampleRate * 0.18 * speed).round();
  final audio = Float32List(3200 + toneSamples * tones.length + 8000);
  for (var part = 0; part < tones.length; part++) {
    for (var i = 0; i < toneSamples; i++) {
      final envelope = math.sin(math.pi * i / toneSamples);
      final index = 3200 + part * toneSamples + i;
      audio[index] =
          0.22 *
          envelope *
          (math.sin(2 * math.pi * tones[part] * i / sampleRate) +
              0.4 * math.sin(4 * math.pi * tones[part] * i / sampleRate));
    }
  }
  return audio;
}

void main() {
  test(
    'the streaming engine recognizes both independent completion words',
    () async {
      final engine = StreamingSherpaEngine();
      addTearDown(engine.dispose);
      const wake = [210.0, 370.0, 270.0];
      const close = [430.0, 250.0, 390.0];
      const enter = [510.0, 470.0, 530.0];
      List<KeywordTemplate> templates(List<double> tones) => [
        for (final speed in [0.92, 1.0, 1.08])
          KeywordTemplate.fromAudio(utterance(tones, speed: speed))!,
      ];
      expect(
        await engine.initKeywordSpotter(
          wakeWord: 'Вока',
          closeWord: 'Отбой',
          enterWord: 'center',
          profile: SpeakerProfile(
            name: 'user',
            dimension: 192,
            embeddings: const [],
            wakeWord: 'Вока',
            closeWord: 'Отбой',
            enterWord: 'center',
            wakeTemplates: templates(wake),
            closeTemplates: templates(close),
            enterTemplates: templates(enter),
          ),
        ),
        isTrue,
      );

      List<String> speak(List<double> tones) {
        engine.resetKeywordStream();
        final audio = utterance(tones);
        final detected = <String>[];
        for (var i = 0; i < audio.length; i += 1600) {
          engine.acceptAudio(
            Float32List.sublistView(
              audio,
              i,
              (i + 1600).clamp(0, audio.length),
            ),
          );
          final keyword = engine.detectKeyword()?.keyword;
          if (keyword != null) detected.add(keyword);
        }
        return detected;
      }

      expect(speak(enter), isEmpty);
      engine.setListeningForClose(true);
      expect(speak(enter), ['center']);
      expect(speak(close), ['отбой']);
    },
  );

  test(
    'time ordered templates distinguish wake and close and survive JSON',
    () {
      final wake = [
        for (final speed in [0.92, 1.0, 1.08])
          KeywordTemplate.fromAudio(utterance([210, 370, 270], speed: speed))!,
      ];
      final close = [
        for (final speed in [0.92, 1.0, 1.08])
          KeywordTemplate.fromAudio(utterance([430, 250, 390], speed: speed))!,
      ];
      final wakeNegative = KeywordTemplate.fromAudio(
        utterance([210, 370, 430]),
      )!;
      final closeNegative = KeywordTemplate.fromAudio(
        utterance([430, 250, 270]),
      )!;
      expect(
        keywordDistance(wake[0], wake[1]),
        lessThan(keywordDistance(wake[0], close[1])),
      );
      expect(KeywordTemplate.fromJson(wake[0].toJson()), isNotNull);
      expect(keywordThreshold(wake), inInclusiveRange(0.75, 1.05));
      final profile = SpeakerProfile.fromJson(
        SpeakerProfile(
          name: 'user',
          dimension: 192,
          embeddings: const [],
          wakeWord: 'Вока',
          closeWord: 'Отбой',
          wakeTemplates: wake,
          closeTemplates: close,
          wakeNegatives: [wakeNegative],
          closeNegatives: [closeNegative],
        ).toJson(),
      );
      expect(profile.hasPersonalKeywordsFor('Вока', 'Отбой'), isTrue);
      expect(profile.wakeNegatives, hasLength(1));
      expect(profile.closeNegatives, hasLength(1));

      String? detect(Float32List audio, {bool closeMode = false}) {
        final spotter = PersonalKeywordSpotter(
          wakeWord: 'Вока',
          closeWord: 'Отбой',
          wakeTemplates: wake,
          closeTemplates: close,
          wakeNegatives: [wakeNegative],
          closeNegatives: [closeNegative],
        );
        spotter.listenForClose = closeMode;
        // A live stream keeps delivering silence after the word.
        audio = Float32List(audio.length + 8000)..setAll(0, audio);
        for (var i = 0; i < audio.length; i += 1600) {
          final end = (i + 1600).clamp(0, audio.length);
          spotter.acceptAudio(Float32List.sublistView(audio, i, end));
          final word = spotter.takeDetection();
          if (word != null) return word;
        }
        return null;
      }

      expect(detect(utterance([210, 370, 270], speed: 1.04)), 'вока');
      expect(
        detect(utterance([210, 370, 270], speed: 0.62)),
        'вока',
        reason: 'a fast pronunciation must remain detectable',
      );
      expect(
        detect(utterance([210, 370, 270], speed: 1.9)),
        'вока',
        reason: 'an isolated word with a stretched vowel can match by DTW',
      );
      expect(
        detect(utterance([510, 470, 530, 500, 520, 490])),
        isNull,
        reason: 'a long unrelated phrase must not use the stretch fallback',
      );
      expect(
        detect(utterance([210, 370, 270, 430, 250])),
        isNull,
        reason: 'a wake-like prefix inside a longer phrase is not the word',
      );
      expect(detect(utterance([210, 370, 430])), isNull);
      expect(
        detect(utterance([210, 370])),
        isNull,
        reason: 'a word missing its final sound is not the wake word',
      );
      expect(
        detect(utterance([430, 250, 390], speed: 0.96), closeMode: true),
        'отбой',
      );
      expect(detect(utterance([430, 250, 270]), closeMode: true), isNull);
      expect(
        detect(utterance([430, 250]), closeMode: true),
        isNull,
        reason: 'the close word also requires its final sound',
      );
      expect(
        detect(utterance([210, 370, 270]), closeMode: true),
        isNull,
        reason: 'the wake word must not stop dictation',
      );
      final closeWithClick = utterance([430, 250, 390]);
      for (var i = 1280; i < 1920; i++) {
        closeWithClick[i] = 0.025 * math.sin(i * 0.13);
      }
      expect(
        detect(closeWithClick, closeMode: true),
        'отбой',
        reason: 'a 40 ms noise burst before the word is not speech',
      );
      expect(
        detect(utterance([430, 250, 390, 210, 310, 220]), closeMode: true),
        isNull,
      );
      expect(detect(Float32List(32000)), isNull);

      final sustained = utterance([210, 370, 270], speed: 1.9);
      final beforeLastSoundEnds = 3200 + (16000 * 0.18 * 1.9 * 2.75).round();
      final streaming = PersonalKeywordSpotter(
        wakeWord: 'Вока',
        closeWord: 'Отбой',
        wakeTemplates: wake,
        closeTemplates: close,
        wakeNegatives: [wakeNegative],
      );
      for (var i = 0; i < beforeLastSoundEnds; i += 1600) {
        streaming.acceptAudio(
          Float32List.sublistView(
            sustained,
            i,
            (i + 1600).clamp(0, beforeLastSoundEnds),
          ),
        );
        expect(
          streaming.takeDetection(),
          isNull,
          reason: 'a matching prefix must wait for the final sound',
        );
      }

      final random = math.Random(42);
      final interference = Float32List.fromList([
        for (var i = 0; i < 16000 * 3; i++)
          (random.nextDouble() * 2 - 1) * 0.045,
      ]);
      expect(
        detect(interference),
        isNull,
        reason: 'room-like broadband noise must not activate the word',
      );

      final oneWindow = PersonalKeywordSpotter(
        wakeWord: 'Вока',
        closeWord: 'Отбой',
        wakeTemplates: wake,
        closeTemplates: close,
      );
      oneWindow.listenForClose = true;
      final closeAudio = utterance([430, 250, 390]);
      oneWindow.acceptAudio(
        Float32List.sublistView(closeAudio, 0, 3200 + 3 * 2880),
      );
      expect(
        oneWindow.takeDetection(),
        isNull,
        reason: 'close word must not fire before the utterance ends',
      );
      oneWindow.acceptAudio(
        Float32List.sublistView(closeAudio, 3200 + 3 * 2880),
      );
      expect(oneWindow.takeDetection(), 'отбой');

      Float32List closeAfterPause(int pauseSamples) {
        final first = utterance([310, 500, 450]);
        final closeWord = utterance([430, 250, 390]);
        return Float32List.fromList([
          ...first.sublist(0, 3200 + 3 * 2880),
          ...Float32List(pauseSamples),
          ...closeWord.sublist(3200),
        ]);
      }

      expect(
        detect(closeAfterPause(3200), closeMode: true),
        isNull,
        reason: 'a syllable following a short intra-word gap is not a command',
      );
      expect(
        detect(closeAfterPause(5120), closeMode: true),
        isNull,
        reason: 'a 320 ms pause is still inside a phrase ("я пока в...")',
      );
      expect(
        detect(closeAfterPause(7200), closeMode: true),
        'отбой',
        reason: 'an isolated close word after speech must still work',
      );

      final timely = PersonalKeywordSpotter(
        wakeWord: 'Вока',
        closeWord: 'Отбой',
        wakeTemplates: wake,
        closeTemplates: close,
      )..listenForClose = true;
      final ages = <int>[];
      timely.onScore = (score) {
        if (score.closeSegmentAgeMs case final age?) ages.add(age);
      };
      final sample = closeAfterPause(7200);
      for (var i = 0; i < sample.length; i += 1600) {
        timely.acceptAudio(
          Float32List.sublistView(sample, i, math.min(i + 1600, sample.length)),
        );
        timely.takeDetection();
      }
      expect(ages, isNotEmpty);
      expect(
        // 400 ms closing silence plus one 100 ms evaluation step.
        ages.every((age) => age <= 500),
        isTrue,
        reason: 'a completed segment must never be rescored much later',
      );
    },
  );
}
