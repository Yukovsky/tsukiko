import 'dart:math' as math;
import 'dart:typed_data';

import 'acoustic_feature_extractor.dart';
import 'keyword_tokenizer.dart';
import 'speech_verifier.dart';

/// One pronunciation recorded by the user. No raw microphone audio is stored.
class KeywordTemplate {
  const KeywordTemplate({required this.durationSamples, required this.frames});

  final int durationSamples;
  final List<Float32List> frames;

  static KeywordTemplate? fromAudio(
    Float32List audio, {
    int minActiveSamples = 4000,
  }) {
    final speech = SpeechVerifier.prepareCalibrationSamples(
      audio,
      minActiveSamples: minActiveSamples,
    );
    if (speech.isEmpty) return null;
    final frames = AcousticFeatureExtractor.keywordFrames(speech);
    if (frames.length < 10 || frames.length > 120) return null;
    return KeywordTemplate(durationSamples: speech.length, frames: frames);
  }

  static KeywordTemplate? fromCalibrationAudio(Float32List audio) {
    final word = SpeechVerifier.prepareIsolatedKeywordSamples(audio);
    return word.isEmpty ? null : fromAudio(word);
  }

  Map<String, Object> toJson() => {
    'durationSamples': durationSamples,
    'frames': [for (final row in frames) row.toList()],
  };

  static KeywordTemplate? fromJson(Object? value) {
    if (value is! Map) return null;
    final length = value['durationSamples'];
    final rawFrames = value['frames'];
    if (length is! int ||
        length < 5600 ||
        length > 96000 ||
        rawFrames is! List ||
        rawFrames.length < 10 ||
        rawFrames.length > 120) {
      return null;
    }
    final frames = <Float32List>[];
    for (final raw in rawFrames) {
      if (raw is! List ||
          raw.length != 12 ||
          raw.any((element) => element is! num || !element.isFinite)) {
        return null;
      }
      frames.add(
        Float32List.fromList(raw.cast<num>().map((n) => n.toDouble()).toList()),
      );
    }
    return KeywordTemplate(durationSamples: length, frames: frames);
  }
}

/// Banded dynamic time warping: compare how a phrase evolves, not just its
/// average timbre. Longer/shorter pronunciations can align locally.
double keywordDistance(KeywordTemplate a, KeywordTemplate b) {
  final left = a.frames;
  final right = b.frames;
  if (left.isEmpty || right.isEmpty) return double.infinity;
  final previous = Float64List(right.length + 1);
  final current = Float64List(right.length + 1);
  previous.fillRange(0, previous.length, double.infinity);
  previous[0] = 0;
  final band = math.max(8, (left.length - right.length).abs() + 8);
  for (var i = 1; i <= left.length; i++) {
    current.fillRange(0, current.length, double.infinity);
    final middle = (i * right.length / left.length).round();
    final low = math.max(1, middle - band);
    final high = math.min(right.length, middle + band);
    for (var j = low; j <= high; j++) {
      var squared = 0.0;
      for (var d = 0; d < 12; d++) {
        final delta = left[i - 1][d] - right[j - 1][d];
        squared += delta * delta;
      }
      final cost = math.sqrt(squared / 12);
      current[j] =
          cost +
          math.min(previous[j - 1], math.min(previous[j], current[j - 1]));
    }
    previous.setAll(0, current);
  }
  return previous[right.length] / math.max(left.length, right.length);
}

/// The calibration threshold follows leave-one-out positive distances.
/// A large outlier is rejected during enrollment instead of making all later
/// detections permissive.
double keywordThreshold(List<KeywordTemplate> templates) {
  if (templates.length < 2) return 0.82;
  var largestNearest = 0.0;
  for (var i = 0; i < templates.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < templates.length; j++) {
      if (i != j) {
        nearest = math.min(
          nearest,
          keywordDistance(templates[i], templates[j]),
        );
      }
    }
    largestNearest = math.max(largestNearest, nearest);
  }
  return (largestNearest + 0.10).clamp(0.75, 1.05);
}

