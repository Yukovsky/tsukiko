import 'package:flutter/cupertino.dart';

import '../core/cat_look.dart';
import '../l10n/gen/app_localizations.dart';
import 'cat/cat.dart';
import 'design.dart';

/// Настроения лунного кота. Рисует его `cat/cat.dart`: голова собрана
/// из строки внешности ([catLook]), настроения переходят одно в другое
/// плавно.
enum Mood {
  /// Пусто, ждём файлы.
  idle,

  /// Файл в очереди, но распознавание не запущено: кот дремлет.
  waiting,

  /// Идёт распознавание или запись: кот прислушивается.
  listening,

  /// Модель долго думает над фрагментом.
  thinking,

  /// Всё получилось.
  happy,

  /// Файл тащат в окно.
  surprised,

  /// Распознавание не удалось.
  sad,

  /// Ничего не нашлось или ничего не услышал.
  unsure,
}

extension on Mood {
  CatMood get cat => switch (this) {
        Mood.idle => CatMood.idle,
        Mood.waiting => CatMood.sleepy,
        Mood.listening => CatMood.listening,
        Mood.thinking => CatMood.thinking,
        Mood.happy => CatMood.happy,
        Mood.surprised => CatMood.surprised,
        Mood.sad => CatMood.sad,
        Mood.unsure => CatMood.unsure,
      };
}

/// Лунный кот приложения. Дышит, моргает, смотрит на курсор; тычок, щелчок
/// или Enter заставляют подмигнуть.
///
/// Тикер кота сам замирает, когда окно не на переднем плане, когда
/// система просит меньше движения и под выключенным TickerMode.
class Mascot extends StatefulWidget {
  const Mascot({
    super.key,
    required this.mood,
    this.height = 132,
    this.interactive = true,
    this.voiceLevel,
  });

  /// Тесты выключают движение у всех котов разом.
  static bool animate = true;

  final Mood mood;

  /// Высота самого кота; поле под свечение добавляется сверху.
  final double height;

  /// Можно ли тыкать в кота. В заглушке да, в вуали перетаскивания нет.
  final bool interactive;

  /// Уровень голоса 0…1 во время записи: кот шевелит ртом в такт.
  final double? voiceLevel;

  @override
  State<Mascot> createState() => _MascotState();
}

class _MascotState extends State<Mascot> {
  CatProfile? _profile;

  CatProfile _profileFor(String look) =>
      _profile?.text == look ? _profile! : (_profile = CatProfile(look));

  @override
  Widget build(BuildContext context) {
    // Кот рисуется в квадрате: голова занимает его середину, а края
    // остаются свечению и ушам.
    final side = widget.height * 1.25;
    Widget cat = ValueListenableBuilder<String>(
      valueListenable: catLook,
      builder: (context, look, _) => LivingCat(
        profile: _profileFor(look),
        mood: widget.mood.cat,
        size: side,
        animate: Mascot.animate,
        // На маленьком коте размытое свечение не разглядеть, а платить
        // за него приходится каждый кадр.
        glow: widget.height >= 64,
        voiceLevel: widget.voiceLevel ?? .65,
      ),
    );
    if (!widget.interactive) cat = IgnorePointer(child: cat);
    return Semantics(
      label: AppLocalizations.of(context).semanticsMascotLabel,
      excludeSemantics: true,
      child: cat,
    );
  }
}

/// Кот как заглушка пустого экрана: сам зверь, заголовок и подпись.
class MascotPlaceholder extends StatelessWidget {
  const MascotPlaceholder({
    super.key,
    required this.mood,
    required this.title,
    required this.subtitle,
    this.height = 138,
    this.action,
  });

  final Mood mood;
  final String title, subtitle;
  final double height;

  /// Кнопка под подписью: пустой экран, из которого ничего нельзя сделать, —
  /// тупик, а не подсказка.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        // Поле пустого экрана — единственное место, где отступ составной:
        // [Gap.section] от края мало, а следующей ступени в шкале нет и
        // заводить её ради одного экрана не за чем.
        padding: const EdgeInsets.all(Gap.section + Gap.inner),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Mascot(mood: mood, height: height),
            const SizedBox(height: Gap.item),
            Text(title, style: Type.emptyTitle, textAlign: TextAlign.center),
            // Подпись принадлежит заголовку и стоит к нему вчетверо ближе,
            // чем кнопка — к ним обоим: так пустой экран читается как
            // «сообщение и действие», а не как три отдельные строки.
            const SizedBox(height: Gap.hint),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Type.control.copyWith(
                color: Surface.secondaryText(context),
                height: 1.5,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: Gap.section),
              SizedBox(width: 260, child: action),
            ],
          ],
        ),
      );
}

/// Сопоставляет состояние приложения настроению кота.
Mood moodFor({
  required bool dragging,
  required bool running,
  required bool jobActive,
  required bool hasJobs,
  required bool longWait,
  bool failed = false,
}) {
  if (dragging) return Mood.surprised;
  if (failed) return Mood.sad;
  if (running && jobActive) return longWait ? Mood.thinking : Mood.listening;
  if (hasJobs) return Mood.waiting;
  return Mood.idle;
}
