import 'dart:math' as math;
import 'dart:typed_data';

/// Адаптивный фильтр фонового шума и детектор голосовой активности.
///
/// Полностью воспроизводит проверенную баллистику оценки комнатного фона
/// из нативного Swift-кода Tsukiko (`macos/Runner/Dictation.swift`):
/// - непрерывно отслеживает уровень шума комнаты (`noiseFloorDb`);
/// - строит динамическое окно речи: порог +4 дБ над фоном (дыхание и шум
///   вентиляторов отсекаются), потолок +22 дБ над фоном (но не ниже −14 дБ);
/// - баллистика индикатора: атака 20 мс, спад 300 мс (интеграция VU-метра).
///
/// Работает на чистом Dart без FFI и внешних библиотек.
class AdaptiveNoiseFilter {
  AdaptiveNoiseFilter();

  double _noiseFloorDb = -50.0;
  double _meterLevel = 0.0;
  double _speechLevel = 0.0;
  DateTime? _lastUpdate;

  double get noiseFloorDb => _noiseFloorDb;
  double get meterLevel => _meterLevel;

  /// Сбросить оценку фона (например, при смене микрофона или перезапуске).
  void reset() {
    _noiseFloorDb = -50.0;
    _meterLevel = 0.0;
    _speechLevel = 0.0;
    _lastUpdate = null;
  }

  /// Обновить уровень по порции PCM сэмплов Float32 [-1.0, 1.0].
  ///
  /// Возвращает нормализованный уровень речи [0.0, 1.0], где 0.0 — тишина или фоновый шум,
  /// 0.4..0.7 — нормальная речь, 1.0 — громкий голос.
  double update(Float32List samples) {
    if (samples.isEmpty) return _meterLevel;

    // Вычисляем RMS
    double sum = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples.length);

    // Ниже −60 дБ считать нечего: это уже цифровая тишина
    final db = rms > 0.000001
        ? math.max(-60.0, 20.0 * (math.log(rms) / math.ln10))
        : -60.0;

    final now = DateTime.now();
    final dt = _lastUpdate != null
        ? math.max(0.01, math.min(0.25, now.difference(_lastUpdate!).inMicroseconds / 1000000.0))
        : 1.0 / 30.0;
    _lastUpdate = now;

    // Фон комнаты: вниз оценка идёт быстро (0.5 с), вверх — медленно (3 с или 60 с).
    // Речь не задирает фон, от которого её же и отсчитывают.
    final was = _noiseFloorDb;
    final floorTau = db < was ? 0.5 : (db < was + 6.0 ? 3.0 : 60.0);
    final floor = was + (db - was) * (1.0 - math.exp(-dt / floorTau));
    _noiseFloorDb = floor;

    // Окно под речь: порог +4 дБ над фоном, потолок +22 дБ над ним (минимум −14 дБ).
    final bottom = floor + 4.0;
    final top = math.max(floor + 22.0, -14.0);
    final target = top > bottom
        ? ((db - bottom) / (top - bottom)).clamp(0.0, 1.0)
        : 0.0;
    _speechLevel = target;

    // Баллистика: атака 20 мс, спад 300 мс (время интеграции VU-метра)
    final tau = target > _meterLevel ? 0.02 : 0.3;
    _meterLevel += (target - _meterLevel) * (1.0 - math.exp(-dt / tau));

    return _meterLevel;
  }

  /// Проверить, звучит ли в данном фрагменте человеческая речь выше фонового шума.
  bool isSpeech(
    Float32List samples, {
    double threshold = 0.08,
    bool immediate = false,
  }) {
    if (samples.isEmpty) return false;
    final level = update(samples);
    return (immediate ? _speechLevel : level) >= threshold;
  }
}
