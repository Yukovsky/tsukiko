import 'dart:async';
import 'dart:math' as math;

import 'package:blobatar/blobatar.dart' as blob;
import 'package:blobatar/flutter.dart' as native;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

enum CatKind { moon, sun, personal }

enum CatShape {
  round('Круглый', 'Мягкий и спокойный.', .11),
  square('Мягкий квадрат', 'Собранный, с округлыми углами.', .54),
  drop('Капля', 'Любопытный кот с чубчиком.', .89);

  const CatShape(this.label, this.description, this.trait);
  final String label, description;
  final double trait;
}

enum CatMood {
  idle('Покой', 'Просто рядом', blob.idle),
  listening(
    'Слушает',
    'Записывает · демо',
    blob.Expression('attentive', blob.Pose(esy: 1.08, edy: -1.2)),
  ),
  thinking('Думает', 'Распознаёт · демо', blob.thinking),
  happy('Радуется', 'Всё получилось', blob.happy),
  sad('Грустит', 'Нужна помощь', blob.sad),
  surprised('Удивлён', 'О, что это?', blob.surprised),
  mad('Сердится', 'Сердится', blob.mad),
  wink('Подмигивает', 'Подмигивает', blob.wink),
  sleepy('Сонный', 'Можно отдохнуть', blob.sleepy),
  smug('Доволен собой', 'Доволен собой', blob.smug),
  unsure('Сомневается', 'Не уверен', blob.unsure),
  scared('Испуган', 'Испуган', blob.scared),
  love('Влюблён', 'Влюблён', blob.love),
  shy('Смущён', 'Смущён', blob.shy),
  sick('Приболел', 'Приболел', blob.sick);

  const CatMood(this.label, this.status, this.expression);
  final String label, status;
  final blob.Expression expression;
}

/// A few held feline gestures on top of the unchanged Blobatar expression.
class CatRig {
  const CatRig({
    this.headTilt = 0,
    this.headX = 0,
    this.headY = 0,
    this.leftEar = 0,
    this.rightEar = 0,
    this.attention = 0,
  });
  final double headTilt, headX, headY, leftEar, rightEar, attention;
  static CatRig forMood(CatMood mood) => switch (mood) {
    CatMood.listening => const CatRig(
      headTilt: -.06,
      headY: -2,
      leftEar: -.15,
      rightEar: .15,
      attention: 1,
    ),
    CatMood.thinking => const CatRig(
      headTilt: .08,
      leftEar: .10,
      rightEar: -.07,
    ),
    CatMood.happy ||
    CatMood.love => const CatRig(headY: -1, leftEar: -.08, rightEar: .08),
    CatMood.sad || CatMood.sick => const CatRig(
      headTilt: .05,
      headY: 1.8,
      leftEar: -.32,
      rightEar: .32,
    ),
    CatMood.sleepy => const CatRig(
      headTilt: .06,
      headY: 2,
      leftEar: -.20,
      rightEar: .24,
    ),
    CatMood.surprised ||
    CatMood.scared => const CatRig(headY: -2, leftEar: .10, rightEar: -.10),
    _ => const CatRig(),
  };
  static CatRig lerp(CatRig a, CatRig b, double t) {
    double v(double x, double y) => x + (y - x) * t;
    return CatRig(
      headTilt: v(a.headTilt, b.headTilt),
      headX: v(a.headX, b.headX),
      headY: v(a.headY, b.headY),
      leftEar: v(a.leftEar, b.leftEar),
      rightEar: v(a.rightEar, b.rightEar),
      attention: v(a.attention, b.attention),
    );
  }
}

