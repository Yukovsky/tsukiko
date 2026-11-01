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
  listening(
    'Слушает',
    'Записывает · демо',
    blob.Expression(
      'attentive',
      blob.Pose(esx: 1.02, esy: 1.08, edy: -1.5, edx: -.3),
    ),
  ),
  thinking('Думает', 'Распознаёт · демо', blob.thinking),
  happy('Радуется', 'Всё получилось', blob.happy),
  sad('Грустит', 'Нужна помощь', blob.sad),
  surprised('Удивлён', 'О, что это?', blob.surprised),
  sleepy('Сонный', 'Можно отдохнуть', blob.sleepy);

  const CatMood(this.label, this.status, this.expression);
  final String label, status;
  final blob.Expression expression;
}

/// A small articulated rig, additive to Blobatar's facial expression.
/// Held poses remain distinct even when all continuous motion is disabled.
class CatRig {
  const CatRig({
    this.headTilt = .075,
    this.headX = 0,
    this.headY = 0,
    this.leftEar = 0,
    this.rightEar = 0,
    this.lean = 0,
    this.stretch = 1,
    this.tail = 0,
    this.energy = .25,
    this.smile = 0,
    this.attention = 0,
    this.down = 0,
  });
  final double headTilt,
      headX,
      headY,
      leftEar,
      rightEar,
      lean,
      stretch,
      tail,
      energy,
      smile,
      attention,
      down;

  static CatRig forMood(CatMood mood) => switch (mood) {
    CatMood.idle => const CatRig(),
    CatMood.armed => const CatRig(
      headTilt: -.015,
      headY: -1,
      leftEar: -.10,
      rightEar: .09,
      attention: .45,
      energy: .12,
    ),
    CatMood.listening => const CatRig(
      headTilt: -.13,
      headX: 3.5,
      headY: -5,
      leftEar: -.24,
      rightEar: .20,
      lean: .045,
      stretch: 1.055,
      tail: .65,
      attention: 1,
      energy: .35,
    ),
    CatMood.thinking => const CatRig(
      headTilt: .19,
      headX: -1,
      headY: 1,
      leftEar: .15,
      rightEar: -.09,
      lean: -.025,
      tail: -.25,
      energy: .20,
    ),
    CatMood.happy => const CatRig(
      headTilt: -.035,
      headY: -3,
      leftEar: -.11,
      rightEar: .12,
      stretch: 1.035,
      tail: 1,
      smile: 1,
      energy: 1,
    ),
    CatMood.sad => const CatRig(
      headTilt: .16,
      headY: 5,
      leftEar: -.42,
      rightEar: .43,
      stretch: .96,
      tail: -.75,
      down: 1,
      energy: .06,
    ),
    CatMood.surprised => const CatRig(
      headTilt: -.07,
      headY: -6,
      leftEar: .10,
      rightEar: -.10,
      stretch: 1.06,
      tail: .8,
      energy: .5,
    ),
    CatMood.sleepy => const CatRig(
      headTilt: .20,
      headY: 7,
      leftEar: -.25,
      rightEar: .30,
      stretch: .94,
      tail: -.55,
      down: .7,
      energy: .04,
    ),
  };

  static CatRig lerp(CatRig a, CatRig b, double t) {
    double v(double x, double y) => x + (y - x) * t;
    return CatRig(
      headTilt: v(a.headTilt, b.headTilt),
      headX: v(a.headX, b.headX),
      headY: v(a.headY, b.headY),
      leftEar: v(a.leftEar, b.leftEar),
      rightEar: v(a.rightEar, b.rightEar),
      lean: v(a.lean, b.lean),
      stretch: v(a.stretch, b.stretch),
      tail: v(a.tail, b.tail),
      energy: v(a.energy, b.energy),
      smile: v(a.smile, b.smile),
      attention: v(a.attention, b.attention),
      down: v(a.down, b.down),
    );
  }
}

