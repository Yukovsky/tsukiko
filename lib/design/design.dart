import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';
import 'package:macos_ui/macos_ui.dart';

import '../core/app_locale.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/recognition.dart';
import '../l10n/gen/app_localizations.dart';
import '../platform/os.dart';

/// Пружины и типографика по формулировкам Apple: не «длительность и кривая»,
/// а «отклик» (за сколько дойти) и «затухание» (насколько перелетит).

class SpringCurve extends Curve {
  SpringCurve({
    required this.duration,
    double response = 0.4,
    double dampingRatio = 1.0,
  }) : _sim = SpringSimulation(
         SpringDescription.withDampingRatio(
           mass: 1,
           stiffness: math.pow(2 * math.pi / response, 2).toDouble(),
           ratio: dampingRatio,
         ),
         0,
         1,
         0,
       );

  final Duration duration;
  final SpringSimulation _sim;

  @override
  double transformInternal(double t) {
    if (t >= 1) return 1;
    return _sim.x(t * duration.inMicroseconds / Duration.microsecondsPerSecond);
  }
}

class Motion {
  /// Перемещение и раскрытие: критическое затухание, без перелёта.
  static const settle = Duration(milliseconds: 380);
  static final settleCurve = SpringCurve(duration: settle, response: 0.4);

  /// Быстрый отклик на наведение и нажатие.
  static const quick = Duration(milliseconds: 220);
  static final quickCurve = SpringCurve(duration: quick, response: 0.25);

  /// Перелёт разрешён только там, где жесту предшествовал импульс —
  /// перетаскивание файла в окно.
  static const toss = Duration(milliseconds: 340);
  static final tossCurve = SpringCurve(
    duration: toss,
    response: 0.3,
    dampingRatio: 0.72,
  );

  /// Нажатие подсвечивается мгновенно — задержка убивает ощущение прямоты.
  static const press = Duration(milliseconds: 90);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// При «уменьшить движение» остаётся мягкое затухание, а не пустота.
  static Duration dur(BuildContext context, Duration d) =>
      reduced(context) ? const Duration(milliseconds: 150) : d;

  static Curve curve(BuildContext context, Curve c) =>
      reduced(context) ? Curves.easeOut : c;

  static double slide(BuildContext context, double px) =>
      reduced(context) ? 0 : px;
}

/// Шкала отступов, шаг 4: других значений в приложении нет.
///
/// Смысл шкалы не в числах, а в порядке: пояснение стоит к своей подписи
/// вчетверо ближе, чем следующий блок к концу предыдущего. Пока это
/// соотношение держится, глаз сам собирает настройку и её пояснение в одно.
///
/// Ступеней намеренно мало. Каждая новая ступень — это ещё одно значение,
/// между которым и соседним придётся выбирать, а выбирать между 10 и 12
/// не по чему: разницы не видно, и она уходит в случайность. Поэтому
/// нынешние значения не переносились одно к одному, а округлялись к
/// ближайшей ступени: 5 и 6 стали [hint], 7 и 9 — [inner], 10 и 11 —
/// [control], 14 и 18 — [item] и [edge], 22 и 28 — [section].
class Gap {
  /// Строки одного списка: щель, а не расстояние. Нужна затем, чтобы
  /// подсветка соседних строк не слипалась в одно пятно, — и ни за чем
  /// больше. Единственная ступень мельче шага 4: расстояния тут уже нет,
  /// есть зазор.
  static const tight = 2.0;

  /// Подпись и её пояснение — самое тесное расстояние в приложении.
  static const hint = 4.0;

  /// Внутри одной настройки: подпись над полем, кнопка под путём.
  static const inner = 8.0;

  /// Между соседними кнопками и значками в одном ряду.
  ///
  /// Отдельная ступень от [inner] потому, что у кнопки есть своя рамка и
  /// своя область нажатия: на восьми точках две соседние кнопки читаются
  /// как одна широкая, а их зоны нажатия сходятся вплотную. Двенадцать —
  /// нижняя граница, на которой ряд ещё держится рядом, но уже распадается
  /// на отдельные цели.
  static const control = 12.0;

  /// Между соседними настройками одного раздела.
  static const item = 16.0;

