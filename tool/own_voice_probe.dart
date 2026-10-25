// Подбор порога «Только мой голос».
//
// На каждого диктора в <папке> лежит `enroll.wav` (образец, ~20 с речи)
// и `test*.wav` (его же другие фразы). Скрипт записывает отпечаток по
// образцу и сравнивает с ним куски речи всех проверочных фраз — и своих,
// и чужих. Печатает, сколько своей речи выброшено и сколько чужой пропущено
// при каждом пороге. `mix_own_then_*.wav` — своя фраза, потом чужая:
// по ним проверяется весь фильтр целиком.
//
//   dart run tool/own_voice_probe.dart \
//       --lib ~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
//       --vad models/silero_vad.onnx \
//       --embedder models/nemo_en_titanet_small.onnx \
//       speakers/
import 'dart:io';

import 'package:tsukiko/core/diarization/own_voice.dart';

Future<void> main(List<String> argv) async {
  String? lib, vad, embedder, root;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--lib':
        lib = argv[++i];
      case '--vad':
        vad = argv[++i];
      case '--embedder':
        embedder = argv[++i];
      default:
        root = argv[i];
    }
  }
  if (vad == null || embedder == null || root == null) {
    stderr.writeln('usage: own_voice_probe --vad V --embedder E [--lib L] dir');
    exitCode = 64;
    return;
  }
  final speakers = Directory(root).listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final prints = <String, OwnVoicePrint>{};
  for (final d in speakers) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    prints[name] = await enrollOwnVoice(
      '${d.path}/enroll.wav',
      sherpaLibraryDir: lib,
      vadModel: vad,
      embeddingModel: embedder,
    );
  }

  // (свой ли, длительность, сходство) для каждого судимого куска.
  final scored = <(bool, int, double)>[];
  for (final d in speakers) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final tests = d
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('test'))
        .toList();
    for (final t in tests) {
      for (final entry in prints.entries) {
        // Чужих сравниваем только с отпечатками того же языка — так
        // честнее: чужой голос в комнате обычно говорит на том же языке.
        if (entry.key.substring(0, 2) != name.substring(0, 2)) continue;
        for (final seg in await scoreOwnVoice(
          t.path,
          entry.value.centroid,
          sherpaLibraryDir: lib,
          vadModel: vad,
          embeddingModel: embedder,
        )) {
          if (seg.score == null) continue;
          scored.add((entry.key == name, seg.toMs - seg.fromMs, seg.score!));
        }
      }
    }
  }

  stdout.writeln('threshold\town_dropped_%\tforeign_passed_%');
  for (var t = 0.20; t <= 0.80 + 1e-9; t += 0.05) {
    var own = 0, ownLost = 0, foreign = 0, foreignKept = 0;
    for (final (mine, ms, score) in scored) {
      if (mine) {
        own += ms;
        if (score < t) ownLost += ms;
      } else {
        foreign += ms;
        if (score >= t) foreignKept += ms;
      }
    }
    stdout.writeln('${t.toStringAsFixed(2)}\t'
        '${(100 * ownLost / own).toStringAsFixed(1)}\t'
        '${(100 * foreignKept / foreign).toStringAsFixed(1)}');
  }
  final selfScores = [for (final p in prints.values) ...p.selfScores]..sort();
  stdout.writeln('enrollment self-similarity: min ${selfScores.first.toStringAsFixed(2)}'
      ' median ${selfScores[selfScores.length ~/ 2].toStringAsFixed(2)}');

  // Весь фильтр: своя фраза, потом чужая.
  final threshold = double.tryParse(Platform.environment['OWN_T'] ?? '') ??
      ownVoiceDefaultThreshold;
  var right = 0, mixes = 0;
  for (final d in speakers) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    for (final f in d.listSync().whereType<File>().where(
      (f) => f.uri.pathSegments.last.startsWith('mix_'),
    )) {
      mixes++;
      final r = await filterOwnVoice(
        f.path,
        '${f.path}.out.wav',
        prints[name]!.withThreshold(threshold),
        sherpaLibraryDir: lib,
        vadModel: vad,
        embeddingModel: embedder,
      );
      // Верно — когда что-то выброшено и что-то осталось: своя половина
      // при этом занимает первую часть файла.
      final ok = r.keptMs > 0 && r.droppedMs > 0;
      if (ok) right++;
      stdout.writeln('mix ${f.uri.pathSegments.last}: kept ${r.keptMs} ms, '
          'dropped ${r.droppedMs} ms ${ok ? 'ok' : 'FAIL'}');
    }
  }
  stdout.writeln('mixed phrases split correctly: $right/$mixes at $threshold');
}