enum CatView { full, face }

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
    this.view = CatView.full,
    this.voiceLevel = .65,
    this.onPoke,
  });
  final CatProfile profile;
  final CatMood mood;
  final bool animate, gaze;
  final double size;
  final double? height;
  final CatView view;
  final double voiceLevel;
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
  late CatRig _rigFrom = CatRig.forMood(widget.mood);
  late CatRig _rigTo = CatRig.forMood(widget.mood);
  double? _petStart;
  double _time = 0, _runBase = 0, _morphStart = -1000, _tracking = 0;
  Offset _target = Offset.zero, _look = Offset.zero;
  bool _hovered = false, _focused = false, _reduced = false;
  Timer? _pokeTimer;
  String? _reaction;

  double get _progress =>
      blob.easeInOut(((_time - _morphStart) / 420).clamp(0, 1));
  CatRig get _rig => CatRig.lerp(_rigFrom, _rigTo, _progress);
  blob.Pose get _pose => blob.lerpPose(_from, _to, _progress);

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
      _rigFrom = _rigTo;
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
    _rigFrom = _rig;
    _rigTo = CatRig.forMood(widget.mood);
    _from = _pose;
    _to = target;
    _morphStart = _time;
    if (!_ticker.isActive) {
      _from = _to;
      _rigFrom = _rigTo;
    }
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
    _petStart = _time;
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
                    view: widget.view,
                    mood: widget.mood,
                    repaint: _repaint,
                    frame: () => CatFrame(
                      pose: _pose,
                      rig: _rig,
                      pet: _petStart == null || !widget.animate || _reduced
                          ? 0
                          : math.sin(
                              math.pi *
                                  ((_time - _petStart!) / 1200).clamp(0, 1),
                            ),
                      speech: widget.mood == CatMood.listening
                          ? widget.voiceLevel *
                                (widget.animate && !_reduced
                                    ? .35 +
                                          .65 *
                                              math.pow(math.sin(_time / 130), 2)
                                    : .55)
                          : 0,
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
    this.rig,
    this.pet = 0,
    this.speech = 0,
  });
  final blob.Pose pose;
  final blob.MotionFrame motion;
  final Offset gaze;
  final double tracking;
  final double time, pet, speech;
  final CatRig? rig;
}

