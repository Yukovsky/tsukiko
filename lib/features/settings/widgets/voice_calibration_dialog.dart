import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/wakeword/adaptive_noise_filter.dart';
import '../../../core/wakeword/audio_stream_source.dart';
import '../../../core/wakeword/personal_keyword_spotter.dart';
import '../../../core/wakeword/speaker_profile.dart';
import '../../../core/wakeword/speech_verifier.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../../platform/bridge.dart';

/// Состояние отдельного шага калибровки.
enum CalibrationPhase {
  idle,
  recording,
  processing,
  stepCompleted,
  allCompleted,
  failed,
}

/// Мастер калибровки голоса пользователя (Voiceprint Enrollment Wizard).
///
/// Цель калибровки: слово активации (wake word) или слово завершения (close word).
enum VoiceCalibrationTarget {
  wake,
  close,
}

/// Мастер калибровки голоса пользователя (Voiceprint Enrollment Wizard).
///
/// Записывает три произношения целевого слова и одно созвучное слово.
/// Сохраняются только акустические признаки; Whisper не решает, верно ли
/// пользователь произнёс нестандартное имя или короткое слово.
class VoiceCalibrationSheet extends StatefulWidget {
  const VoiceCalibrationSheet({
    super.key,
    this.target = VoiceCalibrationTarget.wake,
    required this.wakeWord,
    this.closeWord = '',
    this.bridge,
    this.audioSource,
    this.onProfileCreated,
  });

  final VoiceCalibrationTarget target;
  final String wakeWord;
  final String closeWord;
  final NativeBridge? bridge;
  final AudioStreamSource? audioSource;
  final VoidCallback? onProfileCreated;

  static Future<bool?> showWake(
    BuildContext context, {
    required String wakeWord,
    NativeBridge? bridge,
    AudioStreamSource? audioSource,
    VoidCallback? onProfileCreated,
  }) => showMacosSheet<bool>(
    context: context,
    barrierDismissible: false,
    builder: (sheetContext) => VoiceCalibrationSheet(
      target: VoiceCalibrationTarget.wake,
      wakeWord: wakeWord,
      bridge: bridge,
      audioSource: audioSource,
      onProfileCreated: onProfileCreated,
    ),
  );

  static Future<bool?> showClose(
    BuildContext context, {
    required String closeWord,
    NativeBridge? bridge,
    AudioStreamSource? audioSource,
    VoidCallback? onProfileCreated,
  }) => showMacosSheet<bool>(
    context: context,
    barrierDismissible: false,
    builder: (sheetContext) => VoiceCalibrationSheet(
      target: VoiceCalibrationTarget.close,
      wakeWord: '',
      closeWord: closeWord,
      bridge: bridge,
      audioSource: audioSource,
      onProfileCreated: onProfileCreated,
    ),
  );

  static Future<bool?> show(
    BuildContext context, {
    VoiceCalibrationTarget target = VoiceCalibrationTarget.wake,
    required String wakeWord,
    String closeWord = '',
    NativeBridge? bridge,
    AudioStreamSource? audioSource,
    VoidCallback? onProfileCreated,
  }) => showMacosSheet<bool>(
    context: context,
    barrierDismissible: false,
    builder: (sheetContext) => VoiceCalibrationSheet(
      target: target,
      wakeWord: wakeWord,
      closeWord: closeWord,
      bridge: bridge,
      audioSource: audioSource,
      onProfileCreated: onProfileCreated,
    ),
  );

  @override
  State<VoiceCalibrationSheet> createState() => _VoiceCalibrationSheetState();
}