/// Compare the transition into the last phoneme, excluding edge padding.
/// Whole-word DTW can stretch a matching prefix over a missing ending.
double keywordEndingDistance(KeywordTemplate a, KeywordTemplate b) {
  KeywordTemplate middleEnd(KeywordTemplate value) {
    final start = (value.frames.length * 0.65).floor();
    final end = (value.frames.length * 0.95).ceil();
    return KeywordTemplate(
      durationSamples: value.durationSamples,
      frames: value.frames.sublist(start, end),
    );
  }

  return keywordDistance(middleEnd(a), middleEnd(b));
}

double keywordEndingThreshold(List<KeywordTemplate> templates) {
  if (templates.length < 2) return 0.9;
  var largestNearest = 0.0;
  for (var i = 0; i < templates.length; i++) {
    var nearest = double.infinity;
    for (var j = 0; j < templates.length; j++) {
      if (i != j) {
        nearest = math.min(
          nearest,
          keywordEndingDistance(templates[i], templates[j]),
        );
      }
    }
    largestNearest = math.max(largestNearest, nearest);
  }
  return (largestNearest + 0.18).clamp(0.48, 1.08);
}

/// Both keywords are scored once, after a complete acoustic segment. Sliding
/// windows over arbitrary speech fragments produced false wake activations.
class PersonalKeywordSpotter {
  PersonalKeywordSpotter({
    required this.wakeWord,
    required this.closeWord,
    required this.wakeTemplates,
    required this.closeTemplates,
    this.wakeNegatives = const [],
    this.closeNegatives = const [],
  }) : wakeThreshold = keywordThreshold(wakeTemplates),
       wakeEndingThreshold = keywordEndingThreshold(wakeTemplates),
       closeEndingThreshold = keywordEndingThreshold(closeTemplates),
       closeThreshold = closeTemplates.isEmpty
           ? 0
           : keywordThreshold(closeTemplates);

  final String wakeWord;
  final String closeWord;
  final List<KeywordTemplate> wakeTemplates;
  final List<KeywordTemplate> closeTemplates;
  final List<KeywordTemplate> wakeNegatives;
  final List<KeywordTemplate> closeNegatives;
  final double wakeThreshold;
  final double wakeEndingThreshold;
  final double closeThreshold;
  final double closeEndingThreshold;
  bool listenForClose = false;

  /// With a second-stage verifier the acoustic stage only proposes
  /// candidates. Diagnostic replay: MFCC-DTW distances of spoken keywords
  /// (median 0.94) overlap the 1–5th percentile of ordinary speech, so no
  /// threshold here separates them; recall is recovered by the verifier.
  bool proposeCandidates = false;
  static const looseWakeGate = 1.12;
  static const looseCloseGate = 1.14;

  /// Only attached during an explicit developer diagnostic recording.
  void Function(KeywordScore score)? onScore;

  Float32List _recent = Float32List(0);
  int _sinceEvaluation = 0;
  String? _pending;
  KeywordCandidate? _candidate;
  int _totalSamples = 0;
  final _wakeSegments = _StreamingSpeechSegments(
    minQuietFrames: 9,
    minGate: 0.0015,
  );
  // 400 ms of silence after a close word: mid-phrase pauses are shorter, so
  // "я пока в бургеркинге" no longer ends as a standalone "пока".
  final _closeSegments = _StreamingSpeechSegments(
    minQuietFrames: 20,
    minGate: 0.0045,
  );

  String? takeDetection() {
    final result = _pending;
    _pending = null;
    return result;
  }

  /// Strict detections and, with [proposeCandidates], loose ones, each with
  /// the audio around the segment for verification.
  KeywordCandidate? takeCandidate() {
    final result = _candidate;
    _candidate = null;
    _pending = null;
    return result;
  }

  void reset() {
    _recent = Float32List(0);
    _sinceEvaluation = 0;
    _pending = null;
    _candidate = null;
    _totalSamples = 0;
    _wakeSegments.reset();
    _closeSegments.reset();
  }