/// Original layered geometry in Tsukiko's visual language: big pale eyes,
/// unequal tall ears, soft cheek points and a small side-facing body.
class CatPainter extends CustomPainter {
  CatPainter({
    required this.profile,
    required this.mood,
    required this.frame,
    this.view = CatView.full,
    super.repaint,
  });
  final CatProfile profile;
  final CatMood mood;
  final CatFrame Function() frame;
  final CatView view;

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
    final r = f.rig ?? CatRig.forMood(mood);
    final camera = view == CatView.face
        ? const Rect.fromLTWH(0, -18, 200, 167)
        : const Rect.fromLTWH(-10, -12, 220, 245);
    final scale = math.min(
      size.width / camera.width,
      size.height / camera.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - camera.width * scale) / 2,
      (size.height - camera.height * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-camera.left, -camera.top);
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: .91),
    );
    final time = f.time;
    final wave = math.sin(time / 1050);
    final joy = r.smile * math.pow(math.sin(time / 470), 2);
    canvas.translate(f.motion.shake.$1, f.motion.bob * .55 - joy * 1.8);
    final fur = profile.head;
    final shade = Color.lerp(fur, const Color(0xff292736), .32)!;

    if (view == CatView.full) {
      canvas.drawOval(
        const Rect.fromLTWH(39, 193, 112, 18),
        Paint()
          ..shader = RadialGradient(
            colors: [
              profile.accent.withValues(alpha: .10 + f.speech * .06),
              profile.accent.withValues(alpha: 0),
            ],
          ).createShader(const Rect.fromLTWH(37, 182, 116, 35)),
      );
      canvas.save();
      canvas.translate(100, 194);
      canvas.rotate(-r.lean);
      canvas.scale(
        f.motion.breathe.$1,
        f.motion.breathe.$2 * r.stretch - f.pet * .018,
      );
      canvas.translate(-100, -194);
      canvas.saveLayer(null, Paint());
      final swish =
          wave * (1.0 + r.energy * 3) + f.pet * math.sin(time / 110) * 3;
      final lift = r.tail * 11 + f.speech * 1.5;
      final tail = Path()
        ..moveTo(112, 181)
        ..cubicTo(140 + swish, 195, 155 + swish, 181, 146 + swish, 167 - lift)
        ..cubicTo(141, 152 - lift, 127, 153 - lift, 124, 162 - lift)
        ..cubicTo(118, 176 - lift, 137, 174, 127, 184)
        ..close();
      canvas.drawPath(tail, fill(Color.lerp(fur, shade, .16)!));
      final body = Path()
        ..moveTo(87, 132)
        ..cubicTo(83, 151, 69, 173, 43, 190)
        ..cubicTo(66, 202, 113, 206, 135, 193)
        ..cubicTo(146, 185, 139, 166, 121, 153)
        ..quadraticBezierTo(113, 148, 111, 144)
        ..lineTo(114, 140)
        ..quadraticBezierTo(115, 135, 111, 132)
        ..quadraticBezierTo(100, 130, 87, 132)
        ..close();
      canvas.drawPath(
        body,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [fur, fur, shade],
            stops: const [0, .55, 1],
          ).createShader(const Rect.fromLTWH(40, 130, 105, 76)),
      );
      canvas.drawPath(
        Path()
          ..moveTo(115, 150)
          ..cubicTo(94, 145 - lift * .2, 89, 165, 98 + swish * .25, 179)
          ..quadraticBezierTo(106, 192, 121, 194),
        stroke(shade.withValues(alpha: .75), 1.6),
      );
      canvas.drawRect(
        const Rect.fromLTWH(20, 125, 150, 90),
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0, .69, 1],
          ).createShader(const Rect.fromLTWH(20, 125, 150, 81)),
      );
      canvas.restore();
      canvas.restore();
    }

    // Head and ears have their own pivots; pose, gaze and petting compose.
    canvas.save();
    canvas.translate(r.headX + f.gaze.dx * .22, r.headY + f.pet * 1.6);
    canvas.translate(100, 117);
    canvas.rotate(r.headTilt + wave * .009 + f.gaze.dx * .008 - f.pet * .065);
    canvas.scale(profile.headWidth, 1 + r.attention * .015);
    canvas.translate(-100, -117);
    final microEar = math.sin(time / 690) * .012;
    _ear(
      canvas,
      false,
      r.leftEar + microEar - f.speech * .035 + f.pet * .15,
      fur,
    );
    _ear(
      canvas,
      true,
      r.rightEar - microEar + f.speech * .045 - f.pet * .08,
      fur,
    );
    final cheek = profile.fluffy ? 3.0 : 0.0;
    final head = Path()
      ..moveTo(43, 77)
      ..cubicTo(59, 64, 90, 61, 112, 68)
      ..quadraticBezierTo(139, 69, 154, 87)
      ..quadraticBezierTo(161, 92, 165 + cheek, 97)
      ..quadraticBezierTo(173 + cheek, 103, 163, 109)
      ..cubicTo(141, 129, 86, 131, 47, 115)
      ..quadraticBezierTo(28 - cheek, 108, 28 - cheek, 100)
      ..quadraticBezierTo(28, 95, 40, 90)
      ..quadraticBezierTo(41, 82, 43, 77)
      ..close();
    canvas.drawPath(head, fill(fur));
    canvas.save();
    canvas.clipPath(head);
    final blush = Paint()
      ..color = const Color(
        0xffd97baf,
      ).withValues(alpha: .35 + .12 * r.smile + f.pet * .10)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.8);
    canvas.drawOval(const Rect.fromLTWH(33, 99, 34, 15), blush);
    canvas.drawOval(const Rect.fromLTWH(134, 103, 29, 13), blush);
    canvas.restore();

    final gaze =
        f.gaze +
        Offset(f.motion.saccade.$1, f.motion.saccade.$2) * (1 - f.tracking);
    for (var i = 0; i < 2; i++) {
      final p = f.pose;
      final side = i == 0 ? -1.0 : 1.0;
      final phase =
          i * (1 - p.rock) + p.rock * ((1 + side * f.motion.thinkingPhase) / 2);
      final x = (i == 0 ? 72.0 : 124.0) + p.edx * side + gaze.dx;
      final y = (i == 0 ? 92.0 : 96.0) + p.edy + phase * p.edy2 + gaze.dy;
      final rx = (i == 0 ? 12.8 : 12.2) * profile.eyes;
      final ry = (i == 0 ? 17.0 : 16.1) * profile.eyes;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(
        (.10 + i * .05) * (1 - p.lock) +
            (p.tilt + i * p.tilt2) * side * math.pi / 180,
      );
      final eyeFill = fill(profile.eyeColor.withValues(alpha: .92));
      // Keep Blobatar's expression channels; a happy cat also has curved lids.
      canvas.save();
      canvas.scale(
        (p.esx + i * p.esx2).clamp(.2, 1.5),
        (p.esy + i * p.esy2).clamp(.12, 1.4) * f.motion.blink,
      );
      final outline = blob.blobPath(
        0,
        0,
        rx,
        ry,
        i == 0
            ? const [1, .98, 1.02, 1, .96, 1.02, .98]
            : const [.98, 1.02, .97, 1, 1.01, .97, 1],
        0,
      );
      eyeFill.color = eyeFill.color.withValues(alpha: .92 * (1 - r.smile));
      canvas.drawPath(_path(outline), eyeFill);
      canvas.restore();
      if (r.smile > .001) {
        final lid = ((p.esy + i * p.esy2) / math.max(p.esy, .01)).clamp(
          .05,
          1.0,
        );
        final arc = Path()
          ..moveTo(-rx * 1.04, 1.5)
          ..cubicTo(-rx * .5, -8 * lid, rx * .5, -8 * lid, rx * 1.04, 1.5);
        canvas.drawPath(
          arc,
          stroke(profile.eyeColor.withValues(alpha: .92 * r.smile), 4.6),
        );
      }
      canvas.restore();
    }
    final mouthY = 109.0 + r.down * 1.1;
    canvas.drawPath(
      Path()
        ..moveTo(95.3, mouthY)
        ..quadraticBezierTo(97.7, mouthY + 2.0, 99.1, mouthY - .8)
        ..quadraticBezierTo(100.6, mouthY + 2.2, 102.5, mouthY + .6),
      stroke(profile.eyeColor.withValues(alpha: .63), .95),
    );
    canvas.restore();
    canvas.restore();
    canvas.restore();
  }

  void _ear(Canvas canvas, bool right, double rotation, Color fur) {
    final pivot = right ? const Offset(140, 78) : const Offset(60, 76);
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(rotation);
    canvas.scale(1, profile.earHeight);
    canvas.translate(-pivot.dx, -pivot.dy);
    final path = right
        ? (Path()
            ..moveTo(116, 74)
            ..cubicTo(124, 56, 148, 33, 157, 32)
            ..cubicTo(163, 31, 162, 56, 158, 72)
            ..quadraticBezierTo(156, 86, 151, 93)
            ..close())
        : (Path()
            ..moveTo(43, 89)
            ..cubicTo(40, 67, 47, 34, 65, 17)
            ..cubicTo(69, 13, 73, 17, 73, 26)
            ..quadraticBezierTo(74, 44, 78, 68)
            ..quadraticBezierTo(65, 82, 43, 89)
            ..close());
    canvas.drawPath(path, fill(fur));
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
