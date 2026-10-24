// Подбор эмбеддера и порога кластеризации для режима «Несколько голосов».
//
// Порог — расстояние в пространстве конкретного эмбеддера, и у каждой
// записи свой оптимум: пример sherpa (0.5) на чужом эмбеддере даёт
// десятки «голосов» на одной встрече (замер YazSes). Поэтому порог не
// берётся «из примера», а меряется этим скриптом на своих записях.
//
//   dart run tool/diarize_probe.dart \
//       --lib ~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//       --segmentation <папка моделей>/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx \
//       --embedder <папка моделей>/nemo_en_titanet_small.onnx \
//       --embedder <папка моделей>/wespeaker_en_voxceleb_resnet34_LM.onnx \
//       --from 0.4 --to 2.0 --step 0.1 [--speakers N] \
//       встреча.wav встреча2.wav
//
// Записи — WAV 16 кГц моно 16 бит (так их пишет `os.toWav`; ffmpeg:
// `-ar 16000 -ac 1 -c:a pcm_s16le`). Рядом с записью может лежать
// разметка `<имя>.rttm` (поля SPEAKER file 1 начало длительность … имя …):
// тогда кроме числа голосов печатается доля ошибки по кадрам (DER без
// допуска на границах — грубая, но одинаковая для всех порогов).
//
// --lib не нужен в приложении: там библиотека уже в процессе.
import 'dart:io';
import 'dart:math' as math;

import 'package:tsukiko/core/diarization/diarizer.dart';
import 'package:tsukiko/core/diarization/wav_samples.dart';
import 'package:tsukiko/core/speakers.dart';

Future<void> main(List<String> argv) async {
  String? lib, segmentation;
  final embedders = <String>[];
  final wavs = <String>[];
  var from = 0.4, to = 2.0, step = 0.1;
  var threads = 0;
  var speakers = 0;
  for (var i = 0; i < argv.length; i++) {
    String next() => argv[++i];
    switch (argv[i]) {
      case '--lib':
        lib = next();
      case '--segmentation':
        segmentation = next();
      case '--embedder':
        embedders.add(next());
      case '--from':
        from = double.parse(next());
      case '--to':
        to = double.parse(next());
      case '--step':
        step = double.parse(next());
      case '--threads':
        threads = int.parse(next());
      case '--speakers':
        speakers = int.parse(next());
      default:
        wavs.add(argv[i]);
    }
  }
  if (segmentation == null || embedders.isEmpty || wavs.isEmpty) {
    stderr.writeln(
      'usage: diarize_probe --segmentation M --embedder E [--embedder E2] '
      '[--lib DIR] [--from 0.4 --to 2.0 --step 0.1] a.wav [b.wav]',
    );
    exitCode = 64;
    return;
  }

  final diarizer = Diarizer(sherpaLibraryDir: lib);
  stdout.writeln('embedder\twav\tthreshold\tvoices\texpected\tder\t'
      'fragmented\tseconds\trtf');
  for (final embedder in embedders) {
    for (final wav in wavs) {
      final seconds = wavSecondsBySize(File(wav).lengthSync());
      final reference = _readRttm(wav.replaceFirst(RegExp(r'\.wav$'), '.rttm'));
      final expected = reference == null
          ? '-'
          : '${reference.map((t) => t.clusterId).toSet().length}';
      for (var t = from; t <= to + 1e-9; t += step) {
        final watch = Stopwatch()..start();
        final raw = await diarizer.run(
          wav,
          DiarizationSettings(
            segmentationModel: segmentation,
            embeddingModel: embedder,
            threshold: double.parse(t.toStringAsFixed(3)),
            numThreads: threads,
            numSpeakers: speakers,
          ),
        );
        watch.stop();
        final turns = relabelTurns(raw);
        final roster = speakerRoster([
          for (final turn in turns)
            (from: turn.fromMs, to: turn.toMs, speaker: turn.clusterId),
        ]);
        final der = reference == null ? null : _der(reference, turns);
        final took = watch.elapsedMilliseconds / 1000;
        stdout.writeln([
          embedder.split(Platform.pathSeparator).last,
          wav.split(Platform.pathSeparator).last,
          t.toStringAsFixed(2),
          roster.length,
          expected,
          der == null ? '-' : der.toStringAsFixed(3),
          looksFragmented(roster) ? 'yes' : 'no',
          took.toStringAsFixed(1),
          seconds > 0 ? (took / seconds).toStringAsFixed(3) : '-',
        ].join('\t'));
      }
    }
  }
}

List<SpeakerTurn>? _readRttm(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final out = <SpeakerTurn>[];
  for (final line in file.readAsLinesSync()) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 8 || f[0] != 'SPEAKER') continue;
    final start = (double.parse(f[3]) * 1000).round();
    final length = (double.parse(f[4]) * 1000).round();
    out.add(SpeakerTurn(start, start + length, f[7]));
  }
  return out;
}

/// Доля ошибки по кадрам по 10 мс: пропуск речи, лишняя речь и путаница
/// голосов при лучшем сопоставлении меток. Перебор сопоставлений —
/// полный: голосов в проверочных записях единицы.
double _der(List<SpeakerTurn> reference, List<SpeakerTurn> hypothesis) {
  const frame = 10;
  final end = [...reference, ...hypothesis].fold<int>(
    0,
    (m, t) => math.max(m, t.toMs),
  );
  final frames = end ~/ frame + 1;
  Set<String> at(List<SpeakerTurn> turns, int i) => {
    for (final t in turns)
      if (t.fromMs <= i * frame && i * frame < t.toMs) t.clusterId,
  };
  final ref = [for (var i = 0; i < frames; i++) at(reference, i)];
  final hyp = [for (var i = 0; i < frames; i++) at(hypothesis, i)];
  final refIds = reference.map((t) => t.clusterId).toSet().toList();
  final hypIds = hypothesis.map((t) => t.clusterId).toSet().toList();
  final total = ref.fold<int>(0, (s, r) => s + r.length);
  if (total == 0) return 0;

  var best = double.infinity;
  void tryMapping(Map<String, String> mapping) {
    var errors = 0;
    for (var i = 0; i < frames; i++) {
      final mapped = {for (final h in hyp[i]) mapping[h] ?? 'miss:$h'};
      final hits = mapped.intersection(ref[i]).length;
      errors += math.max(ref[i].length, mapped.length) - hits;
    }
    best = math.min(best, errors / total);
  }

  void permute(int k, Map<String, String> mapping, Set<String> used) {
    if (k == hypIds.length) return tryMapping(mapping);
    permute(k + 1, mapping, used);
    for (final r in refIds) {
      if (used.contains(r)) continue;
      permute(k + 1, {...mapping, hypIds[k]: r}, {...used, r});
    }
  }

  // Больше восьми голосов перебор уже не тянет — берём жадное.
  if (hypIds.length <= 8) {
    permute(0, const {}, const {});
  } else {
    tryMapping(const {});
  }
  return best;
}
