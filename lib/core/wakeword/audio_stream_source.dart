import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';

/// Источник потокового аудио для WakeWord и калибровки.
abstract class AudioStreamSource {
  Future<bool> hasPermission();
  Future<Stream<Float32List>> startStream({int sampleRate = 16000});
  Future<void> stopStream();
  Future<void> dispose();
}

/// Реализация через микрофон системы с использованием `package:record`.
class MicrophoneAudioStreamSource implements AudioStreamSource {
  MicrophoneAudioStreamSource({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _rawSub;
  StreamController<Float32List>? _controller;
  bool _isStreaming = false;
  // Нативный рекордер нельзя дёргать параллельно: наложившиеся stop/start
  // во время смены устройства при сне/пробуждении падают в CoreAudio.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Stream<Float32List>> startStream({int sampleRate = 16000}) =>
      _serial(() => _start(sampleRate));

  Future<Stream<Float32List>> _start(int sampleRate) async {
    if (_isStreaming && _controller != null) {
      return _controller!.stream;
    }

    await _stop();

    final controller = StreamController<Float32List>.broadcast();
    _controller = controller;

    final config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
    );

    final rawStream = await _recorder.startStream(config);
    _isStreaming = true;

    _rawSub = rawStream.listen(
      (data) {
        if (controller.isClosed) return;
        final floatSamples = pcm16ToFloat32(data);
        if (floatSamples.isNotEmpty) {
          controller.add(floatSamples);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
        }
      },
      onDone: () {
        if (!controller.isClosed) {
          controller.close();
        }
      },
      cancelOnError: false,
    );

    return controller.stream;
  }

  @override
  Future<void> stopStream() => _serial(_stop);

  Future<void> _stop() async {
    _isStreaming = false;
    await _rawSub?.cancel();
    _rawSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
    if (_controller != null && !_controller!.isClosed) {
      await _controller!.close();
    }
    _controller = null;
  }

  @override
  Future<void> dispose() => _serial(() async {
    await _stop();
    await _recorder.dispose();
  });

  /// Преобразование сырых байтов 16-битного PCM в массив Float32List [-1.0, 1.0].
  static Float32List pcm16ToFloat32(Uint8List bytes) {
    final numSamples = bytes.lengthInBytes ~/ 2;
    if (numSamples == 0) return Float32List(0);

    final byteData = ByteData.sublistView(bytes);
    final floats = Float32List(numSamples);

    for (var i = 0; i < numSamples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      floats[i] = sample / 32768.0;
    }

    return floats;
  }
}

/// Тестовый источник аудио для юнит-тестов (без системного микрофона).
class FakeAudioStreamSource implements AudioStreamSource {
  FakeAudioStreamSource({this.permissionGranted = true});

  bool permissionGranted;
  final _controller = StreamController<Float32List>.broadcast();
  bool isStreaming = false;

  void pushSamples(Float32List samples) {
    if (!_controller.isClosed && isStreaming) {
      _controller.add(samples);
    }
  }

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<Stream<Float32List>> startStream({int sampleRate = 16000}) async {
    isStreaming = true;
    return _controller.stream;
  }

  @override
  Future<void> stopStream() async {
    isStreaming = false;
  }

  @override
  Future<void> dispose() async {
    isStreaming = false;
    await _controller.close();
  }
}
