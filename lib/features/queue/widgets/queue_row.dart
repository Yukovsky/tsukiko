import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../core/whisper.dart';
import '../../../design/design.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../job.dart';
import '../../../core/labels.dart';

/// Строка очереди и значок её состояния.
class QueueRow extends StatefulWidget {
  const QueueRow({
    super.key,
    required this.job,
    required this.selected,
    required this.lead,
    required this.customised,
    required this.onTap,
  });
  final Job job;
  final bool selected, lead, customised;
  final VoidCallback onTap;

  @override
  State<QueueRow> createState() => QueueRowState();
}

class QueueRowState extends State<QueueRow> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final accent = MacosTheme.of(context).primaryColor;
    // Выделено несколько — ведущая запись (её показывает инспектор) плотнее.
    final bg = widget.selected
        ? (widget.lead ? accent : accent.withValues(alpha: 0.75))
        : _down
            ? Surface.pressed(context)
            : _hover
                ? Surface.hover(context)
                : MacosColors.transparent;
    final fg = widget.selected ? MacosColors.white : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Подсветка на нажатии, не на отпускании.
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          curve: Curves.easeOut,
          // Между строками очереди — щель, а не отступ: строки читаются
          // одним списком, и разводить их дальше значит рвать его. Хватает
          // ровно того, чтобы две подсветки подряд не слились в пятно.
          margin: const EdgeInsets.only(bottom: Gap.tight),
          padding: const EdgeInsets.all(Gap.inner),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StateGlyph(job: job, tint: fg),
                  const SizedBox(width: Gap.inner),
                  Expanded(
                    child: MacosTooltip(
                      message: job.name,
                      child: Text(
                        job.name,
                        // Диктовка кладёт дату и точное время в имя файла.
                        // В одну строку оно не помещается в узкой очереди,
                        // поэтому раньше от времени оставалось многоточие.
                        // Вторая строка сохраняет число целиком, не раздувая
                        // все строки списка до отдельной карточки.
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: Type.fileName.copyWith(color: fg),
                      ),
                    ),
                  ),
                  // Отметка «у этой записи свои настройки» — иначе о них
                  // узнаёшь только открыв инспектор.
                  if (widget.customised)
                    MacosTooltip(
                      message: AppLocalizations.of(context).tooltipCustomSettings,
                      child: MacosIcon(
                        CupertinoIcons.slider_horizontal_3,
                        size: IconSize.inline,
                        color: fg ?? Surface.secondaryText(context),
                      ),
                    ),
                ],
              ),
              Padding(
                // Подпись встаёт под именем файла, а не под значком:
                // левый край считаем, а не подбираем — значок плюс
                // отступ за ним.
                padding: const EdgeInsets.only(
                    left: IconSize.button + Gap.inner, top: Gap.tight),
                // В строку влезает начало одной строки, и на этом всё.
                // Полный текст ошибки — под курсором; прочитать его
                // целиком и скопировать можно в инспекторе и в меню
                // правого щелчка.
                child: _maybeTooltip(
                  job.error,
                  Text(
                    job.detail ?? job.state.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.caption.copyWith(
                      color: fg?.withValues(alpha: 0.75) ?? Surface.secondaryText(context),
                    ),
                  ),
                ),
              ),
              // Прогресс живёт рядом со своим файлом, а не в общей строке снизу.
              if (job.active)
                Padding(
                  padding: const EdgeInsets.only(
                      left: IconSize.button + Gap.inner,
                      top: Gap.hint,
                      right: Gap.tight),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: Gap.hint,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: (fg ?? accent).withValues(alpha: 0.22),
                            ),
                          ),
                          AnimatedFractionallySizedBox(
                            duration: Motion.dur(context, Motion.settle),
                            curve: Motion.curve(context, Motion.settleCurve),
                            widthFactor: job.progress.clamp(0.02, 1),
                            child: ColoredBox(color: fg ?? accent),
                          ),
                        ],
                      ),
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

/// Подсказка при наведении — только когда есть что подсказать.
Widget _maybeTooltip(String? message, Widget child) =>
    message == null || message.isEmpty
        ? child
        : MacosTooltip(message: message, child: child);

class StateGlyph extends StatelessWidget {
  const StateGlyph({
    super.key,required this.job, this.tint});
  final Job job;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (job.state) {
      JobState.done => (CupertinoIcons.checkmark_circle_fill, MacosColors.systemGreenColor),
      JobState.failed => (
          CupertinoIcons.exclamationmark_circle_fill,
          MacosColors.systemRedColor
        ),
      JobState.cancelled => (CupertinoIcons.minus_circle, Surface.secondaryText(context)),
      JobState.waiting => (CupertinoIcons.clock, MacosColors.systemOrangeColor),
      JobState.paused => (
          CupertinoIcons.pause_circle_fill,
          MacosColors.systemOrangeColor
        ),
      JobState.converting || JobState.transcribing || JobState.diarizing => (
          CupertinoIcons.waveform_circle_fill,
          MacosTheme.of(context).primaryColor
        ),
      JobState.queued => (CupertinoIcons.circle, Surface.secondaryText(context)),
    };
    return AnimatedSwitcher(
      duration: Motion.dur(context, Motion.quick),
      switchInCurve: Motion.curve(context, Motion.quickCurve),
      // Кнопочная ступень, а не строчная: по этому значку читают
      // состояние записи через всю колонку, и он тут главный знак,
      // а не отметка при тексте.
      child: MacosIcon(icon,
          key: ValueKey(icon.codePoint), size: IconSize.button, color: tint ?? color),
    );
  }
}

/// Фрагмент: появляется снизу вверх — оттуда же, откуда его выдаёт модель.