  /// Перед заголовком раздела.
  static const section = 24.0;

  /// Поля слева и справа: в окне настроек одно, в узких панелях другое.
  static const edge = 20.0;
  static const edgeNarrow = 16.0;
}

/// Размеры значков — та же шкала, только для картинок.
///
/// Ступеней ровно четыре, и делит их не число, а работа значка. Значок
/// внутри строки текста, значок-кнопка, значок в панели окна и значок
/// вместо картинки — это четыре разных роли, и внутри роли размер обязан
/// быть один. Раньше их было восемь (10, 12, 13, 14, 15, 20, 40, 56), и
/// разница между 12 и 13 не значила ничего: тот же значок копирования в
/// строке расшифровки был мельче соседнего значка ошибки просто потому,
/// что его писали в другой день.
///
/// Числа не круглые, а привязаны к кеглю: значок рядом с текстом обязан
/// нести тот же оптический вес, что и буквы возле него, — иначе пара
/// читается как сломанная. Отсюда 13 при основном кегле 12.5–13.5.
class IconSize {
  /// Значок при тексте: стрелка раскрытия, папка перед путём, знак беды
  /// перед жалобой. Живёт в потоке строки и меряется по ней — примерно
  /// в один кегль, чтобы не выпирать над строчными и не тонуть под ними.
  /// Сам по себе он ничего не значит: уберите его, и строка останется.
  static const inline = 13.0;

  /// Самостоятельный знак: либо по нему целятся (кнопка), либо он один
  /// несёт смысл строки (состояние записи в очереди, немой микрофон на
  /// панели диктовки). И то и другое обязано быть заметно крупнее
  /// строчного: в мелкую кнопку не попасть, а мелкий знак не найти —
  /// ровно эта беда была у копирования фрагмента расшифровки.
  static const button = 16.0;

  /// Значок в панели инструментов и в шапке окна. Крупнее кнопочного,
  /// потому что стоит один в пустом поле, без текста рядом, и опираться
  /// на соседний кегль ему не на что.
  static const toolbar = 20.0;

  /// Значок вместо картинки: пустой экран, окно вопроса. Уже не знак,
  /// а иллюстрация, и меряется не текстом, а той пустотой, которую он
  /// собой держит.
  static const hero = 56.0;
}

/// Размер, насыщенность и межбуквенное — единым набором.
/// Крупному тексту трекинг отрицательный, мелкому — положительный.
class Type {
  static const navTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const emptyTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.35,
    height: 1.2,
  );

  /// Главное состояние поповера: крупнее всего остального в нём, поэтому
  /// трекинг уходит в минус — на этом кегле буквы иначе стоят слишком врозь.
  static const stateTitle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.4,
    height: 1.15,
  );

  static const sectionHeader = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.65,
  );

  static const body = TextStyle(fontSize: 13.5, height: 1.55, letterSpacing: 0);

  static const control = TextStyle(fontSize: 12.5, letterSpacing: 0.1);

  static const fileName = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
  );

  static const caption = TextStyle(fontSize: 11.5, letterSpacing: 0.2);

  static const timestamp = TextStyle(
    fontSize: 11.5,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Материалы. Крупная поверхность читается плотнее мелкой, светлое
/// полупрозрачное не кладётся на светлое полупрозрачное.
class Surface {
  static bool isDark(BuildContext context) =>
      MacosTheme.of(context).brightness == Brightness.dark;

  static Color chrome(BuildContext context) {
    if (!os.hasWindowMaterial) {
      return isDark(context)
          ? const Color(0xFF202023)
          : const Color(0xFFF7F7F9);
    }
    return isDark(context) ? const Color(0xE6202023) : const Color(0xE6F7F7F9);
  }

  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0x2BFFFFFF) : const Color(0x1A000000);

  static Color hover(BuildContext context) =>
      isDark(context) ? const Color(0x14FFFFFF) : const Color(0x0D000000);

  static Color pressed(BuildContext context) =>
      isDark(context) ? const Color(0x24FFFFFF) : const Color(0x17000000);

  static Color secondaryText(BuildContext context) =>
      isDark(context) ? const Color(0x99FFFFFF) : const Color(0x8C000000);

  /// Фон боковой колонки и поповера там, где системного материала окна
  /// нет вовсе (Windows). На macOS возвращает null — материал должен быть
  /// виден, и закрашивать его нельзя.
  ///
  /// Не «серый вместо чёрного» ради галочки: без этого «Очередь пуста»
  /// читалась на чёрном провале посреди светлого окна.
  static Color? sidebar(BuildContext context) => os.hasWindowMaterial
      ? null
      : (isDark(context) ? const Color(0xFF232326) : const Color(0xFFF1F1F4));

  static BoxDecoration? sidebarDecoration(BuildContext context) {
    final color = sidebar(context);
    return color == null ? null : BoxDecoration(color: color);
  }

  /// Значок в панели инструментов: доступный и недоступный.
  ///
  /// macos_ui красит их одинаково — половинной прозрачностью и на
  /// доступном, и на сером. То есть по виду кнопки нельзя было понять,
  /// нажмётся она или нет: человек жал «Сохранить» на пустой очереди
  /// и ничего не происходило. Недоступное должно быть видно
  /// недоступным.
  static Color toolbarIcon(BuildContext context, {required bool enabled}) {
    final dark = isDark(context);
    if (enabled) {
      return dark ? const Color(0xE6FFFFFF) : const Color(0xD9000000);
    }
    return dark ? const Color(0x40FFFFFF) : const Color(0x40000000);
  }

  /// Цвет подсказки в пустом поле ввода. Умолчание macos_ui —
  /// CupertinoColors.placeholderText, а он разрешается через CupertinoTheme,
  /// которого под MacosApp нет: на тёмной теме получалось тёмное на тёмном.
  static TextStyle placeholder(BuildContext context) =>
      TextStyle(color: secondaryText(context));
}

