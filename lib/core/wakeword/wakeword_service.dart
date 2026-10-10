import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../logger.dart';
import '../whisper_server.dart' show DictationSettings, PhraseCompletionMode;
import 'audio_stream_source.dart';
import 'keyword_tokenizer.dart';
import 'sherpa_engine.dart';
import 'speaker_profile.dart';
import 'speech_verifier.dart';
import 'wake_diagnostics.dart';

/// В каком состоянии находится голосовая активация.
enum WakeWordListeningState {
  disabled,
  listeningWakeWord,
  listeningCloseWordOrSilence,
}

/// Сервис фоновой голосовой активации (WakeWord) и завершающего слова (CloseWord).
///
/// Управляет аудиопотоком, персональным детектором ключевых слов и таймером
/// тишины для завершения фразы. Для старого профиля возможен Sherpa fallback.
class WakeWordService {
  WakeWordService({
    AudioStreamSource? audioSource,
    SherpaEngine? engine,
    this.verifier,
  }) : _audioSource = audioSource ?? MicrophoneAudioStreamSource(),
       _engine = engine ?? StreamingSherpaEngine();

  final AudioStreamSource _audioSource;
  final SherpaEngine _engine;

  /// Second stage: every acoustic detection with audio is re-recognized by
  /// whisper before it starts or ends a recording. Without it only strict
  /// acoustic detections count.
  final SpeechVerifier? verifier;
  bool _verifierReady = false;
  bool _verifying = false;
  int _stateEpoch = 0;

  WakeWordListeningState _state = WakeWordListeningState.disabled;
  WakeWordListeningState get state => _state;

  StreamSubscription<Float32List>? _audioSub;
  Timer? _audioWatchdog;
  DateTime? _lastAudioFrameAt;
  bool _restartingAudio = false;
  Completer<void>? _audioRestartDone;
  bool _isSuspendedForSleep = false;
  bool get isSuspendedForSleep => _isSuspendedForSleep;
  int _consecutiveSilentRestarts = 0;
  static const int _maxRapidRestarts = 3;
  DictationSettings? _settings;
  SpeakerProfile? _profile;
  WakeDiagnosticsSession? _diagnostics;

  bool get isDiagnosing => _diagnostics != null;
  String? get diagnosticsPath => _diagnostics?.directory;

  String? startDiagnostics({String? root}) {
    if (!isRunning || _settings == null) return null;
    if (_diagnostics != null) return _diagnostics!.directory;
    final session = WakeDiagnosticsSession.start(
      wakeWord: _settings!.wakeWord,
      closeWord: _settings!.closeWord,
      profile: _profile,
      detector:
          _profile?.hasPersonalKeywordsFor(
                _settings!.wakeWord,
                _settings!.closeWord,
              ) ??
              false
          ? 'personal-mfcc-dtw'
          : 'sherpa-onnx',
      root: root,
    );
    _diagnostics = session;
    if (_engine is StreamingSherpaEngine) {
      _engine.setScoreListener(session.score);
    }
    return session.directory;
  }

  void markDiagnostics(String word) {
    if (word != 'wake' && word != 'close' && word != 'other') return;
    _diagnostics?.mark(word);
  }

  Future<String?> stopDiagnostics() async {
    final session = _diagnostics;
    if (session == null) return null;
    _diagnostics = null;
    if (_engine is StreamingSherpaEngine) {
      _engine.setScoreListener(null);
    }
    await session.stop();
    return session.directory;
  }

  // Обратные вызовы для кубита диктовки
  void Function()? onWakeWordTriggered;

  /// The UI may still be transcribing the previous phrase even though the
  /// microphone is already back in wake mode. Ignore such detections without
  /// locking the detector until the next manual recording.
  bool Function()? canTriggerWakeWord;
  void Function()? onCloseWordTriggered;
  void Function()? onSilenceTimeoutTriggered;
  void Function(String error)? onError;

  /// Время последней зафиксированной речи для таймера тишины (2.0 секунды).
  DateTime? _lastSpeechTime;
  static const Duration silenceThreshold = Duration(milliseconds: 2000);

  /// Запущен ли сервис.
  bool get isRunning => _state != WakeWordListeningState.disabled;

