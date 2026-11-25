import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../logger.dart';
import 'acoustic_feature_extractor.dart';
import 'adaptive_noise_filter.dart';
import 'keyword_tokenizer.dart';
import 'personal_keyword_spotter.dart';
import 'speaker_profile.dart';
import 'wakeword_models.dart';

/// Результат распознавания ключевого слова.
class KeywordDetection {
  const KeywordDetection({
    required this.keyword,
    this.samples,
    this.strict = true,
  });

  final String keyword;
  final Float32List? samples;

  /// False for a loose acoustic candidate that is valid only once verified.
  final bool strict;
}

/// Абстракция над движком распознавания ключевых слов и голоса.
///
/// Позволяет подменять движок в тестах (`FakeSherpaEngine`),
/// гарантируя полную изоляцию от микрофона и файловой системы.
abstract class SherpaEngine {
  bool get isReady;

  /// Инициализировать детектор ключевых слов.
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
    String enterWord = '',
    SpeakerProfile? profile,
  });

  /// Инициализировать детектор активности речи (VAD).
  Future<bool> initVad();

  /// Инициализировать систему верификации спикера.
  Future<bool> initSpeakerRecognition({List<Float32List>? enrolledEmbeddings});

  /// Передать порцию сэмплов в движок (16 кГц, моно).
  void acceptAudio(Float32List samples);

  bool isSpeech(Float32List samples, {bool immediate = false});

  /// Проверить, сработало ли ключевое слово на текущем шаге.
  KeywordDetection? detectKeyword();

  /// Сбросить состояние потока ключевых слов.
  void resetKeywordStream();

  /// Извлечь эмбеддинг спикера из аудиофрагмента.
  Float32List? extractSpeakerEmbedding(Float32List audio);

  /// Проверить, принадлежит ли голос пользователю по порогу сходства.
  bool verifySpeaker(Float32List embedding, double threshold);

  /// Освободить ресурсы.
  void dispose();
}

/// Streaming KWS. The model consumes every PCM frame, including quiet frames
/// needed to finalize a keyword. No WAV creation or subprocess is on this path.
class StreamingSherpaEngine extends AcousticSpeakerEngine {
  PersonalKeywordSpotter? _personal;
  PersonalKeywordSpotter? _personalEnter;
  bool _listeningForClose = false;
  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  KeywordDetection? _pending;
  final List<Float32List> _recent = [];
  int _recentSamples = 0;
  static const _maxRecentSamples = 16000 * 2;

  void setScoreListener(void Function(KeywordScore)? listener) {
    _personal?.onScore = listener;
    _personalEnter?.onScore = listener;
  }

  void setListeningForClose(bool value) {
    _listeningForClose = value;
    _personal?.listenForClose = value;
  }

