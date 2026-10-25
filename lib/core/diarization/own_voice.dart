/// «Только мой голос»: из надиктованной фразы выбрасываются куски речи,
/// не похожие на голос хозяина, — соседа по офису, телевизор, собеседника
/// на созвоне. Распознавание видит только то, что осталось.
///
/// Как это устроено:
///
/// 1. Один раз человек записывает образец своего голоса — секунд двадцать
///    обычной речи. Из него получаются эмбеддинги (тот же TitaNet-S, что
///    размечает голоса в очереди: одна загрузка на обе функции) и их
///    среднее — «отпечаток».
/// 2. Перед распознаванием фраза режется детектором речи (Silero VAD) на
///    куски. У каждого куска длиннее [ownVoiceMinMs] считается эмбеддинг
///    и сходство с отпечатком; ниже [OwnVoicePrint.threshold] — кусок
///    выбрасывается. Короткие куски судить не по чему — они следуют за
///    ближайшим длинным соседом.
/// 3. Если судить было не по чему вовсе (вся фраза — короткое «да»),
///    фраза остаётся целиком: потерять своё слово хуже, чем пропустить
///    чужое.
///
/// Отпечаток голоса — биометрия. Он хранится только на этом компьютере
/// (`own_voice.json` в папке приложения), никуда не уходит и удаляется
/// одной кнопкой в настройках.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../library.dart' show supportDir, writeJsonAtomically;
import '../../platform/os.dart';
import 'wav_samples.dart';

/// Короче этого кусок речи не судится: эмбеддинг по полусекунде голоса
/// почти случаен (OpenWhispr называет порог ~0,8 с; у нас чуть ниже, с
/// оглядкой на короткие диктовки).
const ownVoiceMinMs = 700;

/// Порог сходства по умолчанию — косинус к отпечатку в пространстве
/// TitaNet-S. Подобран замером на 28 реальных голосах (VoxForge, русский
/// и английский): см. `docs/own-voice.md`.
const ownVoiceDefaultThreshold = 0.45;

/// Сколько речи нужно в образце.
const ownVoiceEnrollMinMs = 8000;

/// Длина окна, на которые режется образец, — эмбеддингов из окон
/// получается несколько, и отпечаток не зависит от одной фразы.
const _enrollWindowMs = 3000;

class OwnVoicePrint {
  const OwnVoicePrint({
    required this.centroid,
    required this.threshold,
    required this.speechMs,
    required this.createdAt,
    this.selfScores = const [],
  });

  /// Среднее нормированных эмбеддингов образца, само нормированное.
  final Float32List centroid;
  final double threshold;

  /// Сколько речи было в образце.
  final int speechMs;
  final DateTime createdAt;

  /// Сходство окон образца с отпечатком — чтобы было видно, насколько
  /// ровно записан образец.
  final List<double> selfScores;

  OwnVoicePrint withThreshold(double value) => OwnVoicePrint(
    centroid: centroid,
    threshold: value,
    speechMs: speechMs,
    createdAt: createdAt,
    selfScores: selfScores,
  );

  Map<String, Object> toJson() => {
    'model': OwnVoicePaths.embedderId,
    'centroid': centroid.toList(),
    'threshold': threshold,
    'speechMs': speechMs,
    'createdAt': createdAt.toIso8601String(),
    'selfScores': selfScores,
  };