// ── общие элементы настроек ─────────────────────────────────────────────────
//
// Одни и те же строки стоят в инспекторе главного окна и в окне настроек:
// это разные изоляты, и без общего места они разошлись бы видом.

/// Поле ввода с читаемой подсказкой на обеих темах.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.minLines,
    this.maxLines = 1,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;

  /// Сколько строк поле занимает пустым. Вместе с `maxLines: null` это и
  /// значит «растёт под текст»: поле начинается с трёх строк и дальше
  /// следует за содержимым, а не режет его окошком в три строки с
  /// прокруткой внутри. Подсказку модели пишут длинную — список слов,
  /// имён и терминов, — и прочитать её целиком в таком окошке нельзя.
  final int? minLines;
  final int? maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => MacosTextField(
    controller: controller,
    placeholder: placeholder,
    placeholderStyle: Surface.placeholder(context),
    minLines: minLines,
    maxLines: maxLines,
    onChanged: onChanged,
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    // Снизу вчетверо меньше, чем сверху: заголовок принадлежит тому,
    // что под ним, и обязан стоять к нему ближе, чем к предыдущему
    // разделу. Иначе он читается как подпись к чужому концу.
    padding: const EdgeInsets.only(top: Gap.section, bottom: Gap.inner),
    child: Text(
      text.toUpperCase(),
      style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
    ),
  );
}

/// Пояснение к тому, что стоит НАД ним, и ни к чему больше: снизу отступа
/// нет вовсе, сверху — самый маленький в шкале. Расстояние до следующей
/// настройки задаёт та настройка, и оно всегда больше.
///
/// [under] — пояснение к галке: тогда оно встаёт под её подписью, а не под
/// самой галкой, и колонка текста не рвётся.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.under = false});
  final String text;
  final bool under;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Gap.hint),
    child: Text(
      text,
      style: Type.caption.copyWith(
        color: Surface.secondaryText(context),
        height: 1.4,
      ),
    ),
  );
}

/// Раскрывающийся раздел: заголовок с треугольником, содержимое под ним.
///
/// Нужен там, где раздел важен немногим. Разворачивать его по умолчанию
/// значит отнимать место и внимание у всех ради тех, кому он нужен;
/// прятать совсем — значит не дать его найти вовсе.
class Disclosure extends StatefulWidget {
  const Disclosure({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _open = !_open),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MacosIcon(
              _open
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.chevron_right,
              size: IconSize.inline,
              color: Surface.secondaryText(context),
            ),
            const SizedBox(width: Gap.inner),
            Text(widget.label, style: Type.control),
          ],
        ),
      ),
      if (_open) widget.child,
    ],
  );
}

