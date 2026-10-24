/// Диаризация — «кто когда говорит» — в отдельном изоляте.
///
/// Нативный вызов sherpa-onnx синхронный и считает минуты: на часе
/// записи это 7–18 минут на одном потоке. В изоляте окна он заморозил бы
/// интерфейс на всё это время, поэтому работа уходит в свой изолят,
/// а наружу приходят только доля готового и итоговые отрезки.
///
/// Импортируется только приложением: программа расшифровки собирается
/// `dart compile exe`, и нативные библиотеки sherpa-плагина ей взять
/// неоткуда (см. `lib/cli/transcribe.dart`).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../speakers.dart';
import 'wav_samples.dart';

/// Параметры одного прогона. Все заданы явно, а не умолчаниями sherpa:
/// умолчания в Dart-обёртке (порог 0.5, `debug: true`) подобраны под
/// пример с китайским эмбеддером и дают десятки «голосов» на обычной
/// встрече.
class DiarizationSettings {
  const DiarizationSettings({
    required this.segmentationModel,
    required this.embeddingModel,
    required this.threshold,
    this.numSpeakers = 0,
    this.numThreads = 0,
    this.minDurationOn = 0.3,
    this.minDurationOff = 0.5,
    this.windowShiftRatio = 0.1,
  });

  final String segmentationModel, embeddingModel;

  /// Порог кластеризации — расстояние в пространстве эмбеддера. Не
  /// используется, когда задано [numSpeakers].
  final double threshold;

  /// Сколько голосов. Ноль — по порогу.
  final int numSpeakers;

  /// Ноль — `min(4, число ядер)`: не все ядра, рядом может работать
  /// распознавание или диктовка.
  final int numThreads;

  /// Короче этого (в секундах) отрезок речи выбрасывается, а пауза
  /// короче [minDurationOff] — заклеивается. Значения из примера
  /// документации sherpa-onnx.
  final double minDurationOn, minDurationOff;

  /// Шаг окна сегментации в долях окна (10 с). 0.1 — как по умолчанию;
  /// на очень длинных записях можно поднять до 0.2 ради скорости.
  final double windowShiftRatio;

  int get threads =>
      numThreads > 0 ? numThreads : math.min(4, Platform.numberOfProcessors);

  Map<String, Object> toMessage() => {
    'segmentation': segmentationModel,
    'embedding': embeddingModel,
    'threshold': threshold,
    'numSpeakers': numSpeakers,
    'threads': threads,
    'minOn': minDurationOn,
    'minOff': minDurationOff,
    'shift': windowShiftRatio,
  };
}

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

/// Один прогон диаризации. Отрезки возвращаются с номерами кластеров
/// движка — переименовывает их [relabelTurns].
///
/// Остановка ([cancel]) отвечает сразу, но нативный счёт на ней не
/// прерывается: sherpa-onnx 1.13.8 не смотрит на ответ колбэка хода
/// работы (`ComputeEmbeddings` вызывает его и идёт дальше — проверено по
/// исходнику `offline-speaker-diarization-pyannote-impl.h`), а прервать
/// чужой нативный цикл снаружи нечем. Изолят убивается и умирает, как
/// только счёт вернётся в Dart; до тех пор он держит ядра и память.
/// Поэтому следующий прогон ждёт, пока предыдущий действительно
/// закончится: двух копий записи в памяти сразу не бывает.
class Diarizer {
  Diarizer({this.sherpaLibraryDir});

  /// Папка с нативной библиотекой sherpa. В приложении null — библиотека
  /// уже в процессе; тестам и `tool/diarize_probe.dart` нужен путь.
  final String? sherpaLibraryDir;

  /// Конец предыдущего прогона — в том числе брошенного.
  static Future<void> _previous = Future.value();

  Isolate? _isolate;
  Completer<List<SpeakerTurn>>? _result;

  bool get running => _result != null && !_result!.isCompleted;