  static OwnVoicePrint? fromJson(Object? value) {
    if (value is! Map) return null;
    final raw = value['centroid'];
    if (raw is! List || raw.isEmpty) return null;
    // Отпечаток другой модели с этой не сравнить — его пришлось бы
    // записывать заново.
    if (value['model'] != OwnVoicePaths.embedderId) return null;
    return OwnVoicePrint(
      centroid: Float32List.fromList([
        for (final v in raw) (v as num).toDouble(),
      ]),
      threshold:
          (value['threshold'] as num?)?.toDouble() ?? ownVoiceDefaultThreshold,
      speechMs: (value['speechMs'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse('${value['createdAt']}') ?? DateTime.now(),
      selfScores: [
        for (final v in (value['selfScores'] as List? ?? const []))
          (v as num).toDouble(),
      ],
    );
  }

  static File get file => File(os.join(supportDir, 'own_voice.json'));

  static OwnVoicePrint? load() {
    try {
      return fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  void save() {
    Directory(supportDir).createSync(recursive: true);
    writeJsonAtomically(file, toJson());
  }

  static void delete() {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

/// Что сделал фильтр с фразой.
class OwnVoiceResult {
  const OwnVoiceResult({
    required this.keptMs,
    required this.droppedMs,
    required this.judged,
    this.path,
  });

  /// Куда записан звук после фильтра. null — фраза осталась как была
  /// (судить было не по чему или выбрасывать нечего).
  final String? path;
  final int keptMs, droppedMs;

  /// Был ли хоть один кусок достаточной длины, чтобы его судить.
  final bool judged;

  /// Своего голоса во фразе не нашлось — вставлять нечего.
  bool get nothingLeft => judged && keptMs == 0;
}

// ── чистые правила ──────────────────────────────────────────────────────────

double cosine(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / math.sqrt(na * nb);
}

Float32List normalized(Float32List v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  return Float32List.fromList([for (final x in v) n == 0 ? 0 : x / n]);
}

/// Среднее нормированных векторов, снова нормированное.
Float32List centroidOf(List<Float32List> vectors) {
  final dim = vectors.first.length;
  final sum = Float64List(dim);
  for (final v in vectors) {
    final u = normalized(v);
    for (var i = 0; i < dim; i++) {
      sum[i] += u[i];
    }
  }
  return normalized(Float32List.fromList(sum));
}

/// Оставить ли каждый кусок речи.
///
/// [segments] — куски по порядку: время и сходство с отпечатком (null —
/// кусок короче [minMs], сходство не считали). Длинные куски решаются
/// порогом. Короткие следуют за ближайшим по времени длинным: «да» посреди
/// своей фразы — своё, посреди чужой — чужое. Длинных нет вовсе — судить
/// не по чему, и всё остаётся.
List<bool> decideOwnSegments(
  List<({int fromMs, int toMs, double? score})> segments,
  double threshold,
) {
  final judged = [
    for (var i = 0; i < segments.length; i++)
      if (segments[i].score != null) i,
  ];
  if (judged.isEmpty) return List.filled(segments.length, true);
  return [
    for (var i = 0; i < segments.length; i++)
      if (segments[i].score != null)
        segments[i].score! >= threshold
      else
        () {
          var best = judged.first;
          int gap(int j) {
            final a = segments[i], b = segments[j];
            if (b.toMs <= a.fromMs) return a.fromMs - b.toMs;
            if (b.fromMs >= a.toMs) return b.fromMs - a.toMs;
            return 0;
          }

          for (final j in judged) {
            if (gap(j) < gap(best)) best = j;
          }
          return segments[best].score! >= threshold;
        }(),
  ];
}

/// WAV 16 кГц моно 16 бит из отсчётов — то, что ест распознавание.
Uint8List samplesToWav(Float32List samples) {
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
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, diarizationSampleRate, Endian.little);
  data.setUint32(28, diarizationSampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i] * 32767).round().clamp(-32768, 32767);
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Пути к моделям. Загрузка — в `own_voice_models.dart`: она идёт через
/// `Download` и тянет за собой Flutter, а этот файл должен оставаться
/// пригодным для `dart run` (`tool/own_voice_probe.dart`).
class OwnVoicePaths {
  OwnVoicePaths._();

  /// Тот же эмбеддер, что размечает голоса в очереди (TitaNet-S).
  static const embedderId = 'titanet-small';
  static const embedderFile = 'nemo_en_titanet_small.onnx';

  /// Тот же файл, что берёт голосовая активация (`WakeWordModelPaths`):
  /// скачанный там годится и здесь.
  static const vadFile = 'silero_vad.onnx';

  static String get vadPath => os.join(os.modelsDir, vadFile);
  static String get embedderPath => os.join(os.modelsDir, embedderFile);
}

// ── работа с нейросетями (в своём изоляте) ──────────────────────────────────

/// Записать отпечаток голоса по образцу. [wav] — 16 кГц моно.
///
/// Бросает [StateError], если речи в образце меньше [ownVoiceEnrollMinMs].
Future<OwnVoicePrint> enrollOwnVoice(
  String wav, {
  String? sherpaLibraryDir,
  String? vadModel,
  String? embeddingModel,
}) {
  final vad = vadModel ?? OwnVoicePaths.vadPath;
  final model = embeddingModel ?? OwnVoicePaths.embedderPath;
  return Isolate.run(() async {
    await sherpa.initBindingsAsync(sherpaLibraryDir);
    final samples = wavToSamples(File(wav).readAsBytesSync());
    final speech = _speech(samples, vad);
    final total = speech.fold<int>(0, (s, seg) => s + seg.samples.length);
    final speechMs = total * 1000 ~/ diarizationSampleRate;
    if (speechMs < ownVoiceEnrollMinMs) {
      throw StateError('only $speechMs ms of speech in the sample');
    }
    // Речь подряд, без пауз, — и окна по три секунды.
    final joined = Float32List(total);
    var at = 0;
    for (final seg in speech) {
      joined.setAll(at, seg.samples);
      at += seg.samples.length;
    }
    final window = _enrollWindowMs * diarizationSampleRate ~/ 1000;
    final extractor = _extractor(model);
    try {
      final embeddings = <Float32List>[
        for (var s = 0; s + window ~/ 2 <= joined.length; s += window)
          ?_embed(
            extractor,
            Float32List.sublistView(
              joined,
              s,
              math.min(joined.length, s + window),
            ),
          ),
      ];
      if (embeddings.length < 2) {
        throw StateError('not enough speech windows');
      }
      final centroid = centroidOf(embeddings);
      return OwnVoicePrint(
        centroid: centroid,
        threshold: ownVoiceDefaultThreshold,
        speechMs: speechMs,
        createdAt: DateTime.now(),
        selfScores: [for (final e in embeddings) cosine(e, centroid)],
      );
    } finally {
      extractor.free();
    }
  });
}

/// Оставить во фразе только свой голос. Результат пишется в [outWav];
/// если выбрасывать нечего или судить не по чему, файл не пишется, и
/// [OwnVoiceResult.path] — null: распознавать исходный.
Future<OwnVoiceResult> filterOwnVoice(
  String wav,
  String outWav,
  OwnVoicePrint print, {
  String? sherpaLibraryDir,
  String? vadModel,
  String? embeddingModel,
}) {
  final vad = vadModel ?? OwnVoicePaths.vadPath;
  final model = embeddingModel ?? OwnVoicePaths.embedderPath;
  final centroid = print.centroid, threshold = print.threshold;
  return Isolate.run(() async {
    await sherpa.initBindingsAsync(sherpaLibraryDir);
    final samples = wavToSamples(File(wav).readAsBytesSync());
    final speech = _speech(samples, vad);
    if (speech.isEmpty) {
      return const OwnVoiceResult(keptMs: 0, droppedMs: 0, judged: false);
    }
    final extractor = _extractor(model);
    final List<({int fromMs, int toMs, double? score})> segments;
    try {
      segments = [
        for (final seg in speech)
          () {
            final fromMs = seg.start * 1000 ~/ diarizationSampleRate;
            final ms = seg.samples.length * 1000 ~/ diarizationSampleRate;
            final e = ms < ownVoiceMinMs ? null : _embed(extractor, seg.samples);
            return (
              fromMs: fromMs,
              toMs: fromMs + ms,
              score: e == null ? null : cosine(e, centroid),
            );
          }(),
      ];
    } finally {
      extractor.free();
    }
    final keep = decideOwnSegments(segments, threshold);
    final judged = segments.any((s) => s.score != null);
    var kept = 0, dropped = 0;
    for (var i = 0; i < segments.length; i++) {
      final ms = segments[i].toMs - segments[i].fromMs;
      keep[i] ? kept += ms : dropped += ms;
    }
    if (dropped == 0 || kept == 0) {
      return OwnVoiceResult(keptMs: kept, droppedMs: dropped, judged: judged);
    }
    // Выброшенное заменяем тишиной, а не вырезаем: распознаванию нужны
    // паузы между фразами, и время в истории остаётся настоящим.
    final out = Float32List.fromList(samples);
    for (var i = 0; i < speech.length; i++) {
      if (keep[i]) continue;
      final s = speech[i].start;
      out.fillRange(
        s.clamp(0, out.length),
        (s + speech[i].samples.length).clamp(0, out.length),
        0,
      );
    }
    File(outWav).writeAsBytesSync(samplesToWav(out));
    return OwnVoiceResult(
      keptMs: kept,
      droppedMs: dropped,
      judged: judged,
      path: outWav,
    );
  });
}

/// Сходство каждого куска речи в [wav] с отпечатком — без решений.
/// Нужно замеру порога (`tool/own_voice_probe.dart`).
Future<List<({int fromMs, int toMs, double? score})>> scoreOwnVoice(
  String wav,
  Float32List centroid, {
  String? sherpaLibraryDir,
  String? vadModel,
  String? embeddingModel,
}) {
  final vad = vadModel ?? OwnVoicePaths.vadPath;
  final model = embeddingModel ?? OwnVoicePaths.embedderPath;
  return Isolate.run(() async {
    await sherpa.initBindingsAsync(sherpaLibraryDir);
    final samples = wavToSamples(File(wav).readAsBytesSync());
    final extractor = _extractor(model);
    try {
      return [
        for (final seg in _speech(samples, vad))
          () {
            final fromMs = seg.start * 1000 ~/ diarizationSampleRate;
            final ms = seg.samples.length * 1000 ~/ diarizationSampleRate;
            final e = ms < ownVoiceMinMs ? null : _embed(extractor, seg.samples);
            return (
              fromMs: fromMs,
              toMs: fromMs + ms,
              score: e == null ? null : cosine(e, centroid),
            );
          }(),
      ];
    } finally {
      extractor.free();
    }
  });
}

List<sherpa.SpeechSegment> _speech(Float32List samples, String model) {
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: model,
        // Пауза короче 0,3 с — ещё та же реплика; длиннее 8 с — режем,
        // иначе смена голоса внутри куска потерялась бы.
        minSilenceDuration: 0.3,
        minSpeechDuration: 0.2,
        maxSpeechDuration: 8,
      ),
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: samples.length / diarizationSampleRate + 2,
  );
  final out = <sherpa.SpeechSegment>[];
  try {
    const step = 512;
    for (var i = 0; i < samples.length; i += step) {
      vad.acceptWaveform(
        Float32List.sublistView(samples, i, math.min(samples.length, i + step)),
      );
      while (!vad.isEmpty()) {
        out.add(vad.front());
        vad.pop();
      }
    }
    vad.flush();
    while (!vad.isEmpty()) {
      out.add(vad.front());
      vad.pop();
    }
  } finally {
    vad.free();
  }
  return out;
}

sherpa.SpeakerEmbeddingExtractor _extractor(String model) =>
    sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: model,
        numThreads: 2,
        debug: false,
      ),
    );

Float32List? _embed(sherpa.SpeakerEmbeddingExtractor extractor, Float32List x) {
  final stream = extractor.createStream();
  try {
    stream.acceptWaveform(samples: x, sampleRate: diarizationSampleRate);
    stream.inputFinished();
    if (!extractor.isReady(stream)) return null;
    final e = extractor.compute(stream);
    return e.isEmpty ? null : e;
  } finally {
    stream.free();
  }
}