class Check extends StatefulWidget {
  const Check(this.label, this.value, this.onChanged, {super.key});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<Check> createState() => _CheckState();
}

class _CheckState extends State<Check> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => widget.onChanged(!widget.value),
      child: AnimatedContainer(
        duration: Motion.dur(context, Motion.press),
        curve: Curves.easeOut,
        // Слева поля нет: подсветка начинается ровно там же, где
        // заголовки разделов и пояснения. Иначе у каждой галки свой
        // левый край, и колонка рассыпается.
        padding: const EdgeInsets.fromLTRB(0, Gap.hint, Gap.inner, Gap.hint),
        decoration: BoxDecoration(
          color: _hover ? Surface.hover(context) : MacosColors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MacosCheckbox(value: widget.value, onChanged: widget.onChanged),
            const SizedBox(width: Gap.inner),
            Expanded(child: Text(widget.label, style: Type.control)),
          ],
        ),
      ),
    ),
  );
}

/// Сочетание клавиш плашкой. Одна на всё приложение: в настройках по ней
/// назначают новое сочетание, в поповере она просто показывает нынешнее —
/// и там и там из вида читается, что это значение, а не подпись.
class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key, this.lit = false});
  final String keys;
  final bool lit;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Motion.dur(context, Motion.quick),
    padding: const EdgeInsets.symmetric(
      horizontal: Gap.inner,
      vertical: Gap.tight,
    ),
    decoration: BoxDecoration(
      color: lit ? Surface.pressed(context) : Surface.hover(context),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: Surface.hairline(context)),
    ),
    child: Text(keys, style: Type.control),
  );
}

/// Сочетание клавиш: нажатие на чип включает захват, и следующая
/// комбинация встаёт на его место. Ждём ровно столько же, сколько ждёт
/// сторона macOS, иначе чип завис бы в «нажмите сочетание» навсегда.
class HotkeyRow extends StatefulWidget {
  const HotkeyRow({
    super.key,
    required this.label,
    required this.keys,
    required this.onTap,
    this.onClear,
  });
  final String label, keys;
  final Future<void> Function() onTap;

  /// Снять сочетание совсем. Есть не у всех: без «держать и говорить»
  /// диктовки нет вовсе, а «бросить начатое» можно и не назначать.
  /// null — и когда снимать нечем, и когда снимать нечего.
  final VoidCallback? onClear;

  @override
  State<HotkeyRow> createState() => _HotkeyRowState();
}

class _HotkeyRowState extends State<HotkeyRow> {
  bool _hover = false, _waiting = false;

