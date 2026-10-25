// Разметка голосов: проверка суммы файлов, разбор WAV, доводы и ответ
// `nemo-speech diarize` и — если движок и модель есть на диске —
// настоящий прогон.
//
// Прогон включается переменными окружения:
//
// TSUKIKO_NEMO_SPEECH=<путь к nemo-speech> (0.2.0 и новее) и
// TSUKIKO_DIARIZATION_MODELS=<папка> — в ней
//   `Nemotron-3-Diarization.q8_0.gguf` и записи `*.wav` (16 кГц моно).
//   Рядом с записью — `<имя>.voices` с ожидаемым числом голосов.
//
// Без переменных этот прогон пропускается, а не падает.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/diarization/diarization_models.dart';
import 'package:tsukiko/core/diarization/diarizer.dart';
import 'package:tsukiko/core/diarization/sha256.dart';
import 'package:tsukiko/core/diarization/wav_samples.dart';
import 'package:tsukiko/core/transcript.dart';

Uint8List _wav(List<int> samples, {int channels = 1, int rate = 16000}) {
  final data = ByteData(44 + samples.length * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('sha256', () {
    test('эталонные векторы FIPS 180-4', () {
      expect(
        sha256OfBytes(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256OfBytes(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256OfBytes(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        sha256OfBytes(List.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('файл кусками — то же, что целиком', () async {
      final dir = Directory.systemTemp.createTempSync('tsukiko-sha');
      final file = File('${dir.path}/x.bin')
        ..writeAsBytesSync(List.generate(300000, (i) => i * 7 & 0xff));
      expect(
        await sha256OfFile(file.path),
        sha256OfBytes(file.readAsBytesSync()),
      );
      dir.deleteSync(recursive: true);
    });
  });

  group('wavToSamples', () {
    test('моно 16 бит — от −1 до 1', () {
      final samples = wavToSamples(_wav(const [0, 16384, -32768, 32767]));
      expect(samples.length, 4);
      expect(samples[0], 0);
      expect(samples[1], closeTo(0.5, 1e-6));
      expect(samples[2], -1);
      expect(samples[3], closeTo(1, 1e-4));
    });

    test('стерео сводится средним', () {
      final samples = wavToSamples(
        _wav(const [16384, 0, -16384, -16384], channels: 2),
      );
      expect(samples.length, 2);
      expect(samples[0], closeTo(0.25, 1e-6));
      expect(samples[1], closeTo(-0.5, 1e-6));
    });

    test('чужая частота и не WAV — ошибка, а не случайный звук', () {
      expect(
        () => wavToSamples(_wav(const [0], rate: 44100)),
        throwsA(isA<WavFormatException>()),
      );
      expect(
        () => wavToSamples(Uint8List.fromList(utf8.encode('hello world!'))),
        throwsA(isA<WavFormatException>()),
      );
    });

    test('длительность и память по размеру файла', () {
      expect(wavSecondsBySize(44 + 32000 * 60), 60);
      // Замер на M5: 2.35 ГБ на 2.4 часа, 0.91 ГБ на 36 минутах.
      expect(diarizationPeakBytes(8702) / 1e9, closeTo(2.35, 0.1));
      expect(diarizationPeakBytes(2143) / 1e9, closeTo(0.91, 0.1));
    });
  });

  test('модель: закреплённые ревизия, сумма и размер', () {
    expect(DiarizationModels.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      DiarizationModels.url,
      matches(RegExp(r'/resolve/[0-9a-f]{40}/Nemotron-3-Diarization\.q8_0\.gguf$')),
    );
    expect(DiarizationModels.mb, DiarizationModels.bytes ~/ (1024 * 1024));
  });

  group('nemo-speech diarize', () {
    test('доводы', () {
      expect(buildDiarizeArgs('/a.wav', '/m.gguf', '/t.json'), [
        'diarize', '/a.wav', '--model', '/m.gguf', '--format', 'json',
        '--output', '/t.json', '--force',
      ]);
    });

    test('ответ: секунды в миллисекунды, номер голоса строкой', () {
      final turns = parseDiarizeJson(jsonEncode({
        'file': '/a.wav',
        'segments': [
          {'start': 1.291, 'end': 26.319, 'speaker': 1},
          {'start': 26.091, 'end': 111.259, 'speaker': 2},
          {'start': 'битый', 'end': 2, 'speaker': 3},
        ],
      }));
      expect(turns, const [
        SpeakerTurn(1291, 26319, '1'),
        SpeakerTurn(26091, 111259, '2'),
      ]);
      expect(relabelTurns(turns).map((t) => t.clusterId), ['S1', 'S2']);
      expect(parseDiarizeJson('{"segments": []}'), isEmpty);
      expect(
        () => parseDiarizeJson('{"file": "/a.wav"}'),
        throwsA(isA<DiarizationFailed>()),
      );
    });
  });

  final exe = Platform.environment['TSUKIKO_NEMO_SPEECH'];
  final models = Platform.environment['TSUKIKO_DIARIZATION_MODELS'];
  test(
    'настоящий прогон на подготовленных записях',
    () async {
      final dir = Directory(models!);
      final model = '${dir.path}/${DiarizationModels.file}';
      final diarizer = Diarizer(exe: exe);
      final wavs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.wav'))
          .toList();
      expect(wavs, isNotEmpty);
      for (final wav in wavs) {
        final expected = File(wav.path.replaceFirst(RegExp(r'\.wav$'), '.voices'));
        final turns = relabelTurns(await diarizer.run(wav.path, model));
        expect(turns, isNotEmpty, reason: wav.path);
        expect(turns.first.clusterId, 'S1');
        if (expected.existsSync()) {
          expect(
            turns.map((t) => t.clusterId).toSet().length,
            int.parse(expected.readAsStringSync().trim()),
            reason: wav.path,
          );
        }
      }

      // Остановка убивает процесс, а следующий прогон идёт как обычно.
      final cancelled = diarizer.run(wavs.first.path, model);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      diarizer.cancel();
      await expectLater(cancelled, throwsA(isA<DiarizationCancelled>()));
      expect(await diarizer.run(wavs.first.path, model), isNotEmpty);
    },
    skip: exe == null || models == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