  void acceptAudio(Float32List audio) {
    if (audio.isEmpty || _pending != null) return;
    const maxSamples = 16000 * 3;
    final keep = math.min(maxSamples, _recent.length + audio.length).toInt();
    final next = Float32List(keep);
    final oldCount = math
        .min(_recent.length, keep - math.min(audio.length, keep))
        .toInt();
    final addedCount = math.min(audio.length, keep).toInt();
    next.setRange(0, oldCount, _recent, _recent.length - oldCount);
    next.setRange(oldCount, keep, audio, audio.length - addedCount);
    _recent = next;
    _totalSamples += audio.length;
    if (listenForClose) {
      _closeSegments.acceptAudio(audio);
    } else {
      _wakeSegments.acceptAudio(audio);
    }
    _sinceEvaluation += audio.length;
    if (_sinceEvaluation < 1600) return;
    _sinceEvaluation %= 1600;

    if (listenForClose) {
      final evaluated = _evaluateCompletedCloseSegment();
      if (!evaluated) {
        onScore?.call(
          KeywordScore(
            wake: double.infinity,
            close: double.infinity,
            wakeNegative: double.infinity,
            closeNegative: double.infinity,
            wakeThreshold: wakeThreshold,
            closeThreshold: closeThreshold,
            candidate: null,
            closeReason: 'awaiting_boundary',
          ),
        );
      }
      return;
    }
    _evaluateCompletedWakeSegment();
  }