  void setProposeCandidates(bool value) {
    _personal?.proposeCandidates = value;
    _personalEnter?.proposeCandidates = value;
  }

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
    String enterWord = '',
    SpeakerProfile? profile,
  }) async {
    dispose();
    if (KeywordTokenizer.normalizeKeywordText(wakeWord).isEmpty) return false;
    if (profile != null && profile.hasEnterTemplatesFor(enterWord)) {
      _personalEnter = PersonalKeywordSpotter(
        wakeWord: wakeWord,
        closeWord: enterWord,
        wakeTemplates: profile.hasWakeTemplatesFor(wakeWord)
            ? profile.wakeTemplates
            : const [],
        closeTemplates: profile.enterTemplates,
        closeNegatives: profile.enterNegatives,
      )..listenForClose = true;
    }
    if (profile != null && profile.hasWakeTemplatesFor(wakeWord)) {
      final hasClose = profile.hasCloseTemplatesFor(closeWord);
      _personal = PersonalKeywordSpotter(
        wakeWord: wakeWord,
        closeWord: closeWord,
        wakeTemplates: profile.wakeTemplates,
        closeTemplates: hasClose ? profile.closeTemplates : const [],
        wakeNegatives: profile.wakeNegatives,
        closeNegatives: hasClose ? profile.closeNegatives : const [],
      );
      await super.initKeywordSpotter(wakeWord: wakeWord, closeWord: closeWord);
      Log.info('WakeWord', 'Personal wake and close word templates loaded');
      return true;
    }
    if (!await WakeWordModelPaths.ensureKwsInstalled()) return false;
    try {
      await sherpa.initBindingsAsync();
      final tokenizer = SentencePieceTokenizer.fromModelFileSync(
        WakeWordModelPaths.kwsBpe,
      );
      final keywords = [wakeWord, if (closeWord.trim().isNotEmpty) closeWord]
          .map((word) => KeywordTokenizer.formatForModel(word, tokenizer))
          .where((word) => word.isNotEmpty)
          .toSet()
          .toList();
      if (keywords.isEmpty) return false;
      final keywordFile = File(
        '${WakeWordModelPaths.kwsDir}/tsukiko_keywords.txt',
      );
      await keywordFile.writeAsString('${keywords.join('\n')}\n');
      _spotter = sherpa.KeywordSpotter(
        sherpa.KeywordSpotterConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: WakeWordModelPaths.kwsEncoder,
              decoder: WakeWordModelPaths.kwsDecoder,
              joiner: WakeWordModelPaths.kwsJoiner,
            ),
            tokens: WakeWordModelPaths.kwsTokens,
            numThreads: 2,
          ),
          keywordsFile: keywordFile.path,
          maxActivePaths: 1,
          keywordsScore: 1.5,
          keywordsThreshold: 0.25,
        ),
      );
      _stream = _spotter!.createStream();
      await super.initKeywordSpotter(wakeWord: wakeWord, closeWord: closeWord);
      return true;
    } catch (e, st) {
      Log.error('WakeWord', 'Streaming KWS initialization failed: $e', e, st);
      dispose();
      return false;
    }
  }

  @override
  void acceptAudio(Float32List samples) {
    if (_listeningForClose) _personalEnter?.acceptAudio(samples);
    final personal = _personal;
    if (personal != null) {
      personal.acceptAudio(samples);
      return;
    }
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null || samples.isEmpty) return;
    _recent.add(Float32List.fromList(samples));
    _recentSamples += samples.length;
    while (_recentSamples > _maxRecentSamples && _recent.isNotEmpty) {
      _recentSamples -= _recent.removeAt(0).length;
    }
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      final keyword = spotter.getResult(stream).keyword;
      if (keyword.isEmpty) continue;
      final audio = Float32List(_recentSamples);
      var offset = 0;
      for (final frame in _recent) {
        audio.setAll(offset, frame);
        offset += frame.length;
      }
      _pending = KeywordDetection(
        keyword: keyword.replaceAll('_', ' '),
        samples: audio,
      );
      spotter.reset(stream);
      _recent.clear();
      _recentSamples = 0;
      break;
    }
  }

  @override
  KeywordDetection? detectKeyword() {
    final closeOrWake = _personal?.takeCandidate();
    final enter = _personalEnter?.takeCandidate();
    if (closeOrWake != null || enter != null) {
      // Prefer a strict match over a loose one. A tie favors stopping without
      // submitting unless the Enter template is acoustically closer.
      final candidate = switch ((closeOrWake, enter)) {
        (null, final send?) => send,
        (final close?, final send?)
            when send.strict && !close.strict ||
                send.strict == close.strict && send.distance < close.distance =>
          send,
        _ => closeOrWake!,
      };
      _pending = null;
      return KeywordDetection(
        keyword: candidate.keyword,
        samples: candidate.audio,
        strict: candidate.strict,
      );
    }
    final result = _pending;
    _pending = null;
    return result;
  }

  @override
  void resetKeywordStream() {
    _personal?.reset();
    _personalEnter?.reset();
    final spotter = _spotter;
    final stream = _stream;
    if (spotter != null && stream != null) spotter.reset(stream);
    _pending = null;
    _recent.clear();
    _recentSamples = 0;
  }

  @override
  void dispose() {
    _personal?.reset();
    _personalEnter?.reset();
    _personal = null;
    _personalEnter = null;
    _listeningForClose = false;
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
    _pending = null;
    _recent.clear();
    _recentSamples = 0;
    super.dispose();
  }
}