  int _operationGeneration = 0;
  bool _triggeredInCurrentState = false;
  bool _wakeSuspended = false;
  bool _startedByVoice = false;
  DateTime? _lastCompletionAt;
  static const Duration retriggerDelay = Duration(milliseconds: 700);

  /// Была ли текущая запись инициирована голосом (WakeWord).
  bool get startedByVoice => _startedByVoice;

  /// Запустить сервис голосовой активации с указанными настройками.
  Future<bool> start({
    required DictationSettings settings,
    SpeakerProfile? profile,
  }) async {
    if (!settings.wakeWordEnabled) {
      await stop();
      return false;
    }

    final nextProfile = profile ?? SpeakerProfile.load();
    // A new calibration changes the detector itself, so rebuild its stream.
    if (_state != WakeWordListeningState.disabled &&
        _settings?.wakeWord == settings.wakeWord &&
        _settings?.closeWord == settings.closeWord &&
        _profile?.createdAt == nextProfile?.createdAt) {
      _settings = settings;
      _profile = nextProfile;
      return true;
    }

    final generation = ++_operationGeneration;
    await stop(invalidate: false);
    if (_operationGeneration != generation) return false;

    _settings = settings;
    _profile = nextProfile;

    final hasPerm = await _audioSource.hasPermission();
    if (_operationGeneration != generation) return false;
    if (!hasPerm) {
      Log.warn('WakeWord', 'Microphone permission not granted for WakeWord');
      onError?.call('Microphone permission not granted');
      return false;
    }

    // Инициализируем KWS
    final kwsOk = await _engine.initKeywordSpotter(
      wakeWord: settings.wakeWord,
      closeWord: settings.closeWord,
      profile: _profile,
    );
    if (_operationGeneration != generation) return false;

    if (!kwsOk) {
      Log.warn('WakeWord', 'Failed to initialize SherpaOnnx KeywordSpotter');
      onError?.call('Failed to initialize KeywordSpotter');
      return false;
    }

    // Only the personal detector proposes short candidate windows; the
    // legacy Sherpa path keeps its own decisions.
    _verifierReady =
        (_profile?.hasPersonalKeywordsFor(
              settings.wakeWord,
              settings.closeWord,
            ) ??
            false) &&
        (verifier?.isAvailable ?? false);
    if (_engine is StreamingSherpaEngine) {
      _engine.setProposeCandidates(_verifierReady);
    }
    if (_verifierReady) {
      // Downloads once, then loads in the background; whisper covers the gap.
      unawaited(
        verifier!.prepare(
          wakeWord: settings.wakeWord,
          closeWord: settings.closeWord,
        ),
      );
    }

    // Инициализируем VAD
    await _engine.initVad();
    if (_operationGeneration != generation) return false;

    // Personal templates include the speaker's pronunciation. Legacy
    // aggregate voiceprints caused false rejections and are not used.
    await _engine.initSpeakerRecognition();
    if (_operationGeneration != generation) return false;

    // Запускаем аудиопоток
    try {
      final stream = await _audioSource.startStream(sampleRate: 16000);
      if (_operationGeneration != generation) {
        await _audioSource.stopStream();
        return false;
      }
      _listenToAudio(stream, generation);
      _state = WakeWordListeningState.listeningWakeWord;
      _triggeredInCurrentState = false;
      _startWatchdog(generation);
      Log.info(
        'WakeWord',
        'WakeWord service listening for "${settings.wakeWord}"',
      );
      return true;
    } catch (e, st) {
      Log.error('WakeWord', 'Failed to start audio stream: $e', e, st);
      await stop();
      return false;
    }
  }