  bool _evaluateCompletedWakeSegment() {
    final segment = _wakeSegments.takeSegment();
    if (segment == null) return false;
    final start = segment.$1 - (_totalSamples - _recent.length);
    final end = segment.$2 - (_totalSamples - _recent.length);
    if (start < 0 || end > _recent.length || start >= end) return false;
    if (wakeTemplates.isEmpty) return true;
    final meanLength =
        wakeTemplates.map((t) => t.durationSamples).reduce((a, b) => a + b) ~/
        wakeTemplates.length;
    final length = end - start;
    final minWakeDuration = math.max(3800, (meanLength * 0.40).round());
    final maxWakeDuration = math.min(
      16000 * 1.25,
      math.max(16000 * 0.85, (meanLength * 2.4).round()),
    );
    final strictDuration =
        length >= minWakeDuration && length <= maxWakeDuration;
    // Merged segments ("смотри, Джев") are left to the verifier.
    if (!strictDuration &&
        !(proposeCandidates && length >= 4000 && length <= 16000 * 1.6)) {
      _emitRejectedWake(length, 'duration');
      return true;
    }
    final candidate = KeywordTemplate.fromAudio(
      _segmentAudio(start, end, padding: 1600),
      minActiveSamples: 2400,
    );
    if (candidate == null) {
      _emitRejectedWake(length, 'invalid_audio');
      return true;
    }
    final wake = _distanceTo(
      candidate,
      wakeTemplates,
      maxEndingDistance: wakeEndingThreshold,
    );
    // Competing words are scored without an ending gate: filtering them out
    // would make an ambiguous segment appear uniquely wake-like.
    final close = _distanceTo(candidate, closeTemplates);
    final negative = _distanceTo(candidate, wakeNegatives);
    final isolated = segment.$3 >= 35;
    final strongNegativeMargin =
        wakeNegatives.isNotEmpty && negative > wake + 0.12;
    var threshold = wakeThreshold;
    if (isolated && strongNegativeMargin) {
      final passingEndingCount = wakeTemplates
          .where(
            (t) => keywordEndingDistance(candidate, t) < wakeEndingThreshold,
          )
          .length;
      final rawDists =
          wakeTemplates.map((t) => keywordDistance(candidate, t)).toList()
            ..sort();
      final hasWholeWordMatch =
          rawDists.isNotEmpty &&
          rawDists.first < wakeThreshold &&
          (rawDists.length < 2 || rawDists.last - rawDists.first <= 0.08);
      if (wakeTemplates.length < 2 ||
          passingEndingCount >= 2 ||
          hasWholeWordMatch) {
        threshold = math.min(1.09, wakeThreshold + 0.07);
      }
    }
    if (segment.$4 && !isolated) {
      threshold = math.min(threshold, 0.99);
    }
    final longPronunciation = length > meanLength * 1.5;
    final boundaryOkay =
        !segment.$4 ||
        segment.$3 >= 8 ||
        (wake < 0.92 &&
            strongNegativeMargin &&
            (closeTemplates.isEmpty || close > wake + 0.08));
    final scoreThreshold = longPronunciation && !strongNegativeMargin
        ? math.min(threshold, 0.96)
        : threshold;
    final voiced = _hasVoicedFrames(start, end);
    final accepted =
        strictDuration &&
        wake < scoreThreshold &&
        boundaryOkay &&
        (closeTemplates.isEmpty ||
            close > wake + 0.04 ||
            (isolated && strongNegativeMargin)) &&
        negative > wake + 0.04 &&
        voiced;
    final rawWake = !accepted && proposeCandidates && voiced
        ? _rawDistance(candidate, wakeTemplates)
        : double.infinity;
    final loose =
        rawWake < looseWakeGate &&
        negative + 0.05 >= rawWake &&
        close + 0.05 >= rawWake;
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: negative,
        closeNegative: double.infinity,
        wakeThreshold: scoreThreshold,
        closeThreshold: closeThreshold,
        candidate: accepted || loose ? wakeWord : null,
        wakeSegmentMs: length * 1000 ~/ 16000,
        wakeSegmentAgeMs: (_totalSamples - segment.$2) * 1000 ~/ 16000,
        wakePrecedingQuietMs: segment.$3 * 20,
        wakeReason: accepted
            ? 'accepted'
            : loose
            ? 'candidate'
            : boundaryOkay
            ? 'score'
            : 'boundary',
      ),
    );
    if (accepted) {
      _pending = KeywordTokenizer.normalizeKeywordText(wakeWord);
    }
    if (accepted || loose) {
      _candidate = KeywordCandidate(
        keyword: KeywordTokenizer.normalizeKeywordText(wakeWord),
        strict: accepted,
        distance: rawWake,
        audio: _verificationAudio(start, end),
      );
    }
    return true;
  }

  void _emitRejectedWake(int length, String reason) {
    onScore?.call(
      KeywordScore(
        wake: double.infinity,
        close: double.infinity,
        wakeNegative: double.infinity,
        closeNegative: double.infinity,
        wakeThreshold: wakeThreshold,
        closeThreshold: closeThreshold,
        candidate: null,
        wakeSegmentMs: length * 1000 ~/ 16000,
        wakeReason: reason,
      ),
    );
  }

  bool _evaluateCompletedCloseSegment() {
    final segment = _closeSegments.takeSegment();
    if (segment == null) return false;
    final start = segment.$1 - (_totalSamples - _recent.length);
    final end = segment.$2 - (_totalSamples - _recent.length);
    if (start < 0 || end > _recent.length || start >= end) return false;
    final length = end - start;
    final meanLength = closeTemplates.isEmpty
        ? 0
        : closeTemplates
                  .map((template) => template.durationSamples)
                  .reduce((a, b) => a + b) ~/
              closeTemplates.length;
    final durationMs = length * 1000 ~/ 16000;
    String reason = 'duration';
    var close = double.infinity;
    var wake = double.infinity;
    var negative = double.infinity;
    var threshold = closeThreshold;
    final maxDuration = proposeCandidates
        ? 16000 * 1.5
        : math.min(
            16000 * 0.9,
            math.max(16000 * 0.65, (meanLength * 1.4).round()),
          );
    if (segment.$4 && segment.$3 < 14) {
      // A close word is a separate command. Syllables carved out of a longer
      // utterance can score like the template but have no preceding boundary.
      reason = 'boundary';
    } else if (meanLength > 0 &&
        length >= math.max(3200, (meanLength * 0.40).round()) &&
        length <= maxDuration) {
      final candidate = KeywordTemplate.fromAudio(
        _segmentAudio(start, end),
        minActiveSamples: 1600,
      );
      if (candidate != null) {
        close = _distanceTo(
          candidate,
          closeTemplates,
          // A short ending is more sensitive to framing than whole-word DTW.
          // Keep it a completeness veto; the full score and both competing
          // words below still decide whether this is a command.
          maxEndingDistance: math.max(1.15, closeEndingThreshold + 0.08),
        );
        wake = _distanceTo(candidate, wakeTemplates);
        negative = _distanceTo(candidate, closeNegatives);
        final isolated = segment.$3 >= 15;
        // Extra timing/noise headroom requires separation from BOTH the other
        // command and the recorded confusable word, not just a low raw score.
        final strongNegativeMargin =
            closeNegatives.isNotEmpty && negative > close + 0.12;
        threshold = strongNegativeMargin
            ? math.min(1.05, closeThreshold)
            : (isolated && negative > close + 0.06)
            ? math.min(1.01, closeThreshold)
            : math.min(0.99, closeThreshold);
        final rawClose = _rawDistance(candidate, closeTemplates);
        final looseOk =
            proposeCandidates &&
            rawClose < looseCloseGate &&
            negative + 0.05 >= rawClose &&
            (wake >= wakeThreshold || wake + 0.05 >= rawClose) &&
            _hasVoicedFrames(start, end);
        if (close >= threshold || length > 16000 * 0.9) {
          reason = looseOk ? 'candidate' : 'score';
        } else if (wake < wakeThreshold && wake + 0.04 < close) {
          reason = looseOk ? 'candidate' : 'wake_word';
        } else if (negative <= close + (closeNegatives.isEmpty ? 0 : 0.05)) {
          reason = looseOk ? 'candidate' : 'negative_word';
        } else if (!_hasVoicedFrames(start, end)) {
          reason = 'unvoiced';
        } else {
          reason = 'accepted';
          _pending = KeywordTokenizer.normalizeKeywordText(closeWord);
        }
        if (reason == 'accepted' || reason == 'candidate') {
          _candidate = KeywordCandidate(
            keyword: KeywordTokenizer.normalizeKeywordText(closeWord),
            strict: reason == 'accepted',
            distance: rawClose,
            audio: _verificationAudio(start, end),
          );
        }
      } else {
        reason = 'invalid_audio';
      }
    }
    onScore?.call(
      KeywordScore(
        wake: wake,
        close: close,
        wakeNegative: double.infinity,
        closeNegative: negative,
        wakeThreshold: wakeThreshold,
        closeThreshold: threshold,
        candidate: reason == 'accepted' || reason == 'candidate'
            ? closeWord
            : null,
        closeSegmentMs: durationMs,
        closeSegmentAgeMs: (_totalSamples - segment.$2) * 1000 ~/ 16000,
        closePrecedingQuietMs: segment.$3 * 20,
        closeReason: reason,
      ),
    );
    return true;
  }

  double _distanceTo(
    KeywordTemplate candidate,
    List<KeywordTemplate> templates, {
    double? maxEndingDistance,
  }) {
    if (templates.isEmpty) return double.infinity;
    final validDists = <double>[];
    final allDists = <double>[];
    for (final template in templates) {
      final d = keywordDistance(candidate, template);
      allDists.add(d);
      if (maxEndingDistance != null &&
          keywordEndingDistance(candidate, template) >= maxEndingDistance) {
        continue;
      }
      validDists.add(d);
    }
    if (validDists.isEmpty) return double.infinity;
    validDists.sort();
    allDists.sort();
    var best = validDists[0];
    if (validDists.length >= 2) {
      final spread = validDists[1] - validDists[0];
      if (spread > 0.08) {
        best += (spread - 0.08) * 1.5;
      }
    } else if (allDists.length >= 2) {
      final spread = allDists[1] - allDists[0];
      if (spread > 0.08) {
        best += (spread - 0.08) * 1.5;
      }
    }
    return best;
  }

  /// Plain nearest-template DTW: the ending veto and spread penalty rejected
  /// real keywords outright (the verifier makes the final decision).
  double _rawDistance(
    KeywordTemplate candidate,
    List<KeywordTemplate> templates,
  ) => templates.isEmpty
      ? double.infinity
      : templates.map((t) => keywordDistance(candidate, t)).reduce(math.min);

  /// Half a second of context before the word: a verifier needs to hear
  /// whether it was a separate utterance. Copied, since [_recent] rotates.
  Float32List _verificationAudio(int start, int end) => Float32List.fromList(
    Float32List.sublistView(
      _recent,
      math.max(0, start - 8000),
      math.min(_recent.length, end + 3200),
    ),
  );

  Float32List _segmentAudio(int start, int end, {int padding = 960}) =>
      Float32List.sublistView(
        _recent,
        math.max(0, start - padding),
        math.min(_recent.length, end + padding),
      );

  bool _hasVoicedFrames(int start, int end) {
    var voiced = 0;
    for (var at = start; at + 400 < end; at += 640) {
      var energy = 0.0;
      for (var j = 0; j < 400; j++) {
        final sample = _recent[at + j];
        energy += sample * sample;
      }
      if (energy < 0.008) continue;
      var strongest = 0.0;
      for (var lag = 40; lag <= 200; lag += 4) {
        var dot = 0.0;
        var left = 0.0;
        var right = 0.0;
        for (var j = 0; j < 400 - lag; j++) {
          final a = _recent[at + j];
          final b = _recent[at + j + lag];
          dot += a * b;
          left += a * a;
          right += b * b;
        }
        final correlation = dot / math.sqrt(left * right + 1e-12);
        strongest = math.max(strongest, correlation);
      }
      var dot15 = 0.0;
      var left15 = 0.0;
      var right15 = 0.0;
      for (var j = 0; j < 400 - 15; j++) {
        final a = _recent[at + j];
        final b = _recent[at + j + 15];
        dot15 += a * b;
        left15 += a * a;
        right15 += b * b;
      }
      final corr15 = dot15 / math.sqrt(left15 * right15 + 1e-12);
      final isDrone = corr15 >= 0.72 && strongest <= corr15 + 0.03;
      if (!isDrone && strongest >= 0.50 && ++voiced >= 2) return true;
    }
    return false;
  }
}

