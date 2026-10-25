import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import '../../core/indicator_mode.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/app_locale.dart';
import '../../core/app_theme.dart';
import '../../design/theme_fade.dart';
import '../../core/logger.dart';
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';

/// Плавающая панель записи — та, что приходит сама, пока человек диктует.
///
/// Отвечает на единственный вопрос: «система меня слышит и работает?» —
/// и уходит, как только ответила.
///
/// На macOS та же панель написана на SwiftUI и остаётся там: она стоит
/// на системном материале окна (`NSVisualEffectView`, размытие того, что
/// **за** окном) и на неактивирующей `NSPanel`. Ни того, ни другого Flutter
/// не рисует — он размывает лишь то, что нарисовал сам, — а отдельный
/// движок под неё стоит около 110 МБ памяти (замерено) как раз тогда,
/// когда модель занимает полтора гигабайта. Здесь это оправдано: своей
/// панели на Windows не было вовсе.
Future<void> runHud({bool editor = false}) async {
  Log.info(
    'App',
    'runHud started on ${os.platformId} (${Platform.operatingSystemVersion}), Tsukiko $appVersion',
  );
  refreshLocale();
  refreshTheme();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(HudApp(editor: editor));
}

/// Подложка панели записи.
///
/// На macOS панель — прозрачное окно, и скругление со светлой рамкой
/// рисует сам Flutter. На Windows окно непрозрачное: всё, что Flutter
/// оставил за скруглением, выходило чёрными уголками и полосами по бокам.
/// Там углы скругляет и рамку рисует сама система (DWM, см.
/// `HudWindow::Prepare`), а Flutter заливает окно целиком.
BoxDecoration hudDecoration(BuildContext context) => Platform.isWindows
    ? BoxDecoration(color: Surface.chrome(context))
    : BoxDecoration(
        color: Surface.chrome(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Surface.hairline(context)),
      );

class HudApp extends StatelessWidget {
  const HudApp({super.key, this.editor = false});
  final bool editor;

  @override
  Widget build(BuildContext context) => ThemedApp(
    builder: (context) => MacosApp(
      locale: appLocale.value,
      // Тему строит сам MacosApp — см. комментарий в main.dart.
      themeMode: appThemeMode.value,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: editor ? const HudEditorView() : const HudView(),
    ),
  );
}

class HudView extends StatefulWidget {
  const HudView({super.key, this.bridge});

  /// Свой мост нужен только тестам: в приложении он один на изолят.
  final NativeBridge? bridge;

  @override
  State<HudView> createState() => _HudViewState();
}

class _HudViewState extends State<HudView> {
  late final NativeBridge _bridge = widget.bridge ?? NativeBridge();
  StreamSubscription<HudState>? _states;
  Timer? _ticker;
  StreamSubscription<Map<String, dynamic>>? _queue;
  StreamSubscription<Map<String, dynamic>>? _layout;
  bool _editing = false;
  IndicatorMode _mode = IndicatorMode.panel;
  double _scale = 1;
  Offset _drag = Offset.zero;
  bool _dragMoved = false;
  int _pending = 0;
  bool _processing = false;

  HudState _state = HudState.hidden;
  Duration _elapsed = Duration.zero;
  DateTime? _startedAt;

  /// Микрофон уже отдаёт звук. На Windows устройство поднимается от 0,4
  /// до 1 с, и всё это время панель говорит «включаю микрофон», а не
  /// «записываю»: иначе первые слова уходят в пустоту, а человек о том
  /// и не знает. Таймер записи тоже идёт отсюда, а не от нажатия.
  bool _live = true;

  /// До какого момента считать, что человек говорит. Уровень уже
  /// отсчитан от фона комнаты (см. GetAudioLevel): ноль — тишина или
  /// дыхание. Хвост в 0,4 с не даёт микрофону мигать между словами.
  DateTime _voiceUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const _voiceLevel = .15;

  /// История уровня: полоски бегут справа налево, как настоящий сигнал.
  List<double> _levels = List.filled(_bars, 0);
  static const _bars = 22;

