import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/diarization/own_voice.dart';
import 'package:tsukiko/core/diarization/wav_samples.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/platform/os.dart';

import '../support/fake_os.dart';

({int fromMs, int toMs, double? score}) seg(int from, int to, [double? s]) =>
    (fromMs: from, toMs: to, score: s);

void main() {
  useTempSupportDir('tsukiko-own-voice');

  group('decideOwnSegments', () {
    test('длинные куски решаются порогом', () {
      expect(
        decideOwnSegments([seg(0, 2000, 0.8), seg(2500, 5000, 0.1)], 0.45),
        [true, false],
      );
    });

    test('короткий кусок следует за ближайшим длинным', () {
      expect(
        decideOwnSegments([
          seg(0, 3000, 0.8),
          seg(3100, 3400), // «да» сразу после своей фразы
          seg(8000, 11000, 0.1),
          seg(11050, 11400), // «угу» сразу после чужой
        ], 0.45),
        [true, true, false, false],
      );
    });

    test('судить не по чему — всё остаётся', () {
      expect(decideOwnSegments([seg(0, 400), seg(600, 900)], 0.45), [
        true,
        true,
      ]);
    });

    test('порог включительный', () {
      expect(decideOwnSegments([seg(0, 2000, 0.45)], 0.45), [true]);
    });
  });

  group('векторы', () {
    test('косинус и центроид', () {
      final a = Float32List.fromList([1, 0]);
      final b = Float32List.fromList([0, 2]);
      expect(cosine(a, a), closeTo(1, 1e-6));
      expect(cosine(a, b), closeTo(0, 1e-6));
      expect(cosine(a, Float32List(2)), 0);
      final c = centroidOf([a, b]);
      expect(cosine(c, a), closeTo(cosine(c, b), 1e-6));
      expect(c[0] * c[0] + c[1] * c[1], closeTo(1, 1e-6));
    });
  });

  test('WAV туда и обратно', () {
    final samples = Float32List.fromList([0, 0.5, -0.5, 0.999]);
    final back = wavToSamples(samplesToWav(samples));
    expect(back.length, 4);
    for (var i = 0; i < 4; i++) {
      expect(back[i], closeTo(samples[i], 1e-4));
    }
  });

  group('отпечаток голоса', () {
    test('сохраняется, читается и удаляется', () {
      final print = OwnVoicePrint(
        centroid: Float32List.fromList([0.6, 0.8]),
        threshold: 0.5,
        speechMs: 21000,
        createdAt: DateTime(2026, 10, 24),
        selfScores: const [0.9, 0.8],
      );
      print.save();
      final back = OwnVoicePrint.load()!;
      expect(back.centroid, print.centroid);
      expect(back.threshold, 0.5);
      expect(back.speechMs, 21000);
      expect(back.createdAt, DateTime(2026, 10, 24));
      OwnVoicePrint.delete();
      expect(OwnVoicePrint.load(), isNull);
    });

    test('отпечаток другой модели не читается', () {
      final json = OwnVoicePrint(
        centroid: Float32List.fromList([1]),
        threshold: 0.45,
        speechMs: 1,
        createdAt: DateTime(2026),
      ).toJson()..['model'] = 'wespeaker-resnet34';
      expect(OwnVoicePrint.fromJson(json), isNull);
    });

    test('файл ядра собирается без Flutter', () {
      // own_voice.dart зовётся из `dart run tool/own_voice_probe.dart`.
      expect(
        File('lib/core/diarization/own_voice.dart').readAsStringSync(),
        isNot(contains("import 'package:flutter")),
      );
      expect(
        File('lib/core/diarization/own_voice.dart').readAsStringSync(),
        isNot(contains("import '../models.dart'")),
      );
    });
  });

  test('настройки диктовки хранят «только мой голос»', () {
    final d = DictationSettings()
      ..ownVoiceOnly = true
      ..ownVoiceThreshold = 0.55;
    d.save();
    final back = DictationSettings.load();
    expect(back.ownVoiceOnly, isTrue);
    expect(back.ownVoiceThreshold, 0.55);
    // Старый файл без этих ключей — фильтр выключен, порог обычный.
    File(os.join(os.supportDir, 'dictation.json'))
        .writeAsStringSync('{"enabled": true}');
    final old = DictationSettings.load();
    expect(old.ownVoiceOnly, isFalse);
    expect(old.ownVoiceThreshold, ownVoiceDefaultThreshold);
  });
}