  Future<void> _tap() async {
    setState(() => _waiting = true);
    await widget.onTap();
    if (mounted) setState(() => _waiting = false);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: _waiting ? null : _tap,
      child: Padding(
        // Строке сочетания дали воздуха: на пяти точках три строки
        // подряд сливались в одну сетку из плашек, и глазу не за что
        // было зацепиться, чтобы отделить одно сочетание от другого.
        padding: const EdgeInsets.symmetric(vertical: Gap.inner),
        child: Row(
          children: [
            Expanded(child: Text(widget.label, style: Type.control)),
            // Крестик слева от клавиши, а не справа. Справа он сдвигал
            // сочетание, и строка с ним переставала стоять в столбик
            // с соседними: правый край у трёх сочетаний обязан быть
            // общим, иначе список читается как сломанный.
            if (widget.onClear case final clear? when !_waiting)
              Padding(
                // Между двумя целями нажатия — [Gap.control]: на
                // восьми точках крестик и плашка читались как одна
                // широкая кнопка.
                padding: const EdgeInsets.only(right: Gap.control),
                child: _ClearButton(onPressed: clear),
              ),
            KeyCap(
              _waiting
                  ? AppLocalizations.of(context).hotkeyCapturePrompt
                  : widget.keys,
              lit: _hover || _waiting,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Крестик «снять сочетание».
///
/// Не синяя кнопка macos_ui: синим в этом окне обозначено выбранное, и
/// синий крестик рядом с серой надписью читался как ещё одно состояние,
/// а не как действие. Здесь тот же знак, каким система чистит поля
/// поиска, — залитый кружок с косым крестом. В покое он приглушён,
/// под курсором проявляется целиком: есть, когда его ищут, и не спорит
/// с сочетанием, пока не нужен.
class _ClearButton extends StatefulWidget {
  const _ClearButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    cursor: SystemMouseCursors.click,
    child: MacosTooltip(
      message: AppLocalizations.of(context).tooltipClearHotkey,
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        // Область нажатия шире самого знака: сам крестик — значок
        // кнопочной ступени, а вокруг него добавлено по [Gap.hint]
        // с каждой стороны, чтобы в него попадали, а не целились.
        child: SizedBox(
          width: IconSize.button + Gap.inner,
          height: IconSize.button + Gap.inner,
          child: Center(
            child: AnimatedOpacity(
              duration: Motion.dur(context, Motion.press),
              opacity: _hover ? 1 : 0.55,
              child: MacosIcon(
                CupertinoIcons.xmark_circle_fill,
                size: IconSize.button,
                color: Surface.secondaryText(context),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Путь как объект, а не как строка настройки: по нему можно щёлкнуть
/// и попасть в саму папку.
class LibraryPath extends StatefulWidget {
  const LibraryPath({
    super.key,
    required this.path,
    required this.onReveal,
    required this.onChange,
    this.hint,
  });
  final String path;
  final VoidCallback onReveal, onChange;

  /// Пояснение к самому пути. Стоит между путём и кнопкой, а не после
  /// кнопки: снаружи оно оказывалось ближе к кнопке, чем кнопка к пути,
  /// и читалось как пояснение к ней.
  final String? hint;

  @override
  State<LibraryPath> createState() => _LibraryPathState();
}

class _LibraryPathState extends State<LibraryPath> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final short = widget.path.replaceFirst(home, '~');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MacosTooltip(
          message: AppLocalizations.of(
            context,
          ).buttonShowInFileManager(os.fileManagerName),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onReveal,
              child: AnimatedContainer(
                duration: Motion.dur(context, Motion.quick),
                curve: Motion.curve(context, Motion.quickCurve),
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.inner,
                  vertical: Gap.inner,
                ),
                decoration: BoxDecoration(
                  color: _hover
                      ? Surface.hover(context)
                      : MacosColors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Surface.hairline(context)),
                ),
                child: Row(
                  children: [
                    MacosIcon(
                      CupertinoIcons.folder,
                      size: IconSize.inline,
                      color: Surface.secondaryText(context),
                    ),
                    const SizedBox(width: Gap.inner),
                    Expanded(
                      child: Text(
                        short,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.control,
                      ),
                    ),
                    AnimatedOpacity(
                      duration: Motion.dur(context, Motion.quick),
                      opacity: _hover ? 1 : 0,
                      child: MacosIcon(
                        CupertinoIcons.arrow_up_right_square,
                        size: IconSize.inline,
                        color: Surface.secondaryText(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.hint != null) Hint(widget.hint!),
        const SizedBox(height: Gap.item),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: widget.onChange,
          child: Text(AppLocalizations.of(context).buttonPickAnotherFolder),
        ),
      ],
    );
  }
}

/// Один список моделей вместо трёх кнопок рядом: сверху то, что уже есть
/// на диске, ниже — то, что приложение умеет достать само, с размером.
/// Выбор ненайденной модели начинает её загрузку.
///
/// Разделитель обязателен: без него «есть» и «можно скачать» сливаются
/// в один список, и выбор молча уходит в сеть на полтора гигабайта.
class ModelField extends StatelessWidget {
  const ModelField({
    super.key,
    required this.installed,
    required this.value,
    required this.onChosen,
    required this.onDownload,
    this.fallback,
    this.downloadEnabled = true,
  });

  final List<String> installed;
  final String value;
  final ValueChanged<String> onChosen;
  final ValueChanged<ModelOffer> onDownload;
  final bool downloadEnabled;

  /// Подпись пустого выбора там, где пустой выбор что-то значит: у диктовки
  /// это «как у расшифровщика». Она же становится первым пунктом списка —
  /// иначе, выбрав модель однажды, вернуться к общей было бы нечем.
  /// Пусто — модель обязана быть выбрана, и пункта нет.
  final String? fallback;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, box) => _popup(context, box.maxWidth));

  Widget _popup(BuildContext context, double width) {
    final offers = modelOffers(installed);
    final f = fallback;
    // Раскрытое меню macos_ui не шире кнопки, а пункт кладёт в Row без
    // ограничения: длинное «Nemotron 3.5 ASR Streaming 0.6b · NeMo-Speech · …»
    // вылезало за меню и обрезалось краем окна. Держим пункт в ширине
    // колонки (за вычетом галочки и полей), хвост уходит в многоточие.
    Widget item(String text, {TextStyle? style}) => ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width.isFinite ? math.max(0, width - 40) : double.infinity,
      ),
      child: Text(
        text,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return MacosPopupButton<String>(
      value: installed.contains(value) ? value : (f == null ? null : ''),
      hint: Text(f ?? AppLocalizations.of(context).modelNotSelected),
      // macos_ui измеряет кнопку по самому широкому пункту меню. Размер
      // загрузки полезен в раскрытом списке, но не должен раздвигать саму
      // кнопку за край окна. В закрытом виде оставляем только имя модели.
      selectedItemBuilder: (_) => [
        if (f != null) Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
        for (final m in installed)
          Text(
            modelLabel(m, installed),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (offers.isNotEmpty && installed.isNotEmpty) const SizedBox(),
        for (final m in offers)
          Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
      items: [
        if (f != null) MacosPopupMenuItem(value: '', child: item(f)),
        for (final m in installed)
          MacosPopupMenuItem(
            value: m,
            // Не просто имя: две «Large v3 Turbo» из разных папок выглядели
            // в списке одинаково, и какая выбрана — понять было нельзя.
            child: item(
              '${modelLabel(m, installed)} · '
              '${engineTechnicalName(engineForModel(m))}',
            ),
          ),
        if (offers.isNotEmpty && installed.isNotEmpty)
          MacosPopupMenuItem(
            enabled: false,
            child: item(
              AppLocalizations.of(context).sectionCanDownload,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
        for (final m in offers)
          MacosPopupMenuItem(
            enabled: downloadEnabled,
            value: m.path,
            child: item(
              '${m.title} · ${engineTechnicalName(m.engine)} · ${m.size}',
            ),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        if (v.isEmpty || installed.contains(v)) return onChosen(v);
        final offer = modelCatalog.firstWhere((m) => m.path == v);
        onDownload(offer);
      },
    );
  }
}

/// Ход загрузки модели. Пока файл едет, кнопок нет: вторая полуторагиговая
/// качка рядом с первой только замедлит обе.
class ModelDownload extends StatelessWidget {
  const ModelDownload({
    super.key,
    required this.title,
    required this.progress,
    required this.percent,
    required this.onCancel,
  });

  /// Значения, а не сам загрузчик: он меняется внутри себя, и виджет,
  /// державший на него ссылку, не замечал бы, что процент сдвинулся.
  final String title, progress;
  final int percent;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        AppLocalizations.of(context).downloadingTitle(title),
        style: Type.control,
      ),
      const SizedBox(height: Gap.inner),
      // Во всю ширину: у ProgressBar из macos_ui задана только
      // минимальная ширина в 85 точек, и в столбце он ровно её
      // и занимал — треть панели, будто загрузка чужая.
      SizedBox(
        width: double.infinity,
        child: ProgressBar(value: percent.toDouble()),
      ),
      const SizedBox(height: Gap.inner),
      Row(
        children: [
          Expanded(
            child: Text(
              progress,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
          PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: onCancel,
            child: Text(AppLocalizations.of(context).buttonCancelDownload),
          ),
        ],
      ),
    ],
  );
}

// ── контекстное меню ────────────────────────────────────────────────────────
//
// В macos_ui меню умеют только кнопки, а по правому щелчку в macOS меню есть
// у всего. Панель берём готовую — MacosOverlayFilter, тот же материал, что
// у выпадающих списков, — своим остаётся только раскладка и попадание в экран.

class MenuAction {
  const MenuAction(this.label, {this.onSelected, this.shortcut});

  /// Разделитель: собственной надписи и действия у него нет.
  const MenuAction.separator() : label = '', onSelected = null, shortcut = null;

  final String label;
  final VoidCallback? onSelected;
  final String? shortcut;

  bool get isSeparator => label.isEmpty;
  bool get enabled => onSelected != null;
}

/// Меню у точки щелчка. Пункты без действия показываются серыми — как в
/// системе, где недоступная команда остаётся на своём месте.
Future<void> showContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<MenuAction> actions,
) {
  if (actions.every((a) => a.isSeparator || !a.enabled)) return Future.value();
  return Navigator.of(context, rootNavigator: true).push(
    _ContextMenuRoute(
      at: globalPosition,
      actions: actions,
      theme: MacosTheme.of(context),
    ),
  );
}

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({
    required this.at,
    required this.actions,
    required this.theme,
  });

  final Offset at;
  final List<MenuAction> actions;
  final MacosThemeData theme;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => currentL10n().barrierLabelCloseMenu;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> a,
    Animation<double> _,
  ) {
    return MacosTheme(
      data: theme,
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(at),
        child: FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          child: _ContextMenuPanel(actions: actions),
        ),
      ),
    );
  }
}

/// Меню открывается вправо-вниз от курсора и разворачивается в другую сторону,
/// если там край экрана.
class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout(this.at);
  final Offset at;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) =>
      BoxConstraints.loose(Size(c.maxWidth - Gap.item, c.maxHeight - Gap.item));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = at.dx + child.width > size.width - Gap.inner
        ? math.max(Gap.inner, at.dx - child.width)
        : at.dx;
    final y = at.dy + child.height > size.height - Gap.inner
        ? math.max(Gap.inner, at.dy - child.height)
        : at.dy;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.at != at;
}

class _ContextMenuPanel extends StatelessWidget {
  const _ContextMenuPanel({required this.actions});
  final List<MenuAction> actions;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
    child: MacosOverlayFilter(
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.all(Gap.hint),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in actions)
              if (a.isSeparator)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: Gap.hint,
                    horizontal: Gap.hint,
                  ),
                  child: Container(height: 1, color: Surface.hairline(context)),
                )
              else
                _ContextMenuRow(action: a),
          ],
        ),
      ),
    ),
  );
}