/// Native Blobatar layout and renderer; only the ears are our geometry.
class CatProfile {
  CatProfile({
    this.kind = CatKind.moon,
    this.seed = 'yuko',
    this.shape = CatShape.round,
  });
  final CatKind kind;
  final String seed;
  final CatShape shape;
  String get motionSeed => seed;
  late final blob.Traits traits = blob.traitsFor(seed);
  late final blob.BlobatarOptions options = blob.BlobatarOptions(
    traits: {'shape': shape.trait, 'body.rot': .5},
    tone: .68,
    palette: switch (kind) {
      CatKind.moon => const {'head': '#66679f', 'eye': '#f7f3e8'},
      CatKind.sun => const {'head': '#e5a64f', 'eye': '#32251b'},
      CatKind.personal => null,
    },
  );
  late final blob.BlobatarLayout layout = blob.layoutFor(seed, options);
  late final native.AnimatedBlobatarRenderer renderer =
      native.AnimatedBlobatarRenderer(name: seed, options: options);
  late final blob.Palette base = renderer.paletteFor(blob.idle);
  Color get head => hex(base[blob.colorHead]!);
  Color get eyeColor => hex(base[blob.colorEye]!);
  Color get accent => Color.lerp(head, Colors.white, .55)!;
  blob.Palette colors(blob.Expression expression) =>
      renderer.paletteFor(expression);
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
    this.voiceLevel = .65,
    this.onPoke,
  });
  final CatProfile profile;
  final CatMood mood;
  final bool animate, gaze;
  final double size;
  final double? height;
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
  late Color _fromHead = widget.profile.head, _toHead = widget.profile.head;
  late Color _fromEye = widget.profile.eyeColor,
      _toEye = widget.profile.eyeColor;
  Color get _head => Color.lerp(_fromHead, _toHead, _progress)!;
  Color get _eye => Color.lerp(_fromEye, _toEye, _progress)!;
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
      _fromHead = _toHead;
      _fromEye = _toEye;
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

  void _morph(blob.Pose target, [blob.Expression? expression]) {
    _fromHead = _head;
    _fromEye = _eye;
    final palette = widget.profile.colors(expression ?? widget.mood.expression);
    _toHead = CatProfile.hex(palette[blob.colorHead]!);
    _toEye = CatProfile.hex(palette[blob.colorEye]!);
    _rigFrom = _rig;
    _rigTo = CatRig.forMood(widget.mood);
    _from = _pose;
    _to = target;
    _morphStart = _time;
    if (!_ticker.isActive) {
      _from = _to;
      _rigFrom = _rigTo;
      _fromHead = _toHead;
      _fromEye = _toEye;
    }
    _repaint.value++;
  }

  @override
  void didUpdateWidget(covariant LivingCat oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.profile.motionSeed != widget.profile.motionSeed ||
        oldWidget.profile.options != widget.profile.options;
    if (identityChanged)
      _seeds = blob.motionSeedsFor(widget.profile.motionSeed);
    if (oldWidget.mood != widget.mood || identityChanged) {
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
    _morph(blob.wink.pose, blob.wink);
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
                      headColor: _head,
                      eyeColor: _eye,
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
    this.headColor,
    this.eyeColor,
  });
  final blob.Pose pose;
  final blob.MotionFrame motion;
  final Offset gaze;
  final double tracking;
  final double time, pet, speech;
  final CatRig? rig;
  final Color? headColor, eyeColor;
}