/// Lightweight acoustic second stage for an enrolled voice. Keyword
/// recognition itself belongs to [StreamingSherpaEngine].
class AcousticSpeakerEngine implements SherpaEngine {
  AcousticSpeakerEngine({AdaptiveNoiseFilter? noiseFilter})
    : _noiseFilter = noiseFilter ?? AdaptiveNoiseFilter();

  final AdaptiveNoiseFilter _noiseFilter;
  final List<Float32List> _enrolledEmbeddings = [];
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
    String enterWord = '',
    SpeakerProfile? profile,
  }) async {
    _ready = true;
    return true;
  }

  @override
  Future<bool> initVad() async {
    _noiseFilter.reset();
    return true;
  }

  @override
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  }) async {
    _enrolledEmbeddings
      ..clear()
      ..addAll(enrolledEmbeddings ?? const []);
    return true;
  }

  @override
  void acceptAudio(Float32List samples) {}

  @override
  bool isSpeech(Float32List samples, {bool immediate = false}) =>
      _noiseFilter.isSpeech(samples, immediate: immediate);

  @override
  KeywordDetection? detectKeyword() => null;

  @override
  void resetKeywordStream() {}

  @override
  Float32List? extractSpeakerEmbedding(Float32List audio) {
    if (audio.isEmpty) return null;
    try {
      return AcousticFeatureExtractor.extract(audio);
    } catch (e) {
      Log.error('WakeWord', 'Error extracting acoustic embedding: $e');
      return null;
    }
  }

  @override
  bool verifySpeaker(Float32List embedding, double threshold) {
    if (_enrolledEmbeddings.isEmpty) return true;
    double maxSim = -1;
    double sum = 0;
    for (final enrolled in _enrolledEmbeddings) {
      final sim = AcousticSpeakerEngine._cosineSimilarity(enrolled, embedding);
      if (sim > maxSim) maxSim = sim;
      sum += sim;
    }
    final score = 0.7 * maxSim + 0.3 * sum / _enrolledEmbeddings.length;
    return score.isFinite && score >= threshold;
  }

  static double _cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0;
    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    return normA > 0 && normB > 0
        ? dot / (math.sqrt(normA) * math.sqrt(normB))
        : 0;
  }

  @override
  void dispose() {
    _ready = false;
    _enrolledEmbeddings.clear();
  }
}

/// Тестовая реализация для юнит-тестов (офлайн).
class FakeSherpaEngine implements SherpaEngine {
  bool spotterInitialized = false;
  bool vadInitialized = false;
  bool speakerInitialized = false;

  String configuredWakeWord = '';
  String configuredCloseWord = '';
  String configuredEnterWord = '';
  KeywordDetection? queuedDetection;
  bool speechDetected = false;
  double? forcedVerificationResult;

  @override
  bool get isReady => spotterInitialized;

  @override
  Future<bool> initKeywordSpotter({
    required String wakeWord,
    String closeWord = '',
    String enterWord = '',
    SpeakerProfile? profile,
  }) async {
    configuredWakeWord = wakeWord;
    configuredCloseWord = closeWord;
    configuredEnterWord = enterWord;
    spotterInitialized = true;
    return true;
  }

  @override
  Future<bool> initVad() async {
    vadInitialized = true;
    return true;
  }

  @override
  Future<bool> initSpeakerRecognition({
    List<Float32List>? enrolledEmbeddings,
  }) async {
    speakerInitialized = true;
    return true;
  }

  @override
  void acceptAudio(Float32List samples) {}

  @override
  bool isSpeech(Float32List samples, {bool immediate = false}) =>
      speechDetected;

  @override
  KeywordDetection? detectKeyword() {
    final res = queuedDetection;
    queuedDetection = null;
    return res;
  }

  @override
  void resetKeywordStream() {}

  @override
  Float32List? extractSpeakerEmbedding(Float32List audio) {
    return Float32List(192);
  }

  @override
  bool verifySpeaker(Float32List embedding, double threshold) {
    if (forcedVerificationResult != null) {
      return forcedVerificationResult! >= threshold;
    }
    return true;
  }

  @override
  void dispose() {
    spotterInitialized = false;
    vadInitialized = false;
    speakerInitialized = false;
  }
}