/// Makes one irrevocable boundary decision per 20 ms frame. Re-scanning a
/// rolling buffer changed old segment endpoints as its noise quantile moved,
/// so a word from over a second ago could be accepted during the next word.
class _StreamingSpeechSegments {
  _StreamingSpeechSegments({this.minQuietFrames = 9, this.minGate = 0.0015});

  final int minQuietFrames;
  final double minGate;
  static const frameSamples = 320;
  final _frame = Float32List(frameSamples);
  final _levels = <double>[];
  final _completed = <(int, int, int, bool)>[];
  int _frameFill = 0;
  int _processedSamples = 0;
  int? _start;
  int _lastActiveEnd = 0;
  int _quietFrames = 0;
  int _leadingQuietFrames = 0;
  int? _candidateStart;
  int _candidateActiveFrames = 0;
  int _candidateQuietFrames = 0;
  int _segmentLeadingQuietFrames = 0;
  bool _hasPriorSpeech = false;
  bool _segmentHasPriorSpeech = false;

  void reset() {
    _frameFill = 0;
    _processedSamples = 0;
    _levels.clear();
    _completed.clear();
    _start = null;
    _lastActiveEnd = 0;
    _quietFrames = 0;
    _leadingQuietFrames = 0;
    _candidateStart = null;
    _candidateActiveFrames = 0;
    _candidateQuietFrames = 0;
    _segmentLeadingQuietFrames = 0;
    _hasPriorSpeech = false;
    _segmentHasPriorSpeech = false;
  }

