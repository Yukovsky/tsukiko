import 'dart:async';
import 'dart:math' as math;

import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

enum CatKind { moon, sun, personal }

enum CatMood {
  idle('Покой', 'Просто рядом', blob.idle),
  armed('Ждёт голос', 'Ждёт ключевое слово', blob.idle),
  listening('Слушает', 'Записывает · демо', blob.idle),
  thinking('Думает', 'Распознаёт · демо', blob.thinking),
  happy('Радуется', 'Всё получилось', blob.happy),
  sad('Грустит', 'Нужна помощь', blob.sad),
  surprised('Удивлён', 'О, что это?', blob.surprised),
  sleepy('Сонный', 'Можно отдохнуть', blob.sleepy);

  const CatMood(this.label, this.status, this.expression);
  final String label, status;
  final blob.Expression expression;
}

/// The profile is intentionally separate from temporary expressions and gaze.
class CatProfile {
  CatProfile({
    required this.kind,
    this.seed = 'yuko',
    this.eyeScale = 1,
    this.width = 1,
    this.ears = 1,
    this.form = -1,
    this.avatarColor = true,
  }) : traits = blob.traitsFor(
         kind == CatKind.personal ? seed : 'tsukiko:${kind.name}',
       );

  final CatKind kind;
  final String seed;
  final double eyeScale, width, ears;
  final int form;
  final bool avatarColor;
  final blob.Traits traits;

  String get motionSeed =>
      kind == CatKind.personal ? seed : 'tsukiko:${kind.name}';
  int get resolvedForm => form >= 0
      ? form
      : traits('shape') < .48
      ? 0
      : traits('shape') < .79
      ? 1
      : 2;
  double get headWidth => kind == CatKind.personal
      ? width *
            traits.numIn('body.ratio', .96, 1.04) *
            (resolvedForm == 1 ? .93 : 1)
      : kind == CatKind.moon
      ? .97
      : 1.04;
  double get earHeight => kind == CatKind.personal
      ? ears * traits.numIn('cat.ears', .93, 1.07)
      : kind == CatKind.moon
      ? 1.04
      : .90;
  double get eyes =>
      eyeScale *
      (kind == CatKind.personal ? traits.numIn('eye.rx', .92, 1.08) : 1);
  bool get fluffy => kind == CatKind.personal && resolvedForm == 2;
  late final Color head = switch (kind) {
    CatKind.moon => const Color(0xff7976b9),
    CatKind.sun => const Color(0xffe5a348),
    CatKind.personal =>
      avatarColor
          ? hex(
              blob.palette(
                traits.numIn('hue', 0, 360),
                true,
                .68,
              )[blob.colorHead]!,
            )
          : const Color(0xff7976b9),
  };
  late final Color eyeColor = kind == CatKind.personal && avatarColor
      ? hex(
          blob.palette(traits.numIn('hue', 0, 360), true, .68)[blob.colorEye]!,
        )
      : const Color(0xfffff5db);
  late final Color accent = switch (kind) {
    CatKind.moon => const Color(0xffc3b7fa),
    CatKind.sun => const Color(0xffffca79),
    CatKind.personal => Color.lerp(head, Colors.white, .45)!,
  };

  static Color hex(String value) =>
      Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

/// Native Flutter gaze + upstream Blobatar pose interpolation and idle motion.
class LivingCat extends StatefulWidget {
  const LivingCat({
    super.key,
    required this.profile,
    this.mood = CatMood.idle,
    this.animate = true,
    this.gaze = true,
    this.size = 260,
    this.height,
    this.onPoke,
  });
  final CatProfile profile;
  final CatMood mood;
  final bool animate, gaze;
  final double size;
  final double? height;
  final VoidCallback? onPoke;

  @override
  State<LivingCat> createState() => _LivingCatState();
}

class _LivingCatState extends State<LivingCat>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  final _repaint = ValueNotifier<int>(0);
  late blob.MotionSeeds _seeds = blob.motionSeedsFor(widget.profile.motionSeed);
  late blob.Pose _from = widget.mood.expression.pose;
  late blob.Pose _to = widget.mood.expression.pose;
  double _time = 0, _runBase = 0, _morphStart = -1000, _tracking = 0;
  Offset _target = Offset.zero, _look = Offset.zero;
  bool _hovered = false, _focused = false, _reduced = false;
  Timer? _pokeTimer;
  String? _reaction;