/// The official renderer draws every native body and eye path unchanged.
/// Ears and nose share its published Canvas transform composition.
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

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame();
    final r = f.rig ?? CatRig.forMood(mood);
    final baseMotion = f.motion;
    final gaze =
        f.gaze +
        Offset(baseMotion.saccade.$1, baseMotion.saccade.$2) * (1 - f.tracking);
    final wrap = baseMotion.wrap;
    final motion = blob.MotionFrame(
      shake: baseMotion.shake,
      breathe: baseMotion.breathe,
      bob: baseMotion.bob,
      saccade: (gaze.dx, gaze.dy),
      thinkingPhase: baseMotion.thinkingPhase,
      blink: baseMotion.blink,
      wrap: blob.MotionWrap(
        magnitudeX: wrap.magnitudeX * (1 - f.tracking),
        side: wrap.side * (1 - f.tracking),
        scaleY: wrap.scaleY * (1 - f.tracking),
        rotation: wrap.rotation * (1 - f.tracking),
      ),
    );
    final colors = f.headColor == null || f.eyeColor == null
        ? profile.colors(mood.expression)
        : null;
    final head = f.headColor ?? CatProfile.hex(colors![blob.colorHead]!);
    final eye = f.eyeColor ?? CatProfile.hex(colors![blob.colorEye]!);
    final body = profile.layout.body;
    final zoom = 34 / body.rx;
    final scale = math.min(size.width / 112, size.height / 118);
    canvas.save();
    canvas.translate(
      (size.width - 112 * scale) / 2,
      (size.height - 118 * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(6, 6);
    canvas.translate(50, 61);
    canvas.rotate(r.headTilt + f.gaze.dx * .006 - f.pet * .05);
    canvas.translate(r.headX * .3, r.headY);
    canvas.scale(zoom);
    canvas.translate(-body.cx, -body.cy);

    void nativeTransform() {
      canvas.translate(motion.shake.$1, motion.shake.$2);
      canvas.translate(50, 50);
      canvas.scale(motion.breathe.$1, motion.breathe.$2);
      canvas.translate(-50, -50);
      canvas.translate(0, f.pose.bdy + motion.bob);
    }

    canvas.save();
    nativeTransform();
    _ear(canvas, body, false, r.leftEar - f.speech * .035 + f.pet * .20, head);
    _ear(canvas, body, true, r.rightEar + f.speech * .035 - f.pet * .10, head);
    canvas.restore();
    profile.renderer.paint(
      canvas,
      const Size(100, 100),
      native.AnimatedBlobatarFrame(
        motion: motion,
        pose: f.pose,
        headColor: head,
        eyeColor: eye,
      ),
    );
    canvas.save();
    nativeTransform();
    final y = body.cy + body.ry * .40;
    final mouth = Path()
      ..moveTo(body.cx - 1.5, y + .4)
      ..quadraticBezierTo(body.cx - .6, y + 1.5, body.cx, y)
      ..quadraticBezierTo(body.cx + .6, y + 1.5, body.cx + 1.5, y + .4);
    canvas.drawPath(
      mouth,
      Paint()
        ..color = eye.withValues(alpha: .56)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .55
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
    canvas.restore();
  }

  void _ear(Canvas c, blob.Body b, bool right, double angle, Color color) {
    final side = right ? 1.0 : -1.0;
    final pivot = Offset(b.cx + side * b.rx * .59, b.cy - b.ry * .55);
    c.save();
    c.translate(pivot.dx, pivot.dy);
    c.rotate(angle);
    c.translate(-pivot.dx, -pivot.dy);
    c.translate(b.cx, b.cy);
    c.scale(side * b.rx, b.ry);
    final height = profile.traits.numIn(
      right ? 'cat.ear.right' : 'cat.ear.left',
      1.48,
      1.62,
    );
    final ear = Path()
      ..moveTo(.26, -.67)
      ..lineTo(.70, -height + .10)
      ..quadraticBezierTo(.80, -height - .05, .86, -height + .04)
      ..cubicTo(.95, -1.20, 1.02, -.70, .94, -.32)
      ..close();
    c.drawPath(ear, Paint()..color = color);
    // Small inner facets make the cat legible without altering its native face.
    final inner = Path()
      ..moveTo(.51, -.74)
      ..lineTo(.78, -height + .24)
      ..quadraticBezierTo(.87, -1.04, .83, -.64)
      ..close();
    c.drawPath(inner, Paint()..color = Color.lerp(color, Colors.black, .20)!);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant CatPainter oldDelegate) =>
      oldDelegate.profile != profile || oldDelegate.mood != mood;
}