  void acceptAudio(Float32List audio) {
    for (final sample in audio) {
      _frame[_frameFill++] = sample;
      if (_frameFill == frameSamples) {
        _acceptFrame();
        _frameFill = 0;
      }
    }
  }

  (int, int, int, bool)? takeSegment() =>
      _completed.isEmpty ? null : _completed.removeAt(0);

  void _acceptFrame() {
    var power = 0.0;
    for (final sample in _frame) {
      power += sample * sample;
    }
    final level = math.sqrt(power / frameSamples);
    final sorted = [..._levels]..sort();
    final noise = sorted.isEmpty ? 0.001 : sorted[sorted.length ~/ 4];
    final gate = math.max(minGate, noise * 2.1);
    final active = level >= gate;
    final frameStart = _processedSamples;
    _processedSamples += frameSamples;

    if (_start == null) {
      if (active) {
        if (_candidateStart == null) {
          _candidateStart = frameStart;
          _candidateActiveFrames = 0;
          _candidateQuietFrames = 0;
        }
        _candidateActiveFrames++;
        _candidateQuietFrames = 0;
        if (_candidateActiveFrames >= 4 && _leadingQuietFrames >= 5) {
          _start = _candidateStart;
          _segmentLeadingQuietFrames = _leadingQuietFrames;
          _segmentHasPriorSpeech = _hasPriorSpeech;
          _lastActiveEnd = _processedSamples;
          _quietFrames = 0;
          _candidateStart = null;
          _candidateActiveFrames = 0;
        }
      } else {
        if (_candidateStart == null) {
          _leadingQuietFrames++;
        } else if (++_candidateQuietFrames >= 4) {
          // A brief isolated burst is noise, not the onset of a word.
          _leadingQuietFrames += _candidateActiveFrames + _candidateQuietFrames;
          _candidateStart = null;
          _candidateActiveFrames = 0;
          _candidateQuietFrames = 0;
        }
      }
    } else if (active) {
      _lastActiveEnd = _processedSamples;
      _quietFrames = 0;
    } else if (++_quietFrames >= minQuietFrames) {
      final start = _start!;
      final end = _lastActiveEnd;
      if (end - start >= 2400 && end - start <= 16000 * 2.4) {
        _completed.add((
          start,
          end,
          _segmentLeadingQuietFrames,
          _segmentHasPriorSpeech,
        ));
      }
      _hasPriorSpeech = true;
      _start = null;
      _leadingQuietFrames = _quietFrames;
      _quietFrames = 0;
    }

    _levels.add(level);
    if (_levels.length > 150) _levels.removeAt(0);
  }
}