  @override
  void initState() {
    super.initState();
    _states = _bridge.hudStates.listen(_onState);
    _queue = _bridge.hudQueue.listen(_onQueue);
    _layout = _bridge.hudLayout.listen(_onLayout);
    _bridge.currentHudLayout().then(_onLayout);
    _bridge.currentHudQueue().then(_onQueue);
    _queryInitialState();
  }

  Future<void> _queryInitialState() async {
    try {
      final state = await _bridge.currentHudState();
      if (state != null && mounted) {
        _onState(state);
      }
    } catch (_) {
      // Игнорируем ошибку опроса начального состояния
    }
  }

  @override
  void dispose() {
    _states?.cancel();
    _queue?.cancel();
    _layout?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _onLayout(Map<String, dynamic> layout) {
    if (!mounted) return;
    setState(() {
      _editing = layout['editing'] == true;
      _mode = IndicatorMode.fromValue(layout['mode']);
      final scale = (layout['scaleValue'] as num?)?.toDouble() ?? 1;
      _scale = scale.isFinite ? scale.clamp(.8, 1.6) : 1;
    });
  }

  Widget _draggable(Widget child) => MouseRegion(
    cursor: SystemMouseCursors.move,
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer()
                ..gestureSettings = const DeviceGestureSettings(touchSlop: 4),
              (recognizer) => recognizer
                ..onStart = (_) {
                  _drag = Offset.zero;
                  _dragMoved = false;
                }
                ..onUpdate = (event) {
                  if (event.delta == Offset.zero) return;
                  _dragMoved = true;
                  _drag += event.delta;
                  _bridge.changeHudLayout({
                    'dx': _drag.dx,
                    'dy': _drag.dy,
                    'end': false,
                  });
                }
                ..onEnd = ((_) => _finishDrag())
                ..onCancel = _finishDrag,
            ),
      },
      child: child,
    ),
  );

  void _finishDrag() {
    if (!_dragMoved) return;
    _dragMoved = false;
    _bridge.changeHudLayout({'dx': _drag.dx, 'dy': _drag.dy, 'end': true});
  }

  void _onQueue(Map<String, dynamic> queue) {
    if (!mounted) return;
    setState(() {
      _pending = (queue['pending'] as num?)?.toInt() ?? 0;
      _processing = queue['processing'] == true;
    });
  }

  void _onState(HudState state) {
    if (state == _state) return;
    if (!mounted) return;
    setState(() {
      _state = state;
      if (state == HudState.recording) {
        _live = false;
        _startedAt = null;
        _elapsed = Duration.zero;
        _levels = List.filled(_bars, 0);
      }
    });
    // Уровень нужен только пока пишут: в остальных состояниях панель
    // ничего не слушает, и опрос был бы работой впустую.
    state == HudState.recording ? _startTicker() : _stopTicker();
  }

  /// Тридцать раз в секунду — столько же, сколько на macOS: полоски
  /// должны шевелиться, а не дёргаться.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) async {
      final level = await _bridge.level();
      final live = _live || await _bridge.micLive();
      if (!mounted) return;
      setState(() {
        if (live && !_live) {
          _live = true;
          _startedAt = DateTime.now();
        }
        if (_live) _levels = [..._levels.skip(1), level];
        if (live && level > _voiceLevel) {
          _voiceUntil = DateTime.now().add(const Duration(milliseconds: 400));
        }
        final started = _startedAt;
        if (started != null) _elapsed = DateTime.now().difference(started);
      });
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  String get _time {
    final total = _editing && _state != HudState.recording
        ? 3
        : _elapsed.inSeconds;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  bool get _voice => DateTime.now().isBefore(_voiceUntil);

  bool get _warming => !_editing && _state == HudState.recording && !_live;

  int get _queueCount =>
      _editing ? 2 : hudBacklogCount(_state, _pending, _processing);

  void _action(String action) {
    if (!_editing) _bridge.hudAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width / _scale;
    final height = _mode == IndicatorMode.timer ? 44.0 : 52.0;
    final row = _mode == IndicatorMode.timer
        ? _timerContent(l10n)
        : _content(l10n);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => _editing
          ? handleHudEditorKey(_bridge, event)
          : KeyEventResult.ignored,
      child: SizedBox(
        width: width * _scale,
        height: height * _scale,
        child: FittedBox(
          child: _draggable(
            Container(
              width: width,
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: hudDecoration(context),
              child: Row(children: row),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _timerContent(AppLocalizations l10n) {
    final state = _editing ? HudState.recording : _state;
    if (state != HudState.recording && state != HudState.transcribing) {
      return _content(l10n);
    }
    final recording = state == HudState.recording;
    // Красный микрофон — только пока слышна речь; тишина и вдох — белый,
    // а пока устройство ещё открывается — серый.
    final mic = _warming
        ? Surface.secondaryText(context)
        : _voice || _editing
        ? MacosColors.systemRedColor
        : (Surface.isDark(context) ? MacosColors.white : MacosColors.black);
    // Слева и справа по одной ширине, чтобы время встало точно по центру.
    const side = (IconSize.button + Gap.inner) * 2;
    return [
      SizedBox(
        width: recording && !_warming ? side : IconSize.button + Gap.inner,
        child: Align(
          alignment: Alignment.centerLeft,
          child: recording
              ? MacosIcon(
                  _warming ? CupertinoIcons.mic : CupertinoIcons.mic_fill,
                  size: 16,
                  color: mic,
                )
              : const ProgressCircle(radius: 7),
        ),
      ),
      Expanded(
        child: Text(
          _warming
              ? l10n.hudMicWarmupShort
              : recording
              ? _time
              : l10n.hudTranscribing,
          style: _label.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          textAlign: recording && !_warming ? TextAlign.center : TextAlign.left,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (recording) ...[
        _IconButton(
          icon: CupertinoIcons.xmark,
          onPressed: () => _action('cancel'),
        ),
        _IconButton(
          icon: CupertinoIcons.stop_fill,
          onPressed: () => _action('stop'),
        ),
      ] else
        _IconButton(
          icon: CupertinoIcons.xmark,
          onPressed: () => _action('abort'),
        ),
    ];
  }

  Widget _queueButton(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      minimumSize: const Size(36, 28),
      color: MacosTheme.of(context).primaryColor.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(14),
      onPressed: _editing
          ? null
          : () => _bridge.showHudQueueMenu({
              'record': l10n.hudRecordNext,
              'abort': l10n.hudAbortCurrent,
              'clearQueue': l10n.hudClearQueue,
            }),
      child: Semantics(
        label: l10n.hudQueueCount(_queueCount),
        button: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MacosIcon(CupertinoIcons.list_bullet, size: 12),
            const SizedBox(width: 4),
            Text(
              _queueCount > 99 ? '99+' : '$_queueCount',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _content(AppLocalizations l10n) =>
      switch (_editing ? HudState.recording : _state) {
        HudState.transcribing => [
          const SizedBox(
            width: 24,
            height: 28,
            child: Center(child: ProgressCircle(radius: 7)),
          ),
          const SizedBox(width: Gap.control),
          Text(l10n.hudTranscribing, style: _label, maxLines: 1),
          if (_queueCount > 0) _queueButton(l10n),
          const Spacer(),
          // Часовая запись считается минутами, и выйти из этого иначе
          // нельзя ничем. Крестик — то же, чем отменяют загрузку.
          _IconButton(
            icon: CupertinoIcons.xmark,
            onPressed: () => _action('abort'),
          ),
        ],
        HudState.cancelled => _message(
          CupertinoIcons.xmark_circle_fill,
          Surface.secondaryText(context),
          l10n.hudCancelled,
        ),
        HudState.done => _message(
          CupertinoIcons.checkmark_circle_fill,
          MacosColors.systemGreenColor,
          l10n.hudDone,
        ),
        HudState.failed => _message(
          CupertinoIcons.exclamationmark_triangle_fill,
          MacosColors.systemOrangeColor,
          l10n.hudFailed,
        ),
        HudState.copied => _message(
          CupertinoIcons.doc_on_clipboard,
          MacosColors.systemOrangeColor,
          l10n.hudCopied,
        ),
        HudState.silent => _message(
          CupertinoIcons.mic_slash,
          Surface.secondaryText(context),
          l10n.hudSilent,
        ),
        // Размеры и шаги — как у SwiftUI-панели на macOS (RecordingHUD.swift:
        // HStack(spacing: 9), метр 100×26). Прежде метр стоял во Flexible
        // со сжатием, а справа — Spacer: свободное место делилось между
        // ними пополам, и полоски ужимались почти вдвое против macOS.
        _ => [
          if (_warming) ...[
            MacosIcon(
              CupertinoIcons.mic,
              size: IconSize.button,
              color: Surface.secondaryText(context),
            ),
            const SizedBox(width: Gap.control),
            Flexible(
              child: Text(
                l10n.hudMicWarmup,
                style: _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else ...[
            _Meter(
              levels: _editing && _state != HudState.recording
                  ? List.generate(22, (i) => ((i * 7) % 13 + 2) / 16)
                  : _levels,
            ),
            const SizedBox(width: _hudSpacing),
            Text(
              _time,
              style: _label.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (_queueCount > 0) _queueButton(l10n),
          const Spacer(),
          _HudButton(
            title: l10n.hudCancel,
            filled: false,
            onPressed: () => _action('cancel'),
          ),
          const SizedBox(width: _hudSpacing),
          _HudButton(
            title: l10n.hudStop,
            filled: true,
            onPressed: () => _action('stop'),
          ),
        ],
      };

  List<Widget> _message(IconData icon, Color color, String text) => [
    MacosIcon(icon, size: IconSize.button, color: color),
    const SizedBox(width: Gap.control),
    Expanded(
      child: Text(
        text,
        style: _label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  ];
}

KeyEventResult handleHudEditorKey(NativeBridge bridge, KeyEvent event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    bridge.changeHudLayout({'save': false});
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.enter) {
    bridge.changeHudLayout({'save': true});
    return KeyEventResult.handled;
  }
  final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
  final delta = switch (event.logicalKey) {
    LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
    LogicalKeyboardKey.arrowRight => Offset(step, 0),
    LogicalKeyboardKey.arrowUp => Offset(0, -step),
    LogicalKeyboardKey.arrowDown => Offset(0, step),
    _ => null,
  };
  if (delta == null) return KeyEventResult.ignored;
  bridge.changeHudLayout({'nudgeX': delta.dx, 'nudgeY': delta.dy});
  return KeyEventResult.handled;
}

class HudEditorView extends StatefulWidget {
  const HudEditorView({super.key, this.bridge});
  final NativeBridge? bridge;
  @override
  State<HudEditorView> createState() => _HudEditorViewState();
}

class _HudEditorViewState extends State<HudEditorView> {
  late final NativeBridge _bridge = widget.bridge ?? NativeBridge();
  StreamSubscription<Map<String, dynamic>>? _layout;
  IndicatorMode _mode = IndicatorMode.panel;
  double _scale = 1;
  @override
  void initState() {
    super.initState();
    _layout = _bridge.hudLayout.listen(_update);
    _bridge.currentHudLayout().then(_update);
  }

  void _update(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      _mode = IndicatorMode.fromValue(data['mode']);
      final value = (data['scaleValue'] as num?)?.toDouble() ?? 1;
      _scale = value.isFinite ? value.clamp(.8, 1.6) : 1;
    });
  }

  @override
  void dispose() {
    _layout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = switch (_mode) {
      IndicatorMode.panel => l10n.indicatorPanel,
      IndicatorMode.status => l10n.indicatorStatus,
      IndicatorMode.timer => l10n.indicatorTimer,
      IndicatorMode.off => l10n.indicatorOff,
    };
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => handleHudEditorKey(_bridge, event),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: hudDecoration(context),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.indicatorTitle,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${_mode.index + 1} / 4',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            Row(
              children: [
                _styleArrow(
                  CupertinoIcons.chevron_left,
                  l10n.indicatorPrevious,
                  -1,
                ),
                Expanded(
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                _styleArrow(
                  CupertinoIcons.chevron_right,
                  l10n.indicatorNext,
                  1,
                ),
              ],
            ),
            if (_mode == IndicatorMode.panel || _mode == IndicatorMode.timer)
              Row(
                children: [
                  Text(l10n.hudScale, style: const TextStyle(fontSize: 11)),
                  Expanded(
                    child: CupertinoSlider(
                      value: _scale,
                      min: .8,
                      max: 1.6,
                      divisions: 8,
                      onChanged: (value) =>
                          _bridge.changeHudLayout({'scaleValue': value}),
                    ),
                  ),
                  Text(
                    '${(_scale * 100).round()}%',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              )
            else
              Text(
                _mode == IndicatorMode.status
                    ? l10n.indicatorStatusHint
                    : l10n.indicatorOffHint,
                style: const TextStyle(fontSize: 11),
              ),
            Text(
              _mode == IndicatorMode.panel || _mode == IndicatorMode.timer
                  ? '${l10n.indicatorPreview} · ${l10n.hudLayoutHint}'
                  : l10n.indicatorEditorHint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10),
            ),
            Row(
              children: [
                _editorButton(l10n.hudReset, _bridge.resetHud),
                const Spacer(),
                _editorButton(
                  l10n.hudCancel,
                  () => _bridge.changeHudLayout({'save': false}),
                ),
                _editorButton(
                  l10n.hudSave,
                  () => _bridge.changeHudLayout({'save': true}),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _styleArrow(IconData icon, String label, int direction) => Semantics(
    label: label,
    button: true,
    child: CupertinoButton(
      minimumSize: const Size(28, 28),
      padding: const EdgeInsets.all(4),
      onPressed: () =>
          _bridge.changeHudLayout({'mode': _mode.cycle(direction).name}),
      child: MacosIcon(icon, size: 14),
    ),
  );
  Widget _editorButton(String label, VoidCallback action) => CupertinoButton(
    minimumSize: const Size(28, 28),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    onPressed: action,
    child: Text(label, style: const TextStyle(fontSize: 11)),
  );
}

/// Подпись на панели: те же 13 пунктов средней насыщенности, что
/// и в SwiftUI-версии.
const _label = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

/// Шаг между элементами панели — тот же, что у HStack(spacing: 9) на macOS.
const _hudSpacing = 9.0;

/// Уровень сигнала полосками. Это не украшение: пока они шевелятся,
/// видно, что микрофон действительно слышит, а не пишет тишину.
class _Meter extends StatelessWidget {
  const _Meter({required this.levels});
  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final color = Surface.isDark(context)
        ? const Color(0x8CFFFFFF)
        : const Color(0x8C000000);
    return SizedBox(
      width: 100,
      height: 26,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final (i, level) in levels.indexed) ...[
            if (i > 0) const SizedBox(width: Gap.tight),
            AnimatedContainer(
              duration: Motion.dur(context, Motion.quick),
              curve: Motion.curve(context, Motion.quickCurve),
              width: 2.5,
              height: (level * 24).clamp(2.5, 24),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1.25),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HudButton extends StatefulWidget {
  const _HudButton({
    required this.title,
    required this.filled,
    required this.onPressed,
  });
  final String title;
  final bool filled;
  final VoidCallback onPressed;

  @override
  State<_HudButton> createState() => _HudButtonState();
}

class _HudButtonState extends State<_HudButton> {
  bool _hover = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final background = widget.filled
        ? (_hover ? accent.withValues(alpha: 0.9) : accent)
        : _pressed
        ? Surface.pressed(context)
        : _hover
        ? Surface.hover(context)
        : Surface.hairline(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        // Отклик на нажатие, а не на отпускании: задержка убивает
        // ощущение прямоты.
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 90),
          child: Container(
            height: 26,
            // Как .padding(.horizontal, 10) у кнопки панели на macOS.
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              widget.title,
              style: const TextStyle(
                fontSize: 12,
              ).copyWith(color: widget.filled ? MacosColors.white : null),
            ),
          ),
        ),
      ),
    );
  }
}

/// Крестик отмены. Не кнопка с подписью: действие редкое, и громкая
/// кнопка рядом с «Распознаю…» читалась бы как основное намерение.
class _IconButton extends StatefulWidget {
  const _IconButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onPressed,
      child: Container(
        // Кружок шире значка на [Gap.inner]: полоса низкая, и
        // мимо мелкой цели тут промахиваются чаще всего.
        width: IconSize.button + Gap.inner,
        height: IconSize.button + Gap.inner,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _hover ? Surface.hover(context) : null,
        ),
        child: MacosIcon(
          widget.icon,
          size: IconSize.button,
          color: Surface.secondaryText(
            context,
          ).withValues(alpha: _hover ? 0.9 : 0.4),
        ),
      ),
    ),
  );
}
