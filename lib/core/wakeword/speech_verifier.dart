import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../platform/os.dart';
import '../library.dart' show findWhisper;
import '../logger.dart';
import '../models.dart' show looksLikeSpeechModel;
import 'acoustic_feature_extractor.dart';
import 'wakeword_models.dart';

/// Результат проверки произнесённого слова.
class SpeechVerificationResult {
  const SpeechVerificationResult({
    required this.matched,
    required this.recognizedText,
    this.extractedEmbedding,
    this.errorMessage,
  });

  final bool matched;
  final String recognizedText;
  final Float32List? extractedEmbedding;
  final String? errorMessage;
}

/// Верификатор речи и ключевых слов на базе встроенного в Tsukiko движка Whisper.
///
/// Запускает `tsukiko-recognizer` с быстрой моделью `ggml-tiny.bin` на GPU/CPU,
/// выполняет точную и устойчивую к шуму проверку произнесённых слов на русском и английском языках,
/// и извлекает акустический слепок голоса.
class SpeechVerifier {
  SpeechVerifier({
    this.customRecognizerPath,
    this.customModelPath,
    this.sherpaLibraryDir,
  });

  final String? customRecognizerPath;
  final String? customModelPath;

  /// flutter_test does not link plugin binaries; the app leaves this null.
  final String? sherpaLibraryDir;

  /// Найти путь к исполняемому файлу распознавателя tsukiko-recognizer.
  String? get recognizerExe => customRecognizerPath ?? findWhisper();