  blob.Pose get _pose => blob.lerpPose(
    _from,
    _to,
    blob.easeInOut(((_time - _morphStart) / 340).clamp(0, 1)),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();

  void _sync() {
    final active =
        widget.animate &&
        !_reduced &&
        TickerMode.valuesOf(context).enabled &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    if (active && !_ticker.isActive) {
      _runBase = _time;
      _ticker.start();
    }
    if (!active && _ticker.isActive) _ticker.stop();
    if (!active) {
      _from = _to;
      _look = Offset.zero;
      _tracking = 0;
      _repaint.value++;
    }
  }

  void _tick(Duration elapsed) {
    final next = _runBase + elapsed.inMicroseconds / 1000;
    final dt = (next - _time).clamp(0.0, 50.0);
    _time = next;
    // Exponential pursuit is independent of refresh rate; never overshoots.
    final desired = widget.gaze && _hovered ? _target : Offset.zero;
    final approach = 1 - math.exp(-dt / 90);
    _look = Offset.lerp(_look, desired, approach)!;
    _tracking += ((widget.gaze && _hovered ? 1 : 0) - _tracking) * approach;
    _repaint.value++;
  }

  void _morph(blob.Pose target) {
    _from = _pose;
    _to = target;
    _morphStart = _time;
    if (!_ticker.isActive) _from = _to;
    _repaint.value++;
  }

  @override
  void didUpdateWidget(covariant LivingCat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.motionSeed != widget.profile.motionSeed) {
      _seeds = blob.motionSeedsFor(widget.profile.motionSeed);
    }
    if (oldWidget.mood != widget.mood) {
      _pokeTimer?.cancel();
      _reaction = null;
      _morph(widget.mood.expression.pose);
    }
    _sync();
  }

