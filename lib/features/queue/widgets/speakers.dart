import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/text.dart' show humanDuration;
import '../../../core/transcript.dart';
import '../../../core/whisper.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Цвета голосов — системные, чтобы в тёмной и светлой теме они
/// оставались различимы так же, как остальные цветные отметки окна.
/// Цвет — не единственный признак: рядом всегда стоит имя, иначе
/// голоса не различить тем, кто не различает цвета.
const _palette = [
  MacosColors.systemBlueColor,
  MacosColors.systemOrangeColor,
  MacosColors.systemGreenColor,
  MacosColors.systemPurpleColor,
  MacosColors.systemPinkColor,
  MacosColors.systemTealColor,
  MacosColors.systemYellowColor,
  MacosColors.systemRedColor,
  MacosColors.systemIndigoColor,
  MacosColors.systemBrownColor,
];

Color speakerColor(int index) => _palette[index % _palette.length];

/// Метка голоса над фрагментом: цветная точка, имя и, если реплика
/// началась поверх чужой, знак ⇄.
class SpeakerLabel extends StatelessWidget {
  const SpeakerLabel({super.key, required this.speaker, this.overlap = false});
  final SpeakerInfo speaker;
  final bool overlap;

  @override
  Widget build(BuildContext context) {
    final color = speakerColor(speaker.colorIndex);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (overlap) ...[
          MacosTooltip(
            message: AppLocalizations.of(context).speakerOverlapTooltip,
            child: Text(
              overlapMark,
              style: Type.caption.copyWith(color: Surface.secondaryText(context)),
            ),
          ),
          const SizedBox(width: Gap.tight),
        ],
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: Gap.tight),
        Flexible(
          child: Text(
            speaker.name,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Раздел инспектора «Несколько голосов»: включить режим, сколько
/// голосов ждать, и — когда у записи голоса уже есть — их список
/// с переименованием и слиянием.
class SpeakersSection extends StatelessWidget {
  const SpeakersSection({
    super.key,
    required this.options,
    required this.transcript,
    required this.modelsMissingLabel,
    required this.onToggle,
    required this.onCount,
    required this.onRename,
    required this.onMerge,
    this.onDiarize,
  });

  final RunOptions options;

  /// Готовая расшифровка ведущей записи — если она есть.
  final Transcript? transcript;

  /// Сколько осталось скачать («46 МБ»), или null — модели на месте.
  final String? modelsMissingLabel;

  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onCount;
  final void Function(String id, String name) onRename;
  final void Function(String from, String into) onMerge;

  /// Определить голоса в готовой расшифровке. null — нельзя (нет
  /// готового текста, очередь занята, это открытый файл без звука).
  final VoidCallback? onDiarize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final voices = transcript?.hasSpeakers ?? false
        ? transcript!.speakers
        : const <SpeakerInfo>[];
    final counts = {0, 2, 3, 4, 5, 6, 8, 10, options.speakerCount}.toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(l10n.sectionSpeakers),
        Check(l10n.checkDiarize, options.diarize, onToggle),
        Hint(l10n.hintDiarize, under: true),
        if (options.diarize) ...[
          const SizedBox(height: Gap.item),
          Text(l10n.labelSpeakerCount, style: Type.control),
          const SizedBox(height: Gap.tight),
          MacosPopupButton<int>(
            value: options.speakerCount,
            items: [
              for (final n in counts)
                MacosPopupMenuItem(
                  value: n,
                  child: Text(n == 0 ? l10n.optionSpeakersAuto : '$n'),
                ),
            ],
            onChanged: (v) => onCount(v ?? 0),
          ),
          Hint(l10n.hintSpeakerCount),
          Hint(
            modelsMissingLabel == null
                ? l10n.speakerModelsReady
                : l10n.speakerModelsMissing(modelsMissingLabel!),
          ),
        ],
        if (voices.isNotEmpty) ...[
          SectionTitle(l10n.panelVoices),
          if (looksFragmented(voices))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.inner),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MacosIcon(
                    CupertinoIcons.exclamationmark_triangle,
                    size: IconSize.toolbar,
                    color: MacosColors.systemOrangeColor,
                  ),
                  const SizedBox(width: Gap.inner),
                  Expanded(
                    child: Text(l10n.warningFragmented, style: Type.caption),
                  ),
                ],
              ),
            ),
          for (final v in voices)
            _VoiceRow(
              voice: v,
              others: voices.where((o) => o.id != v.id).toList(),
              onRename: () => _rename(context, v),
              onMerge: (into) => onMerge(v.id, into),
            ),
          Hint(l10n.hintOverlap),
        ],
        if (onDiarize != null) ...[
          const SizedBox(height: Gap.item),
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: onDiarize,
            child: Text(
              voices.isEmpty ? l10n.buttonDiarizeNow : l10n.buttonDiarizeAgain,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _rename(BuildContext context, SpeakerInfo voice) async {
    final name = await showMacosAlertDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initial: voice.name),
    );
    if (name != null) onRename(voice.id, name);
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.voice,
    required this.others,
    required this.onRename,
    required this.onMerge,
  });

  final SpeakerInfo voice;
  final List<SpeakerInfo> others;
  final VoidCallback onRename;
  final ValueChanged<String> onMerge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.inner),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SpeakerLabel(speaker: voice),
                const SizedBox(height: Gap.hint),
                Text(
                  l10n.speakerStats(
                    humanDuration(voice.talkMs),
                    l10n.turnsLabel(voice.turns),
                  ),
                  style: Type.caption.copyWith(
                    color: Surface.secondaryText(context),
                  ),
                ),
              ],
            ),
          ),
          MacosTooltip(
            message: l10n.buttonRenameSpeaker,
            child: MacosIconButton(
              icon: const MacosIcon(
                CupertinoIcons.pencil,
                size: IconSize.toolbar,
              ),
              onPressed: onRename,
            ),
          ),
          if (others.isNotEmpty)
            MacosTooltip(
              message: l10n.mergeSpeakerTitle(voice.name),
              child: MacosPulldownButton(
                icon: CupertinoIcons.arrow_merge,
                items: [
                  for (final other in others)
                    MacosPulldownMenuItem(
                      title: Text(other.name),
                      onTap: () => onMerge(other.id),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return MacosAlertDialog(
      appIcon: const MacosIcon(CupertinoIcons.person_2, size: IconSize.hero),
      title: Text(l10n.renameSpeakerTitle, style: Type.emptyTitle),
      message: Padding(
        padding: const EdgeInsets.only(top: Gap.inner),
        child: MacosTextField(
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _done(),
        ),
      ),
      primaryButton: PushButton(
        controlSize: ControlSize.large,
        onPressed: _done,
        child: Text(l10n.buttonDone),
      ),
      secondaryButton: PushButton(
        controlSize: ControlSize.large,
        secondary: true,
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.buttonCancel),
      ),
    );
  }
}