  /// Найти быструю модель (предпочтительно ggml-tiny.bin, либо любая доступная).
  String? get fastModelPath {
    final explicit = customModelPath;
    if (explicit != null && File(explicit).existsSync()) {
      return explicit;
    }

    // Same latency as tiny on diagnostic replay, but 11/12 wake words
    // recognized instead of 7/12.
    final basePath = os.join(os.modelsDir, 'ggml-base.bin');
    if (File(basePath).existsSync()) return basePath;

    final tinyPath = os.join(os.modelsDir, 'ggml-tiny.bin');
    if (File(tinyPath).existsSync()) return tinyPath;

    // Любая доступная модель в папке моделей
    try {
      final dir = Directory(os.modelsDir);
      if (dir.existsSync()) {
        final files = dir.listSync().whereType<File>();
        for (final f in files) {
          final name = os.basename(f.path);
          if (looksLikeSpeechModel(name) && name.endsWith('.bin')) {
            return f.path;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// Проверить, произнесено ли целевое ключевое слово в аудиофайле WAV.
  Future<SpeechVerificationResult> verifyWavFile(
    String wavPath, {
    required String targetWord,
    Float32List? audioSamples,
  }) async {
    final exe = recognizerExe;
    final model = fastModelPath;

    if (exe == null || !File(exe).existsSync()) {
      Log.warn('SpeechVerifier', 'Recognizer executable not found ($exe)');
      return const SpeechVerificationResult(
        matched: false,
        recognizedText: '',
        errorMessage: 'Recognizer not found',
      );
    }

    if (model == null || !File(model).existsSync()) {
      Log.warn('SpeechVerifier', 'Whisper model not found for verification');
      return const SpeechVerificationResult(
        matched: false,
        recognizedText: '',
        errorMessage: 'Model not found',
      );
    }

    try {
      final res = await Process.run(exe, [
        '-m',
        model,
        '-l',
        keywordLanguage(targetWord),
        '-f',
        wavPath,
        '-np',
        '-nt',
      ]);

      final rawText = (res.stdout as String? ?? '').trim();
      final cleanedText = _cleanWhisperText(rawText);

      final matched = matchesKeyword(cleanedText, targetWord);

      Float32List? embedding;
      if (audioSamples != null && audioSamples.isNotEmpty) {
        embedding = AcousticFeatureExtractor.extract(audioSamples);
      } else {
        final readSamples = readWavSamples(wavPath);
        if (readSamples.isNotEmpty) {
          embedding = AcousticFeatureExtractor.extract(readSamples);
        }
      }

      Log.info(
        'SpeechVerifier',
        'Verification: target="$targetWord", recognized="$cleanedText", matched=$matched',
      );

      return SpeechVerificationResult(
        matched: matched,
        recognizedText: cleanedText,
        extractedEmbedding: embedding,
      );
    } catch (e, st) {
      Log.error('SpeechVerifier', 'Error verifying speech: $e', e, st);
      return SpeechVerificationResult(
        matched: false,
        recognizedText: '',
        errorMessage: '$e',
      );
    }
  }

  bool get isAvailable {
    final exe = recognizerExe;
    return exe != null && File(exe).existsSync() && fastModelPath != null;
  }

  /// In-process recognizer for Russian keywords; loaded only while voice
  /// activation runs (~116 MB resident). Until it is downloaded and loaded,
  /// the whisper process below does the same job, only slower.
  sherpa.OfflineRecognizer? _russian;
  int _prepareGeneration = 0;

  static bool isRussian(String word) => word.contains(RegExp(r'[А-Яа-яЁё]'));

  Future<void> prepare({
    required String wakeWord,
    String closeWord = '',
  }) async {
    final generation = ++_prepareGeneration;
    if (!isRussian(wakeWord) && !isRussian(closeWord)) {
      release();
      return;
    }
    if (_russian != null) return;
    if (!await WakeWordModelPaths.ensureRuAsrInstalled()) return;
    if (generation != _prepareGeneration) return;
    try {
      await sherpa.initBindingsAsync(sherpaLibraryDir);
      if (generation != _prepareGeneration) return;
      _russian = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            transducer: sherpa.OfflineTransducerModelConfig(
              encoder: WakeWordModelPaths.ruAsrEncoder,
              decoder: WakeWordModelPaths.ruAsrDecoder,
              joiner: WakeWordModelPaths.ruAsrJoiner,
            ),
            tokens: WakeWordModelPaths.ruAsrTokens,
            numThreads: 1,
            debug: false,
          ),
        ),
      );
      Log.info('SpeechVerifier', 'Russian keyword verifier loaded');
    } catch (e, st) {
      Log.error('SpeechVerifier', 'Russian verifier failed: $e', e, st);
    }
  }

  void release() {
    _prepareGeneration++;
    _russian?.free();
    _russian = null;
  }

  String? _recognizeRussian(Float32List samples) {
    final recognizer = _russian;
    if (recognizer == null) return null;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      // Synchronous FFI on the audio isolate, 26 ms on M5; move to
      // a worker isolate if slow machines show dropped audio frames.
      recognizer.decode(stream);
      return recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  /// Язык, на котором whisper распознаёт окно со словом: по письменности
  /// самого слова. Латиница — английский, а не «auto»: на секундном окне
  /// автоопределение прыгает между языками и пишет одно и то же слово то
  /// так, то эдак, а написания из калибровки рассчитаны на один и тот же
  /// способ записи при калибровке и при срабатывании.
  static String keywordLanguage(String word) {
    for (final (pattern, lang) in const [
      (r'[\p{Script=Hiragana}\p{Script=Katakana}]', 'ja'),
      (r'\p{Script=Hangul}', 'ko'),
      (r'\p{Script=Han}', 'zh'),
      (r'\p{Script=Cyrillic}', 'ru'),
      (r'\p{Script=Greek}', 'el'),
      (r'\p{Script=Arabic}', 'ar'),
      (r'\p{Script=Hebrew}', 'he'),
      (r'\p{Script=Thai}', 'th'),
      (r'\p{Script=Devanagari}', 'hi'),
      (r'\p{Script=Georgian}', 'ka'),
      (r'\p{Script=Armenian}', 'hy'),
    ]) {
      if (RegExp(pattern, unicode: true).hasMatch(word)) return lang;
    }
    return 'en';
  }

  /// Распознать короткое окно тем же движком, что проверяет срабатывания:
  /// русские слова — встроенным zipformer, остальные — whisper. null —
  /// распознать нечем или движок сломался.
  ///
  /// Калибровка зовёт его же на каждом образце слова: так написания в
  /// профиле получаются тем самым распознавателем, который потом и
  /// проверяет.
  Future<String?> recognize(Float32List samples, String keyword) async {
    if (samples.isEmpty) return null;
    if (isRussian(keyword)) {
      final text = _recognizeRussian(samples);
      if (text != null) return text;
    }
    final exe = recognizerExe;
    final model = fastModelPath;
    if (exe == null || model == null) return null;
    final wav = os.join(
      Directory.systemTemp.path,
      'tsukiko_kws_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    try {
      writeWavFile(wav, samples);
      final process = await Process.start(exe, [
        '-m',
        model,
        '-l',
        keywordLanguage(keyword),
        '-t',
        '2',
        '-f',
        wav,
        '-np',
        '-nt',
      ]);
      final stdoutText = process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      process.stderr.drain<void>();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code != 0) return null;
      return await stdoutText;
    } catch (e) {
      Log.warn('SpeechVerifier', 'Keyword recognition failed: $e');
      return null;
    } finally {
      try {
        File(wav).deleteSync();
      } catch (_) {}
    }
  }

  /// Что услышал последний [confirmKeyword] — для диагностики.
  String? lastHeard;

  /// Second stage of voice activation: recognize a short candidate window.
  /// Returns null when no recognizer is available or it fails.
  ///
  /// [spellings] — написания слова из калибровки (`SpeakerProfile`).
  Future<bool?> confirmKeyword(
    Float32List samples,
    String keyword, {
    required bool isClose,
    List<String> spellings = const [],
  }) async {
    final text = lastHeard = await recognize(samples, keyword);
    if (text == null) return null;
    return isClose
        ? matchesOnlyCommand(text, keyword, spellings: spellings)
        : matchesSpokenKeyword(text, keyword, spellings: spellings);
  }

  static List<String> _words(String text) => _cleanWhisperText(text)
      .toLowerCase()
      .replaceAll('ё', 'е')
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();

  /// Ключ для сравнения написаний на любом языке: без регистра, знаков и
  /// повторов букв («Джефф» и «джеф», «heyyy» и «hey» — одно), «ё» как
  /// «е». Правил произношения конкретных языков здесь нет и не нужно:
  /// оглушение на конце, редукция гласных, кана против иероглифов — всё
  /// это уже есть в написаниях, которые распознаватель выдал на образцах
  /// при калибровке.
  static String spellingKey(String text) => _cleanWhisperText(text)
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAllMapped(RegExp(r'(\p{L})\1+', unicode: true), (m) => m[1]!);

  /// Пишется ли язык без пробелов между словами — тогда слово ищется
  /// в начале фразы как в строке, а не по словам.
  static bool _spaceless(String text) => RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}'
    r'\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]',
    unicode: true,
  ).hasMatch(text);