class _ContextMenuRow extends StatefulWidget {
  const _ContextMenuRow({required this.action});
  final MenuAction action;

  @override
  State<_ContextMenuRow> createState() => _ContextMenuRowState();
}

class _ContextMenuRowState extends State<_ContextMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final accent = MacosTheme.of(context).primaryColor;
    final lit = _hover && a.enabled;
    final fg = !a.enabled
        ? Surface.secondaryText(context).withValues(alpha: 0.5)
        : lit
        ? MacosColors.white
        : null;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: a.enabled
            ? () {
                Navigator.of(context).pop();
                a.onSelected!();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.inner,
            vertical: Gap.hint,
          ),
          decoration: BoxDecoration(
            color: lit ? accent : MacosColors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Text(a.label, style: Type.control.copyWith(color: fg)),
              if (a.shortcut != null) ...[
                // Между надписью пункта и его сочетанием — ширина
                // раздела: сочетание отдельный столбец, а не хвост
                // подписи, и слипаться им нельзя.
                const SizedBox(width: Gap.section),
                const Spacer(),
                Text(
                  a.shortcut!,
                  style: Type.control.copyWith(
                    color: fg ?? Surface.secondaryText(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Правый щелчок (он же двумя пальцами по трекпаду). Собственный обработчик
/// нажатия у ребёнка не трогаем — это разные кнопки мыши.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.actions,
    required this.child,
    this.onOpen,
  });

  /// Пункты меню. Должны только считать: щелчок — это [onOpen].
  final List<MenuAction> Function() actions;

  /// Что сделать до сборки пунктов. Сюда уходит всё, что меняет состояние
  /// (например, выделить строку под курсором), — иначе setState случался бы
  /// посреди построения меню.
  final VoidCallback? onOpen;

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapUp: (d) {
      onOpen?.call();
      showContextMenu(context, d.globalPosition, actions());
    },
    child: child,
  );
}