  void _poke() {
    widget.onPoke?.call();
    _pokeTimer?.cancel();
    setState(() => _reaction = 'Подмигнул');
    _morph(blob.wink.pose);
    _pokeTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _reaction = null);
      _morph(widget.mood.expression.pose);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pokeTimer?.cancel();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Погладить кота. ${widget.mood.status}${_reaction == null ? '' : '. $_reaction'}',
    button: true,
    onTap: _poke,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _poke();
            return null;
          },
        ),
      },
      child: MouseRegion(
        onEnter: (_) => _hovered = true,
        onExit: (_) {
          _hovered = false;
          _target = Offset.zero;
        },
        onHover: (event) {
          final center = Offset(
            widget.size / 2,
            (widget.height ?? widget.size) / 2,
          );
          final point = (event.localPosition - center) / (widget.size / 2);
          _target = Offset(
            point.dx.clamp(-1, 1) * 3.2,
            point.dy.clamp(-1, 1) * 2.3,
          );
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: _poke,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: _focused ? widget.profile.accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: RepaintBoundary(
              child: SizedBox(
                width: widget.size,
                height: widget.height ?? widget.size,
                child: CustomPaint(
                  painter: CatPainter(
                    profile: widget.profile,
                    mood: widget.mood,
                    repaint: _repaint,
                    frame: () => CatFrame(
                      pose: _pose,
                      motion: blob.motionAt(
                        _seeds,
                        _time,
                        widget.animate && !_reduced ? 1 : 0,
                        shake: _pose.shake,
                      ),
                      gaze: _look,
                      tracking: _tracking,
                      time: widget.animate && !_reduced ? _time : 0,
                    ),
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

class CatFrame {
  const CatFrame({
    required this.pose,
    required this.motion,
    this.gaze = Offset.zero,
    this.tracking = 0,
    this.time = 0,
  });
  final blob.Pose pose;
  final blob.MotionFrame motion;
  final Offset gaze;
  final double tracking;
  final double time;
}

/// Vector study of the existing mascot's silhouette and proportions.
/// Reference used for visual comparison; this is not a cleared replacement asset.
class CatPainter extends CustomPainter {
  CatPainter({
    required this.profile,
    required this.mood,
    required this.frame,
    super.repaint,
  });
  final CatProfile profile;
  final CatMood mood;
  final CatFrame Function() frame;

  Paint fill(Color color) => Paint()..color = color;
  Paint stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame();
    final s = math.min(size.width / 220, size.height / 227);
    canvas.save();
    canvas.translate((size.width - 220 * s) / 2, (size.height - 227 * s) / 2);
    canvas.scale(s);
    canvas.translate(35.2, 27.2);
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: .85),
    );
    canvas.translate(f.motion.shake.$1, f.motion.bob * .35 + f.pose.bdy * .35);
    final color = profile.kind == CatKind.moon
        ? const Color(0xff7775a1)
        : profile.head;
    final dark = Color.lerp(color, const Color(0xff272536), .48)!;

    // Small side-facing body, tucked tail and a dissolving lower edge.
    // This study follows the proportions of the user's existing mascot.
    canvas.saveLayer(null, Paint());
    final body = Path()
      ..moveTo(64, 133)
      ..cubicTo(60, 153, 48, 171, 12, 186)
      ..lineTo(121, 187)
      ..cubicTo(126, 174, 118, 158, 103, 151)
      ..cubicTo(95, 147, 88, 147, 87, 146)
      ..lineTo(91, 145)
      ..quadraticBezierTo(94, 140, 91, 134)
      ..quadraticBezierTo(80, 130, 64, 133)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color, dark],
          stops: const [0, .5, 1],
        ).createShader(const Rect.fromLTWH(10, 130, 120, 60)),
    );
    final tail = Path()
      ..moveTo(88, 148)
      ..cubicTo(69, 143, 61, 158, 68, 171)
      ..cubicTo(72, 179, 82, 185, 96, 187);
    canvas.drawPath(tail, stroke(dark.withValues(alpha: .8), 2));
    canvas.drawRect(
      const Rect.fromLTWH(0, 128, 160, 70),
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, .53, 1],
        ).createShader(const Rect.fromLTWH(0, 128, 160, 59)),
    );
    canvas.restore();

    canvas.save();
    canvas.translate(76, 84);
    canvas.scale(profile.kind == CatKind.moon ? 1 : profile.headWidth, 1);
    canvas.translate(-76, -84);
    final earDrop = f.pose.bdy * .5;
    final ear = profile.kind == CatKind.moon ? 1.0 : profile.earHeight;
    final twitch = mood == CatMood.listening
        ? math.sin(f.time / 230) * .45
        : 0.0;
    final shape = Path()
      ..moveTo(20.4, 85.7)
      ..cubicTo(
        17,
        61,
        44,
        18 / ear + earDrop,
        69.4 + twitch,
        7.5 / ear + earDrop,
      )
      ..cubicTo(76, 2 / ear + earDrop, 75, 29, 76, 52.2)
      ..quadraticBezierTo(82, 51.4, 88.4, 57.1)
      ..cubicTo(
        103,
        42.2,
        128,
        24 / ear + earDrop,
        135.3 - twitch,
        24.5 / ear + earDrop,
      )
      ..cubicTo(143, 24, 140.8, 53, 140, 66.6)
      ..quadraticBezierTo(137, 86, 128, 97)
      ..quadraticBezierTo(149, 104, 141, 111.5)
      ..cubicTo(126, 127, 94, 130, 65, 123)
      ..cubicTo(34, 117, 8, 108, 6, 98)
      ..quadraticBezierTo(2, 91, 20.4, 85.7)
      ..close();
    canvas.drawPath(shape, fill(color));
    canvas.save();
    canvas.clipPath(shape);
    final blush = Paint()
      ..color = const Color(0xffd86fa6).withValues(alpha: .42)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.7);
    canvas.drawOval(const Rect.fromLTWH(10, 89, 36, 17), blush);
    canvas.drawOval(const Rect.fromLTWH(111, 104, 28, 13), blush);
    canvas.restore();

    final gaze =
        f.gaze +
        Offset(f.motion.saccade.$1, f.motion.saccade.$2) * (1 - f.tracking);
    for (var i = 0; i < 2; i++) {
      final pose = f.pose;
      final side = i == 0 ? -1.0 : 1.0;
      final rock = pose.rock * side * f.motion.thinkingPhase * 1.4;
      final x = (i == 0 ? 49.6 : 100.6) + pose.edx * side + gaze.dx;
      final y =
          (i == 0 ? 82.3 : 91.8) + pose.edy + i * pose.edy2 + rock + gaze.dy;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(
        (i == 0 ? .16 : .27) * (1 - pose.lock) +
            (pose.tilt + i * pose.tilt2) * side * math.pi / 180,
      );
      canvas.scale(
        (pose.esx + i * pose.esx2).clamp(.2, 1.5),
        (pose.esy + i * pose.esy2).clamp(.12, 1.4) * f.motion.blink,
      );
      final eye = blob.blobPath(
        0,
        0,
        (i == 0 ? 14 : 12.7) * profile.eyes,
        (i == 0 ? 17.5 : 16.5) * profile.eyes,
        i == 0
            ? const [1.0, .97, 1.02, 1.0, .94, 1.02, .98]
            : const [.97, 1.02, .98, 1.0, 1.02, .96, 1.0],
        0,
      );
      canvas.drawPath(
        _path(eye),
        fill(const Color(0xffdeded6).withValues(alpha: .88)),
      );
      canvas.restore();
    }
    canvas.drawPath(
      Path()
        ..moveTo(71.6, 98.4)
        ..quadraticBezierTo(73, 100, 74.2, 97.8)
        ..quadraticBezierTo(75.2, 100.2, 77, 100.1),
      stroke(const Color(0xffe7dce8).withValues(alpha: .62), .9),
    );
    canvas.restore();
    canvas.restore();
    canvas.restore();
  }

  static Path _path(blob.BlobPath input) {
    final p = Path();
    double currentX = 0, currentY = 0;
    for (final segment in input.segments) {
      switch (segment) {
        case blob.MoveTo(:final x, :final y):
          p.moveTo(x, y);
          currentX = x;
          currentY = y;
        case blob.LineTo(:final x, :final y):
          p.lineTo(x, y);
          currentX = x;
          currentY = y;
        case blob.CubicTo(
          :final c1x,
          :final c1y,
          :final c2x,
          :final c2y,
          :final x,
          :final y,
        ):
          p.cubicTo(c1x, c1y, c2x, c2y, x, y);
          currentX = x;
          currentY = y;
        case blob.QuadTo(:final cx, :final cy, :final x, :final y):
          p.quadraticBezierTo(cx, cy, x, y);
          currentX = x;
          currentY = y;
        case blob.HorizontalLineTo(:final x):
          p.lineTo(x, currentY);
          currentX = x;
        case blob.VerticalLineTo(:final y):
          p.lineTo(currentX, y);
          currentY = y;
        case blob.ClosePath():
          p.close();
      }
    }
    return p;
  }

  @override
  bool shouldRepaint(covariant CatPainter oldDelegate) => true;
}