  /// Начинается ли услышанное с одного из [accepted]. Именно начинается:
  /// слово посреди фразы («что это за Джефф такой» из видео) — разговор,
  /// а не обращение. И именно целым словом: «Джеффри» — не «Джефф».
  static bool startsWithKeyword(
    String recognizedText,
    Iterable<String> accepted,
  ) {
    final heard = spellingKey(recognizedText);
    if (heard.isEmpty) return false;
    final words = heard.split(' ');
    for (final spelling in accepted) {
      final key = spellingKey(spelling);
      if (key.isEmpty) continue;
      if (_spaceless(key)) {
        if (heard.replaceAll(' ', '').startsWith(key.replaceAll(' ', ''))) {
          return true;
        }
        continue;
      }
      final target = key.split(' ');
      if (words.length >= target.length &&
          words.take(target.length).join(' ') == key) {
        return true;
      }
    }
    return false;
  }

  /// Слово активации в начале услышанного.
  ///
  /// С написаниями из калибровки — строгое сравнение с ними. Без них
  /// (профиль старше этой проверки) — прежнее мягкое: одна буква на слово
  /// и «Джефф»/«Jeff» за «Джев», но тоже только в начале фразы. Мягкое
  /// пропускало «Джеп», «Джем», «Джек», «Джес» — замер на диагностике
  /// 2026-10-25: 12 ложных срабатываний на 30 созвучных словах; оно
  /// остаётся только до новой калибровки.
  static bool matchesSpokenKeyword(
    String recognizedText,
    String keyword, {
    List<String> spellings = const [],
  }) {
    if (spellings.isNotEmpty) {
      return startsWithKeyword(recognizedText, [keyword, ...spellings]);
    }
    final target = _words(keyword);
    final words = _words(recognizedText);
    if (target.isEmpty || words.length < target.length) return false;
    const jeff = {'джеф', 'джефф', 'джев', 'jeff', 'geoff'};
    bool same(String heard, String expected) =>
        (jeff.contains(expected) && jeff.contains(heard)) ||
        _editDistance(heard, expected) <= (expected.length >= 4 ? 1 : 0);
    for (var j = 0; j < target.length; j++) {
      if (!same(words[j], target[j])) return false;
    }
    return true;
  }