  Future<List<SpeakerTurn>> run(
    String wavPath,
    DiarizationSettings settings, {
    void Function(double share)? onProgress,
  }) async {
    await _previous;
    final result = Completer<List<SpeakerTurn>>();
    _result = result;
    final port = ReceivePort();
    final exit = ReceivePort();
    final finished = Completer<void>();
    _previous = finished.future;
    exit.listen((_) {
      exit.close();
      port.close();
      if (!finished.isCompleted) finished.complete();
      if (!result.isCompleted) {
        result.completeError(DiarizationFailed('diarization isolate exited'));
      }
    });
    port.listen((message) {
      if (message is double) {
        onProgress?.call(message);
      } else if (message is List && !result.isCompleted) {
        result.complete([
          for (var i = 0; i + 2 < message.length; i += 3)
            SpeakerTurn(
              message[i] as int,
              message[i + 1] as int,
              '${message[i + 2]}',
            ),
        ]);
      } else if (message is String && !result.isCompleted) {
        result.completeError(DiarizationFailed(message));
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _work,
        [port.sendPort, wavPath, sherpaLibraryDir, settings.toMessage()],
        onExit: exit.sendPort,
        debugName: 'diarization',
      );
    } catch (e) {
      exit.close();
      port.close();
      finished.complete();
      rethrow;
    }
    try {
      return await result.future;
    } finally {
      _isolate = null;
    }
  }

  /// Остановить. Ожидающий [run] сразу получает [DiarizationCancelled].
  void cancel() {
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.completeError(const DiarizationCancelled());
    }
    _isolate?.kill(priority: Isolate.immediate);
  }
}

/// Тело изолята. Отвечает тремя видами сообщений: доля готового
/// (`double`), отрезки плоским списком `[from, to, speaker, …]` или текст
/// ошибки (`String`).
Future<void> _work(List<Object?> args) async {
  final out = args[0] as SendPort;
  final wavPath = args[1] as String;
  final libraryDir = args[2] as String?;
  final s = (args[3] as Map).cast<String, Object>();
  sherpa.OfflineSpeakerDiarization? engine;
  try {
    await sherpa.initBindingsAsync(libraryDir);
    engine = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: s['segmentation'] as String,
            windowShiftRatio: s['shift'] as double,
          ),
          numThreads: s['threads'] as int,
          debug: false,
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: s['embedding'] as String,
          numThreads: s['threads'] as int,
          debug: false,
        ),
        clustering: sherpa.FastClusteringConfig(
          numClusters: (s['numSpeakers'] as int) > 0
              ? s['numSpeakers'] as int
              : -1,
          threshold: s['threshold'] as double,
        ),
        minDurationOn: s['minOn'] as double,
        minDurationOff: s['minOff'] as double,
      ),
    );
    if (engine.sampleRate != diarizationSampleRate) {
      out.send('unexpected model sample rate ${engine.sampleRate}');
      return;
    }
    // Байты файла живут ровно до разбора: на часе записи это ещё 115 МБ,
    // которые незачем держать рядом с отсчётами и их нативной копией.
    var samples = wavToSamples(File(wavPath).readAsBytesSync());
    if (samples.isEmpty) {
      out.send(const <Object>[]);
      return;
    }
    var shown = -1;
    final segments = engine.processWithCallback(
      samples: samples,
      callback: (done, total) {
        final percent = total <= 0 ? 0 : done * 100 ~/ total;
        if (percent != shown) {
          shown = percent;
          out.send(total <= 0 ? 0.0 : done / total);
        }
        return 0;
      },
    );
    samples = Float32List(0);
    out.send(<Object>[
      for (final seg in segments) ...[
        (seg.start * 1000).round(),
        (seg.end * 1000).round(),
        seg.speaker,
      ],
    ]);
  } catch (e) {
    out.send('$e');
  } finally {
    engine?.free();
  }
}