  void _startWatchdog(int generation) {
    _audioWatchdog?.cancel();
    _audioWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isSuspendedForSleep ||
          _state == WakeWordListeningState.disabled ||
          generation != _operationGeneration) {
        return;
      }
      final last = _lastAudioFrameAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        final Duration threshold;
        if (_consecutiveSilentRestarts >= _maxRapidRestarts) {
          final backoffSeconds = math.min(
            60,
            10 *
                (1 <<
                    math.min(
                      3,
                      _consecutiveSilentRestarts - _maxRapidRestarts,
                    )),
          );
          threshold = Duration(seconds: backoffSeconds);
        } else {
          threshold = const Duration(seconds: 3);
        }
        if (elapsed >= threshold) {
          unawaited(_restartAudioStream(generation));
        }
      }
    });
  }

  /// Приостановить прослушивание аудио на время системного сна.
  /// Освобождает микрофон, отменяет watchdog и останавливает аудиопоток,
  /// предотвращая цикличный рестарт стрима и утечку системных ресурсов.
  Future<void> pauseForSleep() async {
    if (_isSuspendedForSleep || _state == WakeWordListeningState.disabled) return;
    _isSuspendedForSleep = true;
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _audioSource.stopStream();
    _engine.resetKeywordStream();
    _consecutiveSilentRestarts = 0;
    Log.info('WakeWord', 'Audio listening paused for system sleep');
  }

  /// Возобновить прослушивание аудио после пробуждения системы.
  Future<void> resumeFromSleep() async {
    if (!_isSuspendedForSleep) return;
    _isSuspendedForSleep = false;
    _consecutiveSilentRestarts = 0;
    if (_state == WakeWordListeningState.disabled ||
        _settings == null ||
        !_settings!.wakeWordEnabled) {
      return;
    }
    Log.info('WakeWord', 'Resuming audio listening after system wake');
    try {
      final generation = _operationGeneration;
      final stream = await _audioSource.startStream(sampleRate: 16000);
      if (_operationGeneration != generation || _isSuspendedForSleep) {
        await _audioSource.stopStream();
        return;
      }
      _listenToAudio(stream, generation);
      _startWatchdog(generation);
    } catch (e) {
      Log.error('WakeWord', 'Failed to resume audio stream after wake: $e');
    }
  }

  void _listenToAudio(Stream<Float32List> stream, int generation) {
    _lastAudioFrameAt = DateTime.now();
    _audioSub = stream.listen(
      _onAudioFrame,
      onError: (Object error) {
        Log.error('WakeWord', 'Audio stream error: $error');
        unawaited(_restartAudioStream(generation));
      },
      onDone: () => unawaited(_restartAudioStream(generation)),
    );
  }

  Future<void> _restartAudioStream(int generation) async {
    if (_restartingAudio ||
        _isSuspendedForSleep ||
        _state == WakeWordListeningState.disabled ||
        generation != _operationGeneration) {
      return;
    }
    _restartingAudio = true;
    _audioRestartDone = Completer<void>();
    _consecutiveSilentRestarts++;
    _lastAudioFrameAt = DateTime.now();
    _diagnostics?.event('audio_stream_restarting', {
      'attempt': _consecutiveSilentRestarts,
    });
    Log.warn(
      'WakeWord',
      'Audio stream stopped delivering samples (attempt $_consecutiveSilentRestarts); restarting',
    );
    try {
      await _audioSub?.cancel();
      _audioSub = null;
      await _audioSource.stopStream();
      if (_state == WakeWordListeningState.disabled ||
          _isSuspendedForSleep ||
          generation != _operationGeneration) {
        return;
      }
      final stream = await _audioSource.startStream(sampleRate: 16000);
      if (_state == WakeWordListeningState.disabled ||
          _isSuspendedForSleep ||
          generation != _operationGeneration) {
        await _audioSource.stopStream();
        return;
      }
      _engine.resetKeywordStream();
      _listenToAudio(stream, generation);
      _diagnostics?.event('audio_stream_restarted');
    } catch (error, stack) {
      Log.error(
        'WakeWord',
        'Audio stream restart failed: $error',
        error,
        stack,
      );
      _diagnostics?.event('audio_stream_restart_failed', {'error': '$error'});
      // The watchdog retries while voice activation remains enabled.
    } finally {
      _restartingAudio = false;
      _audioRestartDone?.complete();
      _audioRestartDone = null;
    }
  }

  /// Уведомить сервис, что началась запись фразы (диктовка активна).
  ///
  /// [startedByVoice] указывает, была ли запись инициирована голосом (WakeWord).
  /// Согласно логике tsukiko, таймаут простоя/тишины (2-3 сек) работает
  /// исключительно для записей, инициированных голосом. Записи, начатые
  /// клавишей или UI, не должны прерываться по тишине.
  void notifyRecordingStarted({bool startedByVoice = false}) {
    if (_state == WakeWordListeningState.disabled) return;
    _startedByVoice = startedByVoice;
    _stateEpoch++;
    _state = WakeWordListeningState.listeningCloseWordOrSilence;
    _triggeredInCurrentState = false;
    _wakeSuspended = false;
    _lastSpeechTime = DateTime.now();
    _engine.resetKeywordStream();
    if (_engine is StreamingSherpaEngine) _engine.setListeningForClose(true);
    _diagnostics?.event('recording_started', {
      'started_by_voice': startedByVoice,
    });
    Log.info(
      'WakeWord',
      'Now listening for CloseWord or silence... (startedByVoice: $startedByVoice)',
    );
  }

  /// Уведомить сервис, что запись завершилась (диктовка остановлена).
  void notifyRecordingStopped() {
    if (_state == WakeWordListeningState.disabled) return;
    _startedByVoice = false;
    _stateEpoch++;
    _state = WakeWordListeningState.listeningWakeWord;
    _triggeredInCurrentState = false;
    _lastCompletionAt = DateTime.now();
    _lastSpeechTime = null;
    _engine.resetKeywordStream();
    if (_engine is StreamingSherpaEngine) _engine.setListeningForClose(false);
    _diagnostics?.event('recording_stopped');
    Log.info('WakeWord', 'Returned to listening for WakeWord');
  }

  /// Обработка порции аудио с микрофона.
  void _onAudioFrame(Float32List samples) {
    if (_state == WakeWordListeningState.disabled || samples.isEmpty) return;
    _lastAudioFrameAt = DateTime.now();
    _consecutiveSilentRestarts = 0;

    final diagnostics = _diagnostics;
    if (diagnostics != null) {
      try {
        diagnostics.recordAudio(samples);
        if (diagnostics.samples >= WakeDiagnosticsSession.maxSamples) {
          unawaited(stopDiagnostics());
        }
      } catch (e) {
        Log.error('WakeWord', 'Diagnostic recording failed: $e');
        unawaited(stopDiagnostics());
      }
    }

    // While transcription is finishing, a trailing word must not latch the
    // next wake cycle. Resume from a fresh stream once the UI is idle.
    if (_state == WakeWordListeningState.listeningWakeWord &&
        !(canTriggerWakeWord?.call() ?? true)) {
      if (!_wakeSuspended) {
        _wakeSuspended = true;
        _engine.resetKeywordStream();
        _diagnostics?.event('wake_suspended_busy');
      }
      return;
    }
    if (_wakeSuspended) {
      _wakeSuspended = false;
      _engine.resetKeywordStream();
      _diagnostics?.event('wake_resumed');
    }

    // KWS получает и тихие кадры: они нужны для завершения слова.
    // isSpeech ниже отдельно обновляет адаптивный шумовой фон.
    _engine.acceptAudio(samples);

    final now = DateTime.now();
    final bool isSpeech = _engine.isSpeech(samples);
    if (isSpeech) {
      _lastSpeechTime = now;
    }

    // ── 1. Режим ожидания слова активации (WakeWord) ──────────────────────────
    if (_state == WakeWordListeningState.listeningWakeWord) {
      final detection = _engine.detectKeyword();
      if (detection != null && !_triggeredInCurrentState) {
        if (_lastCompletionAt != null &&
            now.difference(_lastCompletionAt!) < retriggerDelay) {
          return;
        }
        _lastSpeechTime = null;
        final detected = KeywordTokenizer.normalizeKeywordText(
          detection.keyword,
        );
        final expected = KeywordTokenizer.normalizeKeywordText(
          _settings?.wakeWord ?? '',
        );

        if (detected == expected) {
          _confirm(
            detection,
            isClose: false,
            fire: () {
              if (!(canTriggerWakeWord?.call() ?? true)) {
                _diagnostics?.event('wake_ignored_busy', {'keyword': detected});
                _engine.resetKeywordStream();
                return;
              }
              _diagnostics?.event('wake_triggered', {'keyword': detected});
              Log.info('WakeWord', 'Spotted keyword: "$detected"');
              _triggeredInCurrentState = true;
              onWakeWordTriggered?.call();
            },
          );
        }
      }
      return;
    }

    // ── 2. Режим ожидания слова завершения (CloseWord) или тишины ──────────────
    if (_state == WakeWordListeningState.listeningCloseWordOrSilence) {
      final settings = _settings;
      if (settings == null) return;

      final mode = settings.completionMode;
      final closeWord = KeywordTokenizer.normalizeKeywordText(
        settings.closeWord,
      );

      // Проверка на CloseWord
      if (closeWord.isNotEmpty &&
          (mode == PhraseCompletionMode.closeWordOnly ||
              mode == PhraseCompletionMode.hybrid)) {
        if (!_triggeredInCurrentState) {
          final detection = _engine.detectKeyword();
          if (detection != null) {
            final detected = KeywordTokenizer.normalizeKeywordText(
              detection.keyword,
            );
            if (detected == closeWord) {
              _confirm(
                detection,
                isClose: true,
                fire: () {
                  _diagnostics?.event('close_triggered', {'keyword': detected});
                  Log.info('WakeWord', 'CloseWord "$closeWord" detected');
                  _triggeredInCurrentState = true;
                  _lastCompletionAt = DateTime.now();
                  onCloseWordTriggered?.call();
                },
              );
              return;
            }
          }
        }
      }

      // Проверка на тишину (2.0 секунды).
      // ВАЖНО: Согласно правилам tsukiko, таймаут тишины/простоя (2-3 сек)
      // работает ТОЛЬКО если запись была инициирована голосом (startedByVoice).
      // Если запись была начата с клавиатуры или UI, таймаут тишины НЕ должен
      // останавливать диктовку!
      if (_startedByVoice &&
          (mode == PhraseCompletionMode.silenceOnly ||
              mode == PhraseCompletionMode.hybrid ||
              closeWord.isEmpty)) {
        if (_lastSpeechTime != null) {
          final silenceDuration = now.difference(_lastSpeechTime!);
          if (silenceDuration >= silenceThreshold) {
            _diagnostics?.event('silence_timeout');
            Log.info(
              'WakeWord',
              'Silence timeout (${silenceDuration.inMilliseconds}ms >= ${silenceThreshold.inMilliseconds}ms). Stopping dictation.',
            );
            _lastSpeechTime = null;
            _triggeredInCurrentState = true;
            _lastCompletionAt = now;
            onSilenceTimeoutTriggered?.call();
            return;
          }
        }
      }
    }
  }

  /// Run [fire] for a detection once the verifier agrees. The result is
  /// dropped if the recording state changed while whisper was running.
  void _confirm(
    KeywordDetection detection, {
    required bool isClose,
    required void Function() fire,
  }) {
    final audio = detection.samples;
    final v = verifier;
    if (!_verifierReady || v == null || audio == null) {
      if (detection.strict) fire();
      return;
    }
    if (_verifying) return;
    _verifying = true;
    final generation = _operationGeneration;
    final epoch = _stateEpoch;
    final word = isClose
        ? _settings?.closeWord ?? ''
        : _settings?.wakeWord ?? '';
    unawaited(
      v.confirmKeyword(audio, word, isClose: isClose).then((confirmed) {
        _verifying = false;
        if (generation != _operationGeneration ||
            epoch != _stateEpoch ||
            _triggeredInCurrentState ||
            _state == WakeWordListeningState.disabled) {
          return;
        }
        // A broken recognizer must not disable voice activation entirely.
        final accept = confirmed ?? detection.strict;
        _diagnostics?.event('verified', {
          'close': isClose,
          'strict': detection.strict,
          'confirmed': confirmed,
        });
        if (accept) fire();
      }),
    );
  }

  /// Остановить сервис.
  Future<void> stop({bool invalidate = true}) async {
    if (invalidate) _operationGeneration++;
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    _lastAudioFrameAt = null;
    _isSuspendedForSleep = false;
    _consecutiveSilentRestarts = 0;
    _state = WakeWordListeningState.disabled;
    _triggeredInCurrentState = false;
    _wakeSuspended = false;
    _startedByVoice = false;
    _stateEpoch++;
    await _audioRestartDone?.future;
    await stopDiagnostics();
    await _audioSub?.cancel();
    _audioSub = null;
    await _audioSource.stopStream();
    _engine.dispose();
    verifier?.release();
  }

  /// Полное освобождение памяти и процессов.
  Future<void> dispose() async {
    _operationGeneration++;
    await stop();
    await _audioSource.dispose();
    _engine.dispose();
  }
}