class _VoiceCalibrationSheetState extends State<VoiceCalibrationSheet>
    with SingleTickerProviderStateMixin {
  late final AudioStreamSource _audioSource;
  final AdaptiveNoiseFilter _noiseFilter = AdaptiveNoiseFilter();

  int _currentStep = 0;
  static const int _totalSteps = 4;
  int get _visibleStep => _currentStep;
  bool get _isNegativeStep => _currentStep == 3;
  bool get _isCloseStep => widget.target == VoiceCalibrationTarget.close;
  String get _targetWord => _isCloseStep ? widget.closeWord : widget.wakeWord;

  CalibrationPhase _phase = CalibrationPhase.idle;
  String? _errorMessage;

  final List<KeywordTemplate> _templates = [];
  final List<KeywordTemplate> _negatives = [];
  final List<KeywordTemplate> _otherTemplates = [];

  /// Как второй этап проверки пишет слово на образцах и как — созвучные
  /// слова. В профиль уходят первые без вторых: если распознаватель и
  /// «Джев», и «Джеп» пишет одинаково, такое написание ничего не отличает.
  final Set<String> _spellings = {};
  final Set<String> _negativeSpellings = {};

  /// Тот же распознаватель, что проверяет срабатывания. Только в
  /// приложении (есть [VoiceCalibrationSheet.bridge]): тесту нечего
  /// загружать.
  SpeechVerifier? _verifier;
  final List<Float32List> _recordedAudioBuffer = [];
  StreamSubscription<Float32List>? _audioSub;

  double _audioLevel = 0.0;
  Timer? _meterPollTimer;
  Timer? _stepTransitionTimer;
  String? _currentRecordingWavPath;

  @override
  void initState() {
    super.initState();
    _audioSource = widget.audioSource ?? MicrophoneAudioStreamSource();
    if (widget.bridge != null) {
      final verifier = _verifier = SpeechVerifier();
      unawaited(verifier.prepare(wakeWord: _targetWord));
    }
    final previous = SpeakerProfile.load();
    if (previous != null) {
      if (_isCloseStep) {
        _otherTemplates.addAll(previous.wakeTemplates);
      } else {
        _otherTemplates.addAll(previous.closeTemplates);
      }
    }
  }

  @override
  void dispose() {
    _meterPollTimer?.cancel();
    _stepTransitionTimer?.cancel();
    _stopRecordingStream();
    _verifier?.release();
    super.dispose();
  }

  Future<void> _stopRecordingStream() async {
    _meterPollTimer?.cancel();
    _meterPollTimer = null;

    if (widget.bridge != null) {
      try {
        await widget.bridge!.stopRecording();
      } catch (_) {}
    } else {
      await _audioSub?.cancel();
      _audioSub = null;
      await _audioSource.stopStream();
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _phase = CalibrationPhase.recording;
      _errorMessage = null;
      _audioLevel = 0.0;
      _recordedAudioBuffer.clear();
      _currentRecordingWavPath = null;
      _noiseFilter.reset();
    });

    final bridge = widget.bridge;
    if (bridge != null) {
      try {
        final path = await bridge.startRecording();
        if (path == null) {
          if (!mounted) return;
          final l10n = AppLocalizations.of(context);
          setState(() {
            _phase = CalibrationPhase.failed;
            _errorMessage = l10n.calibrationMicPermissionError;
          });
          return;
        }
        _currentRecordingWavPath = path;

        // Опрашиваем нативный VU-метр со сглаживанием комнатного фона
        _meterPollTimer?.cancel();
        _meterPollTimer = Timer.periodic(const Duration(milliseconds: 30), (
          _,
        ) async {
          if (!mounted || _phase != CalibrationPhase.recording) return;
          try {
            final lvl = await bridge.level();
            if (mounted && _phase == CalibrationPhase.recording) {
              setState(() {
                _audioLevel = lvl;
              });
            }
          } catch (_) {}
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _phase = CalibrationPhase.failed;
          _errorMessage = '$e';
        });
      }
      return;
    }

    // Fallback через AudioStreamSource
    final hasPerm = await _audioSource.hasPermission();
    if (!hasPerm) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = l10n.calibrationMicPermissionError;
      });
      return;
    }

    try {
      final stream = await _audioSource.startStream(sampleRate: 16000);
      _audioSub = stream.listen(
        _onAudioChunk,
        onError: (Object err) {
          if (!mounted) return;
          setState(() {
            _phase = CalibrationPhase.failed;
            _errorMessage = '$err';
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = '$e';
      });
    }
  }

  void _onAudioChunk(Float32List chunk) {
    if (_phase != CalibrationPhase.recording || chunk.isEmpty) return;

    _recordedAudioBuffer.add(Float32List.fromList(chunk));

    // Адаптивная фильтрация шума комнаты
    final level = _noiseFilter.update(chunk);

    setState(() {
      _audioLevel = level;
    });
  }

  Future<void> _stopRecordingAndProcess() async {
    _meterPollTimer?.cancel();
    _meterPollTimer = null;

    setState(() {
      _phase = CalibrationPhase.processing;
      _audioLevel = 0.0;
    });

    final bridge = widget.bridge;
    String? wavPath;
    if (bridge != null) {
      try {
        wavPath = await bridge.stopRecording() ?? _currentRecordingWavPath;
      } catch (_) {}
    } else {
      await _audioSub?.cancel();
      _audioSub = null;
      await _audioSource.stopStream();
    }

    Float32List raw;
    if (wavPath != null && wavPath.isNotEmpty) {
      raw = SpeechVerifier.readWavSamples(wavPath);
    } else {
      final totalSamples = _recordedAudioBuffer.fold<int>(
        0,
        (sum, list) => sum + list.length,
      );
      raw = Float32List(totalSamples);
      var offset = 0;
      for (final b in _recordedAudioBuffer) {
        raw.setAll(offset, b);
        offset += b.length;
      }
    }
    final template = KeywordTemplate.fromCalibrationAudio(raw);
    if (template == null) {
      if (!mounted) return;
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage =
            'Образец слишком тихий, короткий, длинный или искажённый. '
            '${_isNegativeStep ? 'Произнесите одно созвучное слово' : 'Произнесите только «$_targetWord»'} и повторите запись.';
      });
      return;
    }
    final heard = await _verifier?.recognize(raw, _targetWord);
    if (!mounted) return;
    _handleSuccessfulSample(template, heard);
  }

  /// Написание из образца — если распознаватель услышал одно слово (или
  /// фразу той же длины, что ключевая). Целое предложение на образце —
  /// шум или лишние слова, такое написание ничему не научит.
  String? _spellingOf(String? heard) {
    if (heard == null) return null;
    final key = SpeechVerifier.spellingKey(heard);
    if (key.isEmpty) return null;
    final words = SpeechVerifier.spellingKey(_targetWord).split(' ').length;
    return key.split(' ').length <= words + 1 ? key : null;
  }

  void _handleSuccessfulSample(KeywordTemplate template, [String? heard]) {
    final spelling = _spellingOf(heard);
    if (_isNegativeStep) {
      final nearest = _templates
          .map((sample) => keywordDistance(sample, template))
          .reduce(math.min);
      if (nearest < 0.55) {
        setState(() {
          _phase = CalibrationPhase.failed;
          _errorMessage =
              'Запись слишком похожа на «$_targetWord». '
              'Произнесите другое созвучное слово, которое не должно срабатывать.';
        });
        return;
      }
      _negatives.add(template);
      if (spelling != null) _negativeSpellings.add(spelling);
    } else if (_templates.isNotEmpty &&
        _templates.every((sample) => keywordDistance(sample, template) > 1.12)) {
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage =
            'Запись звучит иначе, чем предыдущие образцы «$_targetWord». '
            'Произнесите только это слово и повторите.';
      });
      return;
    }
    if (!_isNegativeStep &&
        _otherTemplates.any(
          (sample) => keywordDistance(sample, template) < 0.52,
        )) {
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage =
            'Новое слово слишком похоже на другое ключевое слово. '
            'Выберите другое слово или повторите запись.';
      });
      return;
    }
    if (!_isNegativeStep) {
      _templates.add(template);
      if (spelling != null) _spellings.add(spelling);
    }

    if (_currentStep + 1 < _totalSteps) {
      setState(() {
        _phase = CalibrationPhase.stepCompleted;
      });
      // Плавный переход на следующий шаг через полсекунды
      _stepTransitionTimer?.cancel();
      _stepTransitionTimer = Timer(const Duration(milliseconds: 650), () {
        if (!mounted) return;
        setState(() {
          _currentStep++;
          _phase = CalibrationPhase.idle;
          _recordedAudioBuffer.clear();
          _currentRecordingWavPath = null;
        });
      });
    } else {
      _finishAndSaveProfile();
    }
  }

  void _finishAndSaveProfile() {
    final previous = SpeakerProfile.load();
    final spellings = _spellings.difference(_negativeSpellings).toList();
    final SpeakerProfile profile;
    if (_isCloseStep) {
      profile = previous != null
          ? previous.copyWith(
              closeWord: widget.closeWord,
              closeTemplates: _templates,
              closeNegatives: _negatives,
              closeSpellings: spellings,
              createdAt: DateTime.now(),
            )
          : SpeakerProfile(
              name: 'user',
              dimension: 192,
              embeddings: const [],
              wakeWord: '',
              closeWord: widget.closeWord,
              wakeTemplates: const [],
              closeTemplates: _templates,
              wakeNegatives: const [],
              closeNegatives: _negatives,
              closeSpellings: spellings,
              createdAt: DateTime.now(),
            );
    } else {
      profile = previous != null
          ? previous.copyWith(
              wakeWord: widget.wakeWord,
              wakeTemplates: _templates,
              wakeNegatives: _negatives,
              wakeSpellings: spellings,
              createdAt: DateTime.now(),
            )
          : SpeakerProfile(
              name: 'user',
              dimension: 192,
              embeddings: const [],
              wakeWord: widget.wakeWord,
              closeWord: '',
              wakeTemplates: _templates,
              closeTemplates: const [],
              wakeNegatives: _negatives,
              closeNegatives: const [],
              wakeSpellings: spellings,
              createdAt: DateTime.now(),
            );
    }
    if (!profile.save()) {
      setState(() {
        _phase = CalibrationPhase.failed;
        _errorMessage = 'Не удалось сохранить профиль голоса.';
      });
      return;
    }

    widget.onProfileCreated?.call();

    if (!mounted) return;
    setState(() {
      _phase = CalibrationPhase.allCompleted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return MacosSheet(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 480,
          minWidth: 420,
          maxHeight: 520,
        ),
        child: Padding(
          padding: const EdgeInsets.all(Gap.section),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Шапка
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: MacosTheme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: MacosIcon(
                        _phase == CalibrationPhase.allCompleted
                            ? CupertinoIcons.checkmark_seal_fill
                            : CupertinoIcons.waveform,
                        color: MacosTheme.of(context).primaryColor,
                        size: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.item),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isCloseStep
                              ? l10n.calibrationCloseTitle
                              : l10n.calibrationWakeTitle,
                          style: Type.emptyTitle,
                        ),
                        const SizedBox(height: Gap.hint),
                        Text(
                          _isCloseStep
                              ? l10n.calibrationCloseSubtitle
                              : l10n.calibrationWakeSubtitle,
                          style: Type.caption.copyWith(
                            color:
                                MacosTheme.brightnessOf(context) ==
                                    Brightness.dark
                                ? const Color(0xFF9E9E9E)
                                : const Color(0xFF757575),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.section),

              // Индикатор шагов (1, 2, 3)
              if (_phase != CalibrationPhase.allCompleted) ...[
                Row(
                  children: [
                    for (int i = 0; i < _totalSteps; i++) ...[
                      if (i > 0)
                        Expanded(
                          child: Container(
                            height: 2,
                            color: i <= _visibleStep
                                ? MacosTheme.of(context).primaryColor
                                : (MacosTheme.brightnessOf(context) ==
                                          Brightness.dark
                                      ? const Color(0xFF3A3A3C)
                                      : const Color(0xFFE5E5EA)),
                          ),
                        ),
                      AnimatedContainer(
                        duration: Motion.quick,
                        curve: Motion.quickCurve,
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: i < _visibleStep
                              ? MacosTheme.of(context).primaryColor
                              : (i == _visibleStep
                                    ? MacosTheme.of(context).primaryColor
                                    : (MacosTheme.brightnessOf(context) ==
                                              Brightness.dark
                                          ? const Color(0xFF2C2C2E)
                                          : const Color(0xFFF2F2F7))),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: i <= _visibleStep
                                ? MacosTheme.of(context).primaryColor
                                : (MacosTheme.brightnessOf(context) ==
                                          Brightness.dark
                                      ? const Color(0xFF3A3A3C)
                                      : const Color(0xFFD1D1D6)),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: i < _visibleStep
                              ? const MacosIcon(
                                  CupertinoIcons.checkmark,
                                  size: 12,
                                  color: Color(0xFFFFFFFF),
                                )
                              : Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: i == _visibleStep
                                        ? const Color(0xFFFFFFFF)
                                        : (MacosTheme.brightnessOf(context) ==
                                                  Brightness.dark
                                              ? const Color(0xFF8E8E93)
                                              : const Color(0xFF636366)),
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Gap.item),
              ],

              // Основное содержимое текущего шага
              Expanded(
                child: AnimatedSwitcher(
                  duration: Motion.settle,
                  switchInCurve: Motion.settleCurve,
                  switchOutCurve: Curves.easeOut,
                  child: _phase == CalibrationPhase.allCompleted
                      ? _buildCompletedContent(l10n)
                      : _buildStepContent(l10n),
                ),
              ),

              const SizedBox(height: Gap.section),

              // Кнопки управления внизу
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_phase != CalibrationPhase.allCompleted) ...[
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () {
                        _stopRecordingStream();
                        Navigator.of(context).pop(false);
                      },
                      child: Text(l10n.buttonCancel),
                    ),
                    const SizedBox(width: Gap.control),
                    if (_phase == CalibrationPhase.recording)
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: _stopRecordingAndProcess,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const MacosIcon(
                              CupertinoIcons.stop_fill,
                              size: 14,
                              color: Color(0xFFFFFFFF),
                            ),
                            const SizedBox(width: Gap.inner),
                            Text(l10n.calibrationButtonStop),
                          ],
                        ),
                      )
                    else if (_phase == CalibrationPhase.processing)
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: null,
                        child: Text(l10n.calibrationProcessing),
                      )
                    else if (_phase == CalibrationPhase.stepCompleted)
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: null,
                        child: Text(l10n.calibrationSampleAccepted),
                      )
                    else
                      PushButton(
                        controlSize: ControlSize.large,
                        onPressed: _startRecording,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const MacosIcon(
                              CupertinoIcons.mic_fill,
                              size: 14,
                              color: Color(0xFFFFFFFF),
                            ),
                            const SizedBox(width: Gap.inner),
                            Text(l10n.calibrationButtonRecord),
                          ],
                        ),
                      ),
                  ] else ...[
                    PushButton(
                      controlSize: ControlSize.large,
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(l10n.buttonDone),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepContent(AppLocalizations l10n) {
    final title = _isNegativeStep
        ? l10n.calibrationNegativeTitle
        : switch (_currentStep) {
            0 => l10n.calibrationStep1Title,
            1 => l10n.calibrationStep2Title,
            _ => l10n.calibrationStep3Title,
          };

    final prompt = _isNegativeStep
        ? l10n.calibrationNegativePrompt
        : switch (_currentStep) {
            0 => l10n.calibrationStep1Prompt,
            1 => l10n.calibrationStep2Prompt,
            _ => l10n.calibrationStep3Prompt,
          };

    return Container(
      key: ValueKey<int>(_currentStep),
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: MacosTheme.brightnessOf(context) == Brightness.dark
            ? const Color(0xFF1E1E1E)
            : const Color(0xFFF9F9FB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: MacosTheme.brightnessOf(context) == Brightness.dark
              ? const Color(0xFF333333)
              : const Color(0xFFE5E5EA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _isCloseStep ? l10n.fieldCloseWord : l10n.fieldWakeWord,
            style: Type.caption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.hint),
          Text(title, style: Type.navTitle, textAlign: TextAlign.center),
          const SizedBox(height: Gap.inner),
          Text(
            prompt,
            style: Type.body.copyWith(
              color: MacosTheme.brightnessOf(context) == Brightness.dark
                  ? const Color(0xFFB0B0B0)
                  : const Color(0xFF555555),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.item),

          // Фраза активации в плашке
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.item,
                vertical: Gap.inner,
              ),
              decoration: BoxDecoration(
                color: MacosTheme.of(
                  context,
                ).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: MacosTheme.of(
                    context,
                  ).primaryColor.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                _isNegativeStep
                    ? l10n.calibrationNegativeExample(_targetWord)
                    : '«$_targetWord»',
                style: Type.emptyTitle.copyWith(
                  color: MacosTheme.of(context).primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: Gap.item),

          // Индикатор уровня звука и состояния
          Center(child: _buildAudioMeter(l10n)),
        ],
      ),
    );
  }

  Widget _buildAudioMeter(AppLocalizations l10n) {
    if (_phase == CalibrationPhase.recording) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            height: 36,
            child: CustomPaint(
              painter: _AudioWavePainter(
                level: _audioLevel,
                color: MacosTheme.of(context).primaryColor,
              ),
            ),
          ),
          const SizedBox(height: Gap.hint),
          Text(
            l10n.calibrationRecordingInProgress,
            style: Type.caption.copyWith(
              color: MacosTheme.of(context).primaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    if (_phase == CalibrationPhase.processing) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(radius: 12),
          const SizedBox(height: Gap.inner),
          Text(l10n.calibrationProcessing, style: Type.caption),
        ],
      );
    }

    if (_phase == CalibrationPhase.stepCompleted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(
            CupertinoIcons.checkmark_circle_fill,
            color: Color(0xFF34C759),
            size: 20,
          ),
          const SizedBox(width: Gap.inner),
          Text(
            l10n.calibrationSampleAccepted,
            style: Type.control.copyWith(
              color: const Color(0xFF34C759),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    if (_phase == CalibrationPhase.failed && _errorMessage != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MacosIcon(
            CupertinoIcons.exclamationmark_circle_fill,
            color: Color(0xFFFF3B30),
            size: 18,
          ),
          const SizedBox(width: Gap.inner),
          Flexible(
            child: Text(
              _errorMessage!,
              style: Type.caption.copyWith(color: const Color(0xFFFF3B30)),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return Text(
      l10n.calibrationIdlePrompt,
      style: Type.caption.copyWith(
        color: MacosTheme.brightnessOf(context) == Brightness.dark
            ? const Color(0xFF757575)
            : const Color(0xFF9E9E9E),
      ),
    );
  }

  Widget _buildCompletedContent(AppLocalizations l10n) {
    return Container(
      key: const ValueKey<String>('completed'),
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: const Color(0xFF34C759).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF34C759).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const MacosIcon(
            CupertinoIcons.checkmark_circle_fill,
            color: Color(0xFF34C759),
            size: 48,
          ),
          const SizedBox(height: Gap.item),
          Text(
            l10n.calibrationCompletedTitle,
            style: Type.emptyTitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.inner),
          Text(
            l10n.calibrationCompletedBody,
            style: Type.body.copyWith(
              color: MacosTheme.brightnessOf(context) == Brightness.dark
                  ? const Color(0xFFD0D0D0)
                  : const Color(0xFF444444),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Визуализатор звуковых волн микрофона на базе Canvas.
class _AudioWavePainter extends CustomPainter {
  const _AudioWavePainter({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const barCount = 19;
    final barWidth = size.width / (barCount * 2);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.fill;

    final centerY = size.height / 2;

    for (var i = 0; i < barCount; i++) {
      final x = i * (barWidth * 2) + barWidth;
      // Волнообразное распределение вокруг центра
      final distFromCenter = ((i - barCount / 2).abs()) / (barCount / 2);
      final envelope = 1.0 - distFromCenter * 0.6;
      final currentBarLevel = (level * envelope).clamp(0.08, 1.0);
      final barHeight = math.max(4.0, size.height * currentBarLevel * 0.9);

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centerY),
          width: barWidth,
          height: barHeight,
        ),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AudioWavePainter oldDelegate) =>
      oldDelegate.level != level || oldDelegate.color != color;
}
