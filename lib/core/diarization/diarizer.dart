/// Диаризация — «кто когда говорит» — отдельным процессом
/// `nemo-speech diarize` с моделью Nemotron-3-Diarization.
///
/// Тот же NeMo-Speech.cpp, что распознаёт Parakeet и Nemotron ASR: на Mac
/// он считает на Metal (встреча 17,5 мин — около минуты на M5), на
/// Windows — на Vulkan, а без годной видеокарты на процессоре (там же
/// пять минут записи — 45 с). Отдельный процесс заодно даёт настоящую
/// остановку: его можно убить, а нативный цикл внутри своего процесса
/// прервать было нечем.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../platform/os.dart';
import '../library.dart';
import '../speakers.dart';

/// Диаризацию остановили — это не сбой, о нём не говорят как об ошибке.
class DiarizationCancelled implements Exception {
  const DiarizationCancelled();
  @override
  String toString() => 'DiarizationCancelled';
}

class DiarizationFailed implements Exception {
  DiarizationFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Доводы для `nemo-speech diarize`. Пути — через `os.processPath`, как у
/// распознавания: кириллица в `argv` чужой программы на Windows теряется.
List<String> buildDiarizeArgs(String wav, String model, String jsonPath) => [
  'diarize',
  os.processPath(wav),
  '--model',
  os.processPath(model),
  '--format',
  'json',
  '--output',
  os.processPath(jsonPath),
  '--force',
];

/// Разобрать ответ `nemo-speech diarize --format json`:
/// `{"file": …, "segments": [{"start": 1.29, "end": 26.3, "speaker": 1}]}`.
/// Номер голоса движка становится строкой — переименовывает его
/// [relabelTurns].
List<SpeakerTurn> parseDiarizeJson(String text) {
  final json = jsonDecode(text);
  final segments = json is Map ? json['segments'] : null;
  if (segments is! List) throw DiarizationFailed('no segments in diarize json');
  return [
    for (final s in segments)
      if (s is Map && s['start'] is num && s['end'] is num)
        SpeakerTurn(
          ((s['start'] as num) * 1000).round(),
          ((s['end'] as num) * 1000).round(),
          '${s['speaker']}',
        ),
  ];
}

/// Один прогон диаризации. Отрезки возвращаются с номерами голосов
/// движка — переименовывает их [relabelTurns].
class Diarizer {
  /// [exe] — путь к `nemo-speech`; null — свой движок приложения, иначе
  /// системный. Тестам и замерам нужен явный путь.
  Diarizer({this.exe});

  final String? exe;

  Process? _proc;
  bool _cancelled = false;

  bool get running => _proc != null;

  Future<List<SpeakerTurn>> run(String wavPath, String model) async {
    _cancelled = false;
    final engine = exe ?? findNemoSpeech();
    if (engine == null) throw DiarizationFailed('nemo-speech not found');
    final tmp = await Directory.systemTemp.createTemp('tsukiko-diarize');
    final out = '${tmp.path}${Platform.pathSeparator}turns.json';
    try {
      // Под своим именем, как распознавание: в «Мониторинге системы» память
      // должна числиться за понятным процессом.
      final proc = _proc = await Process.start(
        runnableEngine(engine, nemoSpeechExeName) ?? engine,
        buildDiarizeArgs(wavPath, model, out),
        environment: exe == null ? await os.engineEnvironment() : null,
      );
      if (exe == null) os.bindToApp(proc.pid);
      // Движок хода работы не печатает — только строки начала и конца.
      // Вывод нужен для сообщения об ошибке, последние строки.
      final tail = <String>[];
      void keep(String line) {
        if (line.trim().isEmpty) return;
        tail.add(line.trim());
        if (tail.length > 8) tail.removeAt(0);
      }

      final done = [
        proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(keep),
        proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(keep),
      ];
      final code = await proc.exitCode;
      await Future.wait(done);
      if (_cancelled) throw const DiarizationCancelled();
      final file = File(out);
      if (code != 0 || !file.existsSync()) {
        throw DiarizationFailed(
          'nemo-speech diarize exit $code: ${tail.join(' · ')}',
        );
      }
      return parseDiarizeJson(await file.readAsString());
    } finally {
      _proc = null;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Остановить. Ожидающий [run] получает [DiarizationCancelled].
  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }
}
