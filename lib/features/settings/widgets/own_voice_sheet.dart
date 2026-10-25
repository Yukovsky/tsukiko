import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/diarization/own_voice.dart';
import '../../../core/diarization/own_voice_models.dart';
import '../../../core/models.dart' show sizeLabelMb;
import '../../../core/text.dart' show humanDuration;
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../../platform/bridge.dart';

/// Запись образца голоса для «Только мой голос».
///
/// Человек читает вслух короткий текст — секунд двадцать обычной речи.
/// Читать, а не говорить что вздумается, — чтобы не мучиться, что сказать:
/// для отпечатка голоса слова не важны, важно, чтобы речи было достаточно.
class OwnVoiceSheet extends StatefulWidget {
  const OwnVoiceSheet({super.key, required this.bridge});
  final NativeBridge bridge;

  /// Показать лист. true — образец записан и сохранён.
  static Future<bool?> show(BuildContext context, NativeBridge bridge) =>
      showMacosSheet<bool>(
        context: context,
        builder: (_) => OwnVoiceSheet(bridge: bridge),
      );

  @override
  State<OwnVoiceSheet> createState() => _OwnVoiceSheetState();
}

enum _Phase { idle, recording, processing, failed }

class _OwnVoiceSheetState extends State<OwnVoiceSheet> {
  /// Больше полуминуты незачем: отпечаток от этого точнее не станет.
  static const _limit = Duration(seconds: 30);

  /// Меньше — образец почти наверняка выйдет коротким по речи.
  static const _enough = Duration(seconds: 15);

  _Phase _phase = _Phase.idle;
  String? _error, _progress;
  String? _wav;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    if (_phase == _Phase.recording) {
      unawaited(widget.bridge.stopRecording());
    }
    super.dispose();
  }

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _phase = _Phase.recording;
      _error = null;
      _elapsed = Duration.zero;
    });
    final path = await widget.bridge.startRecording();
    if (!mounted) return;
    if (path == null || path.isEmpty) {
      setState(() {
        _phase = _Phase.failed;
        _error = l10n.calibrationMicPermissionError;
      });
      return;
    }
    _wav = path;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final level = await widget.bridge.level();
      if (!mounted || _phase != _Phase.recording) return;
      final elapsed = DateTime.now().difference(_startedAt!);
      setState(() {
        _level = level;
        _elapsed = elapsed;
      });
      if (elapsed >= _limit) unawaited(_stop());
    });
  }

  Future<void> _stop() async {
    if (_phase != _Phase.recording) return;
    _timer?.cancel();
    final l10n = AppLocalizations.of(context);
    setState(() {
      _phase = _Phase.processing;
      _level = 0;
    });
    final wav = await widget.bridge.stopRecording() ?? _wav;
    try {
      if (wav == null) throw StateError('no recording');
      if (!OwnVoiceModels.isInstalled) {
        setState(
          () => _progress = l10n.ownVoiceModelsDownloading(
            sizeLabelMb(OwnVoiceModels.downloadMb),
          ),
        );
        final problem = await OwnVoiceModels.ensureInstalled();
        if (problem != null) throw StateError(problem);
      }
      if (!mounted) return;
      setState(() => _progress = l10n.ownVoiceProcessing);
      final print = await enrollOwnVoice(wav);
      print.save();
      if (mounted) Navigator.of(context).pop(true);
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = '$e'.contains('speech')
            ? l10n.ownVoiceTooShort
            : l10n.ownVoiceFailed(e.message);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = l10n.ownVoiceFailed('$e');
      });
    } finally {
      if (wav != null) {
        try {
          File(wav).deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final recording = _phase == _Phase.recording;
    return MacosSheet(
      child: Padding(
        padding: const EdgeInsets.all(Gap.section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.ownVoiceSheetTitle, style: Type.emptyTitle),
            const SizedBox(height: Gap.item),
            Text(l10n.ownVoiceSheetBody, style: Type.control),
            const SizedBox(height: Gap.item),
            Container(
              padding: const EdgeInsets.all(Gap.item),
              decoration: BoxDecoration(
                color: Surface.hover(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(l10n.ownVoiceReadingText, style: Type.body),
            ),
            const SizedBox(height: Gap.item),
            if (recording) ...[
              Row(
                children: [
                  const MacosIcon(
                    CupertinoIcons.mic_fill,
                    color: MacosColors.systemRedColor,
                  ),
                  const SizedBox(width: Gap.inner),
                  Text(
                    humanDuration(_elapsed.inMilliseconds),
                    style: Type.timestamp,
                  ),
                  const SizedBox(width: Gap.item),
                  Expanded(
                    child: CapacityIndicator(
                      value: (_level * 100).clamp(0, 100),
                    ),
                  ),
                ],
              ),
              Hint(
                _elapsed < _enough
                    ? l10n.ownVoiceKeepReading
                    : l10n.ownVoiceCanStop,
              ),
            ],
            if (_phase == _Phase.processing) ...[
              Row(
                children: [
                  const SizedBox(
                    width: IconSize.button,
                    height: IconSize.button,
                    child: ProgressCircle(),
                  ),
                  const SizedBox(width: Gap.inner),
                  Expanded(child: Text(_progress ?? '', style: Type.control)),
                ],
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: Type.caption.copyWith(
                  color: MacosColors.systemRedColor,
                ),
              ),
            const SizedBox(height: Gap.section),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: _phase == _Phase.processing
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(l10n.buttonCancel),
                ),
                const SizedBox(width: Gap.control),
                PushButton(
                  controlSize: ControlSize.large,
                  onPressed: switch (_phase) {
                    _Phase.idle || _Phase.failed => _start,
                    _Phase.recording => _stop,
                    _Phase.processing => null,
                  },
                  child: Text(
                    recording
                        ? l10n.ownVoiceStop
                        : _phase == _Phase.failed
                        ? l10n.ownVoiceRetry
                        : l10n.ownVoiceStart,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