class KeywordCandidate {
  const KeywordCandidate({
    required this.keyword,
    required this.strict,
    required this.distance,
    required this.audio,
  });

  final String keyword;

  /// Passed the standalone acoustic thresholds (used without a verifier).
  final bool strict;
  final double distance;
  final Float32List audio;
}

class KeywordScore {
  const KeywordScore({
    required this.wake,
    required this.close,
    required this.wakeNegative,
    required this.closeNegative,
    required this.wakeThreshold,
    required this.closeThreshold,
    required this.candidate,
    this.closeSegmentMs,
    this.closeSegmentAgeMs,
    this.closePrecedingQuietMs,
    this.closeReason,
    this.wakeSegmentMs,
    this.wakeSegmentAgeMs,
    this.wakePrecedingQuietMs,
    this.wakeReason,
  });

  final double wake;
  final double close;
  final double wakeNegative;
  final double closeNegative;
  final double wakeThreshold;
  final double closeThreshold;
  final String? candidate;
  final int? closeSegmentMs;
  final int? closeSegmentAgeMs;
  final int? closePrecedingQuietMs;
  final String? closeReason;
  final int? wakeSegmentMs;
  final int? wakeSegmentAgeMs;
  final int? wakePrecedingQuietMs;
  final String? wakeReason;

  Map<String, Object?> toJson() => {
    'wake': wake.isFinite ? wake : null,
    'close': close.isFinite ? close : null,
    'wakeNegative': wakeNegative.isFinite ? wakeNegative : null,
    'closeNegative': closeNegative.isFinite ? closeNegative : null,
    'wakeThreshold': wakeThreshold,
    'closeThreshold': closeThreshold,
    'candidate': candidate,
    if (closeSegmentMs != null) 'closeSegmentMs': closeSegmentMs,
    if (closeSegmentAgeMs != null) 'closeSegmentAgeMs': closeSegmentAgeMs,
    if (closePrecedingQuietMs != null)
      'closePrecedingQuietMs': closePrecedingQuietMs,
    if (closeReason != null) 'closeReason': closeReason,
    if (wakeSegmentMs != null) 'wakeSegmentMs': wakeSegmentMs,
    if (wakeSegmentAgeMs != null) 'wakeSegmentAgeMs': wakeSegmentAgeMs,
    if (wakePrecedingQuietMs != null)
      'wakePrecedingQuietMs': wakePrecedingQuietMs,
    if (wakeReason != null) 'wakeReason': wakeReason,
  };
}
