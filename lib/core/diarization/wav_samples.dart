/// Звук из WAV в числа с плавающей точкой — то, что ест диаризация.
///
/// Без Flutter и без sherpa: читать WAV умеет и sherpa (`readWave`), но
/// тогда разбор нельзя проверить тестом без нативной библиотеки, а ошибка
/// в нём — это молча испорченный звук и случайные голоса.
library;

import 'dart:typed_data';

/// Частота, на которой обучены модели сегментации и эмбеддинга. `os.toWav`
/// и так пишет 16 кГц моно, поэтому передискретизации здесь нет: чужая
/// частота — это ошибка вызова, а не данные.
const diarizationSampleRate = 16000;

/// Сколько секунд звука в WAV такого вида, как пишет `os.toWav`
/// (16 кГц, моно, 16 бит), — по размеру файла, без чтения.
double wavSecondsBySize(int bytes) =>
    bytes <= 44 ? 0 : (bytes - 44) / (diarizationSampleRate * 2);

/// Сколько памяти займёт `nemo-speech diarize` на пике. Замер на M5
/// (Metal): 0.49 ГБ на 14 минутах, 0.91 ГБ на 36, 2.35 ГБ на 2.4 часа —
/// почти прямая, около 450 МБ сверху и 800 МБ на час записи.
int diarizationPeakBytes(double seconds) =>
    (450 * 1000 * 1000 + seconds * 800 * 1000 * 1000 / 3600).round();

class WavFormatException implements Exception {
  WavFormatException(this.message);
  final String message;
  @override
  String toString() => 'WavFormatException: $message';
}

/// Разобрать WAV (PCM, 16 бит) в отсчёты от −1 до 1. Несколько каналов
/// сводятся в один средним.
Float32List wavToSamples(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes, at, at + 4);
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw WavFormatException('not a RIFF/WAVE file');
  }
  int? channels, rate, bits, format;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (format == null || channels == null || bits == null) {
        throw WavFormatException('data chunk before fmt chunk');
      }
      // 0xFFFE — WAVE_FORMAT_EXTENSIBLE: тот же PCM, только с длинной
      // шапкой; так пишут некоторые сборки ffmpeg.
      if ((format != 1 && format != 0xFFFE) || bits != 16) {
        throw WavFormatException('only 16-bit PCM is supported');
      }
      if (rate != diarizationSampleRate) {
        throw WavFormatException('expected $diarizationSampleRate Hz, got $rate');
      }
      // Размер куска у потоковой записи бывает не заполнен (0 или
      // 0xFFFFFFFF) — тогда данные идут до конца файла.
      final end = size == 0 || body + size > bytes.length
          ? bytes.length
          : body + size;
      final frames = (end - body) ~/ (2 * channels);
      final out = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        var sum = 0;
        for (var c = 0; c < channels; c++) {
          sum += data.getInt16(body + (i * channels + c) * 2, Endian.little);
        }
        out[i] = sum / channels / 32768.0;
      }
      return out;
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  throw WavFormatException('no data chunk');
}