  /// A close word is a common word ("пока"), so it must be exact and be the
  /// only thing said: "всем пока" or "я пока" is dictation, not a command.
  static bool matchesOnlyCommand(
    String recognizedText,
    String keyword, {
    List<String> spellings = const [],
  }) {
    final heard = spellingKey(recognizedText);
    if (heard.isEmpty) return false;
    for (final spelling in {keyword, ...spellings}) {
      final target = spellingKey(spelling);
      if (target.isEmpty) continue;
      if (RegExp('^(${RegExp.escape(target)} ?)+\$').hasMatch(heard)) {
        return true;
      }
    }
    return false;
  }

  static int _editDistance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = [i];
      for (var j = 1; j <= b.length; j++) {
        current.add(
          math.min(
            math.min(previous[j] + 1, current[j - 1] + 1),
            previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return previous[b.length];
  }

  /// Проверить порцию аудиосэмплов Float32List (сохраняет временный WAV и проверяет).
  Future<SpeechVerificationResult> verifySamples(
    Float32List samples, {
    required String targetWord,
  }) async {
    if (samples.isEmpty) {
      return const SpeechVerificationResult(
        matched: false,
        recognizedText: '',
        errorMessage: 'Empty audio samples',
      );
    }

    final tmpPath = os.join(
      Directory.systemTemp.path,
      'tsukiko_verify_${DateTime.now().microsecondsSinceEpoch}.wav',
    );

    try {
      writeWavFile(tmpPath, samples);
      final result = await verifyWavFile(
        tmpPath,
        targetWord: targetWord,
        audioSamples: samples,
      );
      return result;
    } finally {
      try {
        final f = File(tmpPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// Проверить, совпадает ли распознанный текст с целевым словом активации.
  static bool matchesKeyword(String recognizedText, String targetWord) {
    final cleanTarget = _cleanWhisperText(targetWord).toLowerCase();
    if (cleanTarget.isEmpty) return false;

    final cleanRecognized = _cleanWhisperText(recognizedText).toLowerCase();
    if (cleanRecognized.isEmpty) return false;

    // A substring and edit-distance-one check accepts confusable words such
    // as "деф" or "стопка". Compare complete word sequences instead.
    final words = cleanRecognized.split(RegExp(r'\s+'));
    final candidates = cleanTarget == 'джеф' || cleanTarget == 'джефф'
        ? const {'джеф', 'джефф', 'jeff', 'geoff'}
        : {cleanTarget};
    return candidates.any((candidate) {
      final targetWords = candidate.split(' ');
      for (var i = 0; i + targetWords.length <= words.length; i++) {
        if (words.skip(i).take(targetWords.length).join(' ') == candidate) {
          return true;
        }
      }
      return false;
    });
  }

  /// Enrollment must contain the keyword alone; an occurrence somewhere in
  /// a sentence would produce a voice profile for the entire sentence.
  static bool matchesOnlyKeyword(String recognizedText, String targetWord) {
    final recognized = _cleanWhisperText(recognizedText).toLowerCase();
    final target = _cleanWhisperText(targetWord).toLowerCase();
    if (recognized.isEmpty || target.isEmpty) return false;
    if (recognized == target) return true;
    if (target == 'джеф' || target == 'джефф') {
      return const {'джеф', 'джефф', 'jeff', 'geoff'}.contains(recognized);
    }
    return false;
  }

  /// Discard leading/trailing room noise before building an enrollment vector.
  /// Returns an empty buffer for silence, clipping, or an implausibly long take.
  static Float32List prepareCalibrationSamples(
    Float32List audio, {
    int minActiveSamples = 4000,
  }) {
    if (audio.length < 5600 || audio.length > 16000 * 6) return Float32List(0);
    var peak = 0.0;
    var clipped = 0;
    for (final sample in audio) {
      final value = sample.abs();
      if (value > peak) peak = value;
      if (value >= 0.98) clipped++;
    }
    if (peak < 0.008 || clipped > audio.length ~/ 100) return Float32List(0);
    const frame = 320; // 20 ms
    final threshold = math.max(0.006, peak * 0.07);
    int? first;
    int? last;
    for (var start = 0; start + frame <= audio.length; start += frame) {
      var power = 0.0;
      for (var i = start; i < start + frame; i++) {
        power += audio[i] * audio[i];
      }
      if (math.sqrt(power / frame) >= threshold) {
        first ??= start;
        last = start + frame;
      }
    }
    if (first == null || last == null || last - first < minActiveSamples) {
      return Float32List(0);
    }
    final start = math.max(0, first - 1600);
    final end = math.min(audio.length, last + 1600);
    return Float32List.sublistView(audio, start, end);
  }

  /// Keep one complete word from an enrollment take. Button clicks and short
  /// breaths otherwise become part of every template and inflate its duration.
  /// Ambiguous takes with two substantial utterances are rejected.
  static Float32List prepareIsolatedKeywordSamples(Float32List audio) {
    if (audio.length < 5600 || audio.length > 16000 * 6) return Float32List(0);
    var peak = 0.0;
    var clipped = 0;
    for (final sample in audio) {
      final value = sample.abs();
      if (value > peak) peak = value;
      if (value >= 0.98) clipped++;
    }
    if (peak < 0.008 || clipped > audio.length ~/ 100) return Float32List(0);

    const frame = 320;
    final count = audio.length ~/ frame;
    final rms = List<double>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      var power = 0.0;
      for (var j = i * frame; j < (i + 1) * frame; j++) {
        power += audio[j] * audio[j];
      }
      rms[i] = math.sqrt(power / frame);
    }
    final sorted = [...rms]..sort();
    final noise = sorted[count ~/ 4];
    final loudest = sorted.last;
    final threshold = math.max(0.0015, math.max(noise * 3, loudest * 0.08));
    final active = [for (final level in rms) level >= threshold];
    var previousActive = -1;
    for (var i = 0; i < count; i++) {
      if (!active[i]) continue;
      if (previousActive >= 0 && i - previousActive <= 6) {
        for (var j = previousActive + 1; j < i; j++) {
          active[j] = true;
        }
      }
      previousActive = i;
    }
    final segments = <(int, int)>[];
    int? start;
    for (var i = 0; i <= count; i++) {
      final speech = i < count && active[i];
      if (speech && start == null) start = i;
      if (!speech && start != null) {
        if (i - start >= 8) segments.add((start, i));
        start = null;
      }
    }
    if (segments.isEmpty) return Float32List(0);
    segments.sort((a, b) => (b.$2 - b.$1).compareTo(a.$2 - a.$1));
    final chosen = segments.first;
    final chosenFrames = chosen.$2 - chosen.$1;
    if (chosenFrames < 13 || chosenFrames > 120) return Float32List(0);
    if (segments.skip(1).any((segment) {
      final length = segment.$2 - segment.$1;
      return length >= 13 && length >= chosenFrames * 0.5;
    })) {
      return Float32List(0);
    }
    final from = math.max(0, chosen.$1 * frame - 960);
    final to = math.min(audio.length, chosen.$2 * frame + 960);
    return Float32List.sublistView(audio, from, to);
  }

  /// Очистить вывод Whisper от спецтегов вроде [Музыка], (Шум), скобок и пунктуации.
  static String _cleanWhisperText(String raw) {
    return raw
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Чтение PCM Float32List сэмплов из 16 кГц моно 16-битного WAV файла.
  static Float32List readWavSamples(String path) {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() < 44) return Float32List(0);
      final bytes = file.readAsBytesSync();

      var offset = 12;
      while (offset + 8 <= bytes.length) {
        final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        final chunkSize = ByteData.sublistView(
          bytes,
          offset + 4,
          offset + 8,
        ).getUint32(0, Endian.little);
        if (chunkId == 'data') {
          final dataStart = offset + 8;
          final dataEnd = math.min(bytes.length, dataStart + chunkSize);
          final sampleBytes = bytes.sublist(dataStart, dataEnd);
          final numSamples = sampleBytes.length ~/ 2;
          final floats = Float32List(numSamples);
          final bd = ByteData.sublistView(sampleBytes);
          for (var i = 0; i < numSamples; i++) {
            floats[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
          }
          return floats;
        }
        offset += 8 + chunkSize;
      }
      return Float32List(0);
    } catch (_) {
      return Float32List(0);
    }
  }

  /// Запись 16 кГц моно 16-битного WAV файла из Float32List сэмплов [-1.0, 1.0].
  static void writeWavFile(String path, Float32List samples) {
    final numSamples = samples.length;
    final byteRate = 16000 * 1 * 2; // sampleRate * channels * bytesPerSample
    final blockAlign = 1 * 2;
    final subchunk2Size = numSamples * 2;
    final chunkSize = 36 + subchunk2Size;

    final header = ByteData(44);
    // "RIFF"
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, chunkSize, Endian.little);
    // "WAVE"
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // "fmt "
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    header.setUint16(20, 1, Endian.little); // AudioFormat (1 for PCM)
    header.setUint16(22, 1, Endian.little); // NumChannels (1 mono)
    header.setUint32(24, 16000, Endian.little); // SampleRate (16000)
    header.setUint32(28, byteRate, Endian.little); // ByteRate
    header.setUint16(32, blockAlign, Endian.little); // BlockAlign
    header.setUint16(34, 16, Endian.little); // BitsPerSample
    // "data"
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, subchunk2Size, Endian.little);

    final pcmBytes = Uint8List(subchunk2Size);
    final pcmBd = ByteData.sublistView(pcmBytes);
    for (var i = 0; i < numSamples; i++) {
      final s = (samples[i] * 32767.0).clamp(-32768.0, 32767.0).toInt();
      pcmBd.setInt16(i * 2, s, Endian.little);
    }

    final outBytes = Uint8List(44 + subchunk2Size);
    outBytes.setAll(0, header.buffer.asUint8List());
    outBytes.setAll(44, pcmBytes);

    File(path).writeAsBytesSync(outBytes);
  }
}
