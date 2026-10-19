import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/transcript.dart';
import '../../../design/design.dart';
import '../../../design/mascot.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Фрагмент расшифровки и полог, который встречает перетаскиваемый файл.
class SegmentRow extends StatefulWidget {
  const SegmentRow({
    super.key,
    required this.segment,
    required this.showTimestamp,
    required this.onCopied,
    required this.onReplacementUndo,
    this.highlight = '',
  });
  final Segment segment;
  final bool showTimestamp;
  final VoidCallback onCopied;
  final ValueChanged<int> onReplacementUndo;
  final String highlight;

  @override
  State<SegmentRow> createState() => SegmentRowState();
}

class SegmentRowState extends State<SegmentRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: Motion.settle,
  )..forward();
  bool _hover = false, _copied = false;
  Timer? _resetCopied;
  final _replacementTaps = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    _syncReplacementTaps();
  }

  @override
  void didUpdateWidget(covariant SegmentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.segment, widget.segment)) {
      _syncReplacementTaps();
    }
  }

  void _syncReplacementTaps() {
    for (final tap in _replacementTaps) {
      tap.dispose();
    }
    _replacementTaps
      ..clear()
      ..addAll([
        for (var i = 0; i < widget.segment.replacements.length; i++)
          TapGestureRecognizer()..onTap = () => widget.onReplacementUndo(i),
      ]);
  }

  @override
  void dispose() {
    _resetCopied?.cancel();
    for (final tap in _replacementTaps) {
      tap.dispose();
    }
    _enter.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.segment.text));
    setState(() => _copied = true);
    widget.onCopied();
    _resetCopied?.cancel();
    _resetCopied = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// Найденное подсвечивается прямо в тексте — искать глазами по строке,
  /// которую только что нашёл поиск, было бы издевательством.
  TextSpan _spans(BuildContext context) {
    final text = widget.segment.text;
    final needle = widget.highlight;
    final accent = MacosTheme.of(context).primaryColor;
    final spans = <TextSpan>[];

    void addSearchable(String part) {
      if (part.isEmpty) return;
      final q = needle.toLowerCase();
      if (q.isEmpty) {
        spans.add(TextSpan(text: part));
        return;
      }
      final lower = part.toLowerCase();
      var at = 0;
      while (true) {
        final hit = lower.indexOf(q, at);
        if (hit < 0) break;
        if (hit > at) spans.add(TextSpan(text: part.substring(at, hit)));
        spans.add(
          TextSpan(
            text: part.substring(hit, hit + q.length),
            style: TextStyle(backgroundColor: accent.withValues(alpha: 0.28)),
          ),
        );
        at = hit + q.length;
      }
      spans.add(TextSpan(text: part.substring(at)));
    }

    var at = 0;
    for (final (index, replacement) in widget.segment.replacements.indexed) {
      if (replacement.start < at ||
          replacement.end < replacement.start ||
          replacement.end > text.length) {
        continue;
      }
      addSearchable(text.substring(at, replacement.start));
      spans.add(
        TextSpan(
          text: text.substring(replacement.start, replacement.end),
          style: TextStyle(
            backgroundColor: MacosColors.systemYellowColor.withValues(
              alpha: 0.24,
            ),
            decoration: TextDecoration.underline,
            decorationColor: MacosColors.systemYellowColor.withValues(
              alpha: 0.8,
            ),
          ),
          recognizer: _replacementTaps[index],
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      at = replacement.end;
    }
    addSearchable(text.substring(at));
    return TextSpan(style: Type.body, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Motion.curve(context, Motion.settleCurve),
    );
    final slide = Motion.slide(context, 10);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Opacity(
          opacity: curve.value.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, slide * (1 - curve.value)),
            child: child,
          ),
        ),
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.quick),
          curve: Motion.curve(context, Motion.quickCurve),
          margin: const EdgeInsets.only(bottom: Gap.tight),
          padding: const EdgeInsets.all(Gap.inner),
          decoration: BoxDecoration(
            color: _copied
                ? MacosTheme.of(context).primaryColor.withValues(alpha: 0.14)
                : _hover
                ? Surface.hover(context)
                : MacosColors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showTimestamp)
                Padding(
                  // Время — отдельный столбец слева, и до текста от него
                  // ступень «между кнопками»: на восьми точках столбец
                  // прилипал к первому слову и переставал читаться числом.
                  padding: const EdgeInsets.only(
                    right: Gap.control,
                    top: Gap.tight,
                  ),
                  child: Text(
                    fmtTs(widget.segment.from).substring(0, 8),
                    style: Type.timestamp.copyWith(
                      color: Surface.secondaryText(context),
                    ),
                  ),
                ),
              Expanded(child: SelectableText.rich(_spans(context))),
              if (widget.segment.replacements.isNotEmpty)
                SizedBox(
                  width: IconSize.toolbar + Gap.inner,
                  height: IconSize.toolbar + Gap.inner,
                  child: AnimatedOpacity(
                    duration: Motion.dur(context, Motion.quick),
                    opacity: _hover ? 1 : 0,
                    child: MacosTooltip(
                      message: AppLocalizations.of(
                        context,
                      ).tooltipUndoVoiceCommand,
                      child: MacosIconButton(
                        icon: const MacosIcon(
                          CupertinoIcons.arrow_uturn_left,
                          size: IconSize.toolbar,
                        ),
                        onPressed: _hover
                            ? () => widget.onReplacementUndo(
                                widget.segment.replacements.length - 1,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              // Копирование — самостоятельная цель нажатия, а не отметка
              // при тексте: значок кнопочной ступени, и коробка вокруг
              // него шире значка на [Gap.inner], чтобы в неё попадали.
              // Раньше тут стоял значок в тринадцать точек — мельче
              // соседнего времени записи, и найти его глазом было нечем.
              SizedBox(
                width: IconSize.toolbar + Gap.inner,
                height: IconSize.toolbar + Gap.inner,
                child: AnimatedOpacity(
                  duration: Motion.dur(context, Motion.quick),
                  curve: Motion.curve(context, Motion.quickCurve),
                  opacity: _hover || _copied ? 1 : 0,
                  child: MacosIconButton(
                    icon: MacosIcon(
                      _copied
                          ? CupertinoIcons.checkmark_alt
                          : CupertinoIcons.doc_on_doc,
                      size: IconSize.toolbar,
                      color: _copied
                          ? MacosTheme.of(context).primaryColor
                          : null,
                    ),
                    onPressed: _hover || _copied ? _copy : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Полог при перетаскивании: материал приходит с лёгким перелётом —
/// жест уже нёс импульс.
class DropVeil extends StatelessWidget {
  const DropVeil({
    super.key,
    required this.active,
    this.compact = false,
    this.title,
    this.subtitle,
  });
  final bool active;

  /// Узкая колонка очереди: коту в ней не поместиться, и он там не нужен —
  /// подсветки края и подписи хватает, чтобы понять, что файл здесь примут.
  final bool compact;

  /// Заголовок действия (по умолчанию — dropVeilHint).
  final String? title;

  /// Подпись с пояснением форматов или статуса.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final isDark = MacosTheme.brightnessOf(context) == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: Motion.dur(context, Motion.toss),
        curve: Motion.curve(context, Motion.tossCurve),
        opacity: active ? 1 : 0,
        child: AnimatedScale(
          duration: Motion.dur(context, Motion.toss),
          curve: Motion.curve(context, Motion.tossCurve),
          scale: active ? 1 : 0.97,
          child: Container(
            margin: compact
                ? const EdgeInsets.all(Gap.inner)
                // Снизу вчетверо больше, чем с боков: там лежит нижняя
                // полоса окна, и вуаль не должна залезать под неё.
                : const EdgeInsets.fromLTRB(
                    Gap.item,
                    Gap.item,
                    Gap.item,
                    Gap.item * 4,
                  ),
            decoration: BoxDecoration(
              color: isDark
                  ? accent.withValues(alpha: 0.15)
                  : accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accent.withValues(alpha: 0.50),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.12),
                  blurRadius: 24,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? Gap.inner : Gap.section,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (compact) ...[
                          Icon(
                            CupertinoIcons.arrow_down_doc_fill,
                            size: 28,
                            color: accent,
                          ),
                          const SizedBox(height: Gap.inner),
                        ] else ...[
                          // Кот тянется навстречу файлу. Высота 138 совпадает
                          // с MascotPlaceholder, чтобы переход ощущался естественным.
                          const Mascot(
                            mood: Mood.surprised,
                            height: 138,
                            interactive: false,
                          ),
                          const SizedBox(height: Gap.item),
                        ],
                        Text(
                          title ?? l10n.dropVeilHint,
                          textAlign: TextAlign.center,
                          style: (compact ? Type.caption : Type.emptyTitle).copyWith(
                            color: accent,
                            fontWeight: compact ? FontWeight.w600 : null,
                          ),
                        ),
                        if (!compact && subtitle != null) ...[
                          const SizedBox(height: Gap.hint),
                          Text(
                            subtitle!,
                            textAlign: TextAlign.center,
                            style: Type.control.copyWith(
                              color: Surface.secondaryText(context),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
