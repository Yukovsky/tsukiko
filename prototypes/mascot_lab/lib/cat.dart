import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'genome.dart';
import 'silhouette.dart';

part 'figure.dart';

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

/// Feline gestures held on top of the unchanged Blobatar expression. Ears are
/// droop angles for both sides; [arc] bends the eyes into the closed curves of
/// the original drawing; [curve] is the mouth, 1 for a caret and -1 for a smile.
class CatRig {
  const CatRig({
    this.tilt = 0,
    this.lift = 0,
    this.leftEar = 0,
    this.rightEar = 0,
    this.arc = 0,
    this.wink = 0,
    this.blush = 1,
    this.curve = 1,
    this.open = 0,
    this.lid = 0,
    this.frown = 0,
    this.attention = 0,
  });
  final double tilt, lift, leftEar, rightEar, arc, wink, blush, curve, open;

  /// [lid] hides that share of each eye from the top; the pose tilt turns
  /// the cut into sad or cross brows. Past .5, [frown] turns any mouth down.
  final double lid, frown;
  final double attention;

  static CatRig forMood(CatMood mood) {
    final face = _face(mood);
    return CatRig(
      tilt: face.tilt,
      lift: face.lift,
      leftEar: face.leftEar,
      rightEar: face.rightEar,
      arc: face.arc,
      wink: face.wink,
      blush: face.blush,
      curve: face.curve,
      open: face.open,
      lid: face.lid,
      frown: face.frown,
      attention: face.attention,
    );
  }

  static CatRig _face(CatMood mood) => switch (mood) {
    CatMood.idle => const CatRig(),
    CatMood.listening => const CatRig(
      tilt: -.05,
      lift: -1.5,
      leftEar: -.1,
      rightEar: -.1,
      attention: 1,
    ),
    CatMood.thinking => const CatRig(
      tilt: .07,
      leftEar: .12,
      rightEar: -.04,
      curve: .4,
    ),
    CatMood.happy => const CatRig(
      lift: -1,
      leftEar: -.08,
      rightEar: -.08,
      arc: 2.4,
      blush: 1.3,
      curve: -1,
    ),
    CatMood.love => const CatRig(
      lift: -1,
      leftEar: -.06,
      rightEar: -.06,
      blush: 1.6,
      curve: -1,
    ),
    CatMood.sad => const CatRig(
      tilt: .04,
      lift: 1.6,
      leftEar: .4,
      rightEar: .4,
      blush: .5,
      lid: .3,
      frown: 1,
    ),
    CatMood.sick => const CatRig(
      tilt: .05,
      lift: 1.6,
      leftEar: .42,
      rightEar: .36,
      blush: .3,
      lid: .32,
      frown: .7,
    ),
    CatMood.sleepy => const CatRig(
      tilt: .05,
      lift: 1.8,
      leftEar: .3,
      rightEar: .36,
      arc: -2.2,
      blush: .8,
      curve: -.4,
    ),
    CatMood.surprised => const CatRig(
      lift: -2,
      leftEar: -.14,
      rightEar: -.14,
      curve: 0,
      open: 1,
    ),
    CatMood.scared => const CatRig(
      lift: -1,
      leftEar: .42,
      rightEar: .42,
      blush: .3,
      curve: .3,
      open: .6,
    ),
    CatMood.mad => const CatRig(
      leftEar: .46,
      rightEar: .46,
      blush: .4,
      frown: .8,
    ),
    CatMood.wink => const CatRig(wink: 2.6, curve: -1, blush: 1.2),
    CatMood.smug => const CatRig(tilt: -.03, curve: -.7, blush: .9),
    CatMood.unsure => const CatRig(
      tilt: .06,
      leftEar: .24,
      rightEar: -.02,
      curve: .1,
    ),
    CatMood.shy => const CatRig(
      lift: 1,
      leftEar: .34,
      rightEar: .34,
      blush: 1.7,
      curve: .5,
    ),
  };

  /// The same face with the ears' droop scaled: a cat lying down keeps
  /// its ears up more than a sad head alone would.
  CatRig withEars(double k) => CatRig(
    tilt: tilt,
    lift: lift,
    leftEar: leftEar * k,
    rightEar: rightEar * k,
    arc: arc,
    wink: wink,
    blush: blush,
    curve: curve,
    open: open,
    lid: lid,
    frown: frown,
    attention: attention,
  );

  static CatRig lerp(CatRig a, CatRig b, double t) {
    double v(double x, double y) => x + (y - x) * t;
    return CatRig(
      tilt: v(a.tilt, b.tilt),
      lift: v(a.lift, b.lift),
      leftEar: v(a.leftEar, b.leftEar),
      rightEar: v(a.rightEar, b.rightEar),
      arc: v(a.arc, b.arc),
      wink: v(a.wink, b.wink),
      blush: v(a.blush, b.blush),
      curve: v(a.curve, b.curve),
      open: v(a.open, b.open),
      lid: v(a.lid, b.lid),
      frown: v(a.frown, b.frown),
      attention: v(a.attention, b.attention),
    );
  }
}

/// One look string resolved once. Geometry comes from a Blobatar style built
/// around [CatSilhouette]; poses, tints and motion seeds are the library's.
class CatProfile {
  CatProfile(this.text);
  final String text;
  late final CatGenome genome = CatGenome.parse(text);
  late final blob.Traits traits = genome.traits;
  late final CatLook look = CatLook(genome, traits);
  late final CatSilhouette silhouette = CatSilhouette(look, traits);
  late final blob.BlobatarLayout layout = blob.BlobatarStyle([
    (silhouette, 1.0),
  ], silhouette.fit).layout(traits);
  late final blob.MotionSeeds seeds = blob.motionSeeds(traits);
  late final (Color, Color, Color, Color) colors = look.colors;
  Color get head => colors.$1;
  Color get eyeColor => colors.$2;
  Color get accent => Color.lerp(head, Colors.white, .55)!;
  late final double twitchEvery = traits.numIn('cat.ear.twitch', 5200, 9400);

  /// Two tufts on each cheek where the head is widest, leaning down like
  /// brushed fur; drawn as one shape with the head.
  late final Path cheekFur = _cheekFur();

  Path _cheekFur() {
    final out = Path();
    if (look.head == CatHead.fluff) return out;
    final b = layout.body;
    final metric = toPath(silhouette.trace(b)).computeMetrics().first;
    // The right cheek: the outermost stretch of the outline below the eyes.
    final samples = [
      for (var i = 0; i < 240; i++)
        metric.getTangentForOffset(metric.length * i / 240)!,
    ];
    for (final (at, size) in const [(.3, .9), (.48, .75)]) {
      final y = b.cy + at * b.ry;
      final hit = samples
          .where((t) => t.position.dx > b.cx)
          .reduce(
            (a, c) =>
                (c.position.dy - y).abs() < (a.position.dy - y).abs() ? c : a,
          );
      for (final side in [1.0, -1.0]) {
        Offset m(Offset p) => Offset(b.cx + (p.dx - b.cx) * side, p.dy);
        final p = hit.position;
        // Outward and a little down, the way cheek fur lies.
        final out0 = Offset(math.cos(.55), math.sin(.55));
        final along = Offset(-out0.dy, out0.dx);
        final w = b.rx * .1 * size, len = b.rx * .11 * size;
        final base0 = p - out0 * (w * .9) - along * w;
        final base1 = p - out0 * (w * .9) + along * w;
        final tip = p + out0 * len + along * (len * .35);
        out.addPath(
          Path()
            ..moveTo(m(base0).dx, m(base0).dy)
            ..quadraticBezierTo(
              m(p - along * (w * .2)).dx,
              m(p - along * (w * .2)).dy,
              m(tip).dx,
              m(tip).dy,
            )
            ..quadraticBezierTo(
              m(p + along * (w * .9)).dx,
              m(p + along * (w * .9)).dy,
              m(base1).dx,
              m(base1).dy,
            )
            ..close(),
          Offset.zero,
        );
      }
    }
    return out;
  }

  /// A mood tints the fur a touch; the eyes keep the cat's own colour.
  blob.Palette colorsFor(blob.Expression expression) {
    final base = {blob.colorHead: _hex(head), blob.colorEye: _hex(eyeColor)};
    return {
      ...base,
      blob.colorHead: blob.mixHex(
        base[blob.colorHead]!,
        blob.expressionPalette(base, expression)[blob.colorHead]!,
        .05,
      ),
    };
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
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
    this.glow = true,
    this.body = false,
    this.onPoke,
  });
  final CatProfile profile;
  final CatMood mood;
  final bool animate, gaze, glow;

  /// The whole cat on the floor instead of the head alone.
  final bool body;
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
  late blob.MotionSeeds _seeds = widget.profile.seeds;
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
  late final BodySpring _body = BodySpring(BodyPose.forMood(widget.mood));

  double get _progress =>
      blob.easeInOut(((_time - _morphStart) / 420).clamp(0, 1));
  CatRig get _rig => CatRig.lerp(_rigFrom, _rigTo, _progress);
  blob.Pose get _pose => blob.lerpPose(_from, _to, _progress);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  /// The cat watches the cursor anywhere in its window, not only over
  /// itself: every pointer event of the window passes through here. Close
  /// by, the eyes follow the point; farther off, only its direction.
  void _pointer(PointerEvent event) {
    if (event is PointerRemovedEvent) {
      _hovered = false;
      _target = Offset.zero;
      return;
    }
    if (event is! PointerHoverEvent && event is! PointerMoveEvent) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final half = widget.size / 2;
    final v =
        box.globalToLocal(event.position) -
        Offset(half, (widget.height ?? widget.size) / 2);
    final point = v / math.max(v.distance, half);
    _hovered = true;
    _target = Offset(point.dx * 3.2, point.dy * 2.3);
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
      _body.snap();
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
    if (widget.body) _body.step(dt);
    _repaint.value++;
  }

  void _morph(blob.Pose target, [blob.Expression? expression]) {
    _fromHead = _head;
    _fromEye = _eye;
    final palette = widget.profile.colorsFor(
      expression ?? widget.mood.expression,
    );
    _toHead = CatProfile.hex(palette[blob.colorHead]!);
    _toEye = CatProfile.hex(palette[blob.colorEye]!);
    _rigFrom = _rig;
    _rigTo = CatRig.forMood(widget.mood);
    _body.aim(BodyPose.forMood(widget.mood));
    _from = _pose;
    _to = target;
    _morphStart = _time;
    if (!_ticker.isActive) {
      _body.snap();
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
    final identityChanged = oldWidget.profile.text != widget.profile.text;
    if (identityChanged) _seeds = widget.profile.seeds;
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
    _body.poke();
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
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
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
                    glow: widget.glow,
                    repaint: _repaint,
                    frame: () => CatFrame(
                      body: widget.body ? _body.pose : null,
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

/// A still cat for pickers: paints once, runs no ticker.
class StillCat extends StatelessWidget {
  const StillCat({
    super.key,
    required this.profile,
    required this.size,
    this.mood = CatMood.idle,
    this.body = false,
  });
  final CatProfile profile;
  final CatMood mood;
  final double size;
  final bool body;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.square(size),
      painter: CatPainter(
        profile: profile,
        mood: mood,
        glow: false,
        frame: () => CatFrame(
          body: body ? BodyPose.forMood(mood) : null,
          pose: mood.expression.pose,
          motion: blob.motionAt(profile.seeds, 0, 0),
        ),
      ),
    ),
  );
}

class _Tuft {
  const _Tuft(this.path, this.from, this.to);
  final Path path;
  final Offset from, to;
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
    this.body,
  });

  /// The whole cat on the floor; null paints the head alone.
  final BodyPose? body;
  final blob.Pose pose;
  final blob.MotionFrame motion;
  final Offset gaze;
  final double tracking;
  final double time, pet, speech;
  final CatRig? rig;
  final Color? headColor, eyeColor;
}

double _rad(double degrees) => degrees * math.pi / 180;

/// Follows the native renderer's transform order for the body and eyes, so a
/// Blobatar pose lands the same way; everything feline hangs off that layout.
class CatPainter extends CustomPainter {
  CatPainter({
    required this.profile,
    required this.mood,
    required this.frame,
    this.glow = true,
    super.repaint,
  });
  final CatProfile profile;
  final CatMood mood;
  final CatFrame Function() frame;
  final bool glow;

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
        ? profile.colorsFor(mood.expression)
        : null;
    final head = f.headColor ?? CatProfile.hex(colors![blob.colorHead]!);
    final eye = f.eyeColor ?? CatProfile.hex(colors![blob.colorEye]!);
    final ink = profile.colors.$3, blush = profile.colors.$4;
    final paints = _Inks(head, eye, ink, blush);
    if (f.body case final body?) {
      _paintFigure(canvas, size, f, body, r, motion, paints);
      return;
    }

    final scale = math.min(size.width, size.height) / 112;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-50, -50);
    _paintHead(canvas, f, r, motion, paints, glow: glow);
    canvas.restore();
  }

  /// Moves the canvas into the head's own 100-unit box as this frame holds
  /// it (roll, lift, breath, bob) and returns the two ear angles.
  (double, double) _enterHead(
    Canvas canvas,
    CatFrame f,
    CatRig r,
    blob.MotionFrame motion,
  ) {
    canvas.translate(50, 74);
    canvas.rotate(r.tilt + f.gaze.dx * .006 - f.pet * .05);
    canvas.translate(0, r.lift);
    canvas.translate(-50, -74);
    canvas.translate(motion.shake.$1, motion.shake.$2);
    canvas.translate(50, 50);
    canvas.scale(motion.breathe.$1, motion.breathe.$2);
    canvas.translate(-50, -50);
    canvas.translate(0, f.pose.bdy + motion.bob);
    final twitchAt = (f.time % profile.twitchEvery) / 340;
    final twitch = twitchAt < 1 ? math.sin(math.pi * twitchAt) * .16 : 0.0;
    return (
      r.leftEar - f.speech * .06 + f.pet * .3,
      r.rightEar - f.speech * .06 + f.pet * .12 + twitch,
    );
  }

  /// The head's outline alone, its full shape with ear brushes, and the
  /// brushes themselves.
  (Path, Path, List<_Tuft>) _headShape(double left, double right, double t) {
    final b = profile.layout.body;
    final outline = toPath(
      profile.silhouette.trace(b, left: left, right: right),
    );
    final tufts = profile.look.ears == CatEars.tuft
        ? [_tuft(b, left, t, left: true), _tuft(b, right, t)]
        : const <_Tuft>[];
    var shape = outline;
    for (final tuft in tufts) {
      shape = Path.combine(PathOperation.union, shape, tuft.path);
    }
    return (outline, shape, tufts);
  }

  /// Only the head's ink, for a body that shares one outline with it.
  void _paintHeadInk(
    Canvas canvas,
    CatFrame f,
    CatRig r,
    blob.MotionFrame motion,
    _Inks inks,
  ) {
    canvas.save();
    final (left, right) = _enterHead(canvas, f, r, motion);
    final (_, shape, _) = _headShape(left, right, f.time);
    _ink(canvas, [shape, profile.cheekFur], inks);
    canvas.restore();
  }

  void _ink(Canvas canvas, List<Path> paths, _Inks inks) {
    final b = profile.layout.body;
    final line = inks.line(b.rx * .08);
    for (final p in paths) {
      canvas.drawPath(p, line);
      canvas.drawPath(p.shift(Offset(0, b.rx * .018)), line);
    }
  }

  /// The head in its own 100-unit box, where Blobatar laid it out: outline,
  /// ears, fur, face and whatever it wears. The caller places the box.
  /// Without [inked] the outline is left to the caller.
  void _paintHead(
    Canvas canvas,
    CatFrame f,
    CatRig r,
    blob.MotionFrame motion,
    _Inks inks, {
    bool glow = false,
    bool inked = true,
  }) {
    final head = inks.fur, eye = inks.eye, ink = inks.ink, blush = inks.blush;
    final b = profile.layout.body;
    canvas.save();
    final (left, right) = _enterHead(canvas, f, r, motion);
    final (outline, shape, tufts) = _headShape(left, right, f.time);
    final fur = profile.cheekFur;
    if (glow) {
      canvas.drawPath(
        shape,
        Paint()
          ..color = Color.lerp(head, Colors.white, .1)!.withValues(alpha: .34)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    // Ink first, fill over it: only the outer half of the line survives, and
    // the cheek fur joins the head without a seam.
    if (inked) _ink(canvas, [shape, fur], inks);
    final fill = Paint()..color = head;
    canvas.drawPath(shape, fill);
    canvas.drawPath(fur, fill);
    for (final t in tufts) {
      // Dipped in ink: darkest at the hair's end, fading back down the ear.
      final hair = Color.lerp(head, ink, .8)!;
      canvas.save();
      canvas.clipPath(shape);
      canvas.drawCircle(
        t.to,
        (t.to - t.from).distance * 1.2,
        Paint()
          ..shader = ui.Gradient.linear(
            t.from,
            t.to,
            [hair.withValues(alpha: 0), hair, hair],
            [0, .45, 1],
          ),
      );
      canvas.restore();
    }
    canvas.save();
    canvas.clipPath(outline);
    _paintMark(canvas, b, head, ink);
    _paintCheeks(canvas, b, ink, blush, r.blush);
    canvas.restore();
    _paintWhiskers(canvas, b, ink);

    canvas.save();
    canvas.translate(motion.saccade.$1, motion.saccade.$2);
    for (var i = 0; i < 2; i++) {
      _paintEye(canvas, i, f.pose, motion, r, eye, ink);
    }
    canvas.restore();
    _paintMouth(canvas, b, ink, r, f.speech);
    _paintWear(canvas, b, ink, blush, right);
    canvas.restore();
  }

  /// A brush of hair at the ear's tip, splaying into three points. It is
  /// one shape with the ear: its sides leave the ear's rounded
  /// tip along the tip's own tangent, so the outline only bends, never
  /// breaks, and the dark tint is painted over the merged shape.
  _Tuft _tuft(blob.Body b, double angle, double time, {bool left = false}) {
    final (inner, corner, outer) = profile.silhouette.earTip(
      b,
      angle,
      left: left,
    );
    final s = left ? -1.0 : 1.0;
    final w = b.rx;
    final up = corner - (inner + outer) / 2;
    final turn = math.atan2(up.dx, -up.dy);
    final cos = math.cos(turn), sin = math.sin(turn);
    Offset body(Offset point) => Offset(
      corner.dx + point.dx * cos - point.dy * sin,
      corner.dy + point.dx * sin + point.dy * cos,
    );
    // The rounded tip is the quad inner → corner → outer; below 0 and past
    // 1 the point runs back down the ear's straight edges instead.
    Offset tip(double t) => t < 0
        ? inner + (inner - corner) * -t
        : t > 1
        ? outer + (outer - corner) * (t - 1)
        : inner * ((1 - t) * (1 - t)) +
              corner * (2 * t * (1 - t)) +
              outer * (t * t);
    Offset along(double t) {
      final c = t.clamp(0.0, 1.0);
      final d = (corner - inner) * (1 - c) + (outer - corner) * c;
      return d / d.distance;
    }

    final sway = math.sin(time / 620 + (left ? 1.3 : 0)) * .06;
    Offset hair(double x, double y) {
      final a = sway * (-y / .3).clamp(0.0, 1.0);
      // Short brushes: the drawn cats keep the hair close to the ear.
      final px = s * x * w * .85, py = y * w * .5;
      return body(
        Offset(
          px * math.cos(a) - py * math.sin(a),
          px * math.sin(a) + py * math.cos(a),
        ),
      );
    }

    // The sides leave the ear's straight edges just below the rounding.
    const t0 = -.1, t1 = 1.1, k = .14;
    final a = tip(t0), z = tip(t1);
    final path = Path()..moveTo(a.dx, a.dy);
    final first = a + along(t0) * (k * w);
    final last = z - along(t1) * (k * w);
    // Read as: c2, end, then (c1, c2, end) per further hair, then the
    // last c1. The outer controls come from the tip's tangents.
    final h = [
      for (final (x, y) in const [
        (-.042, -.109),
        (-.025, -.227),
        (.0, -.185),
        (.025, -.168),
        (.042, -.176),
        (.059, -.227),
        (.084, -.26),
        (.101, -.26),
        (.109, -.218),
        (.134, -.202),
        (.16, -.21),
        (.067, -.084),
      ])
        hair(x, y),
    ];
    void cubic(Offset c1, Offset c2, Offset to) =>
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
    cubic(first, h[0], h[1]);
    for (var i = 2; i + 2 < h.length; i += 3) {
      cubic(h[i], h[i + 1], h[i + 2]);
    }
    cubic(h.last, last, z);
    final root = body(Offset(0, w * .4));
    path
      ..lineTo(root.dx, root.dy)
      ..close();
    return _Tuft(path, body(Offset(0, .24 * w)), h[1]);
  }

  void _paintEye(
    Canvas c,
    int index,
    blob.Pose pose,
    blob.MotionFrame motion,
    CatRig rig,
    Color color,
    Color ink,
  ) {
    final eye = profile.layout.eyes[index];
    final kind = profile.look.eyes;
    final side = index == 0 ? -1.0 : 1.0;
    final picked = index.toDouble();
    final phase =
        picked * (1 - pose.rock) +
        pose.rock * ((1 + side * motion.thinkingPhase) / 2);
    // Poses were tuned for slim pills; on a big round eye the same widening
    // would run into the other eye, so the stretch is damped. Shrinking is
    // halved for every kind, or sad beads end up as specks. Squints under .45
    // stay as they are: they are closed eyes, not small ones.
    final damp = kind == CatEyes.moon || kind == CatEyes.pupil
        ? .5
        : kind == CatEyes.slit
        ? .6
        : 1.0;
    final small = kind == CatEyes.bead || kind == CatEyes.pill;
    final keep = small ? .25 : .5;
    double held(double s) =>
        s > 1 ? 1 + (s - 1) * damp : (s < .45 ? s : 1 - (1 - s) * keep);
    final sx = pose.esx + picked * pose.esx2;
    final sy = pose.esy + picked * pose.esy2;
    final width = sx > 1 ? held(sx) : 1 - (1 - sx) * keep;
    final height = held(sy);

    c.save();
    c.translate(
      eye.cx + pose.edx * side,
      eye.cy + pose.edy + phase * pose.edy2,
    );
    c.rotate(
      _rad(
        (pose.tilt + picked * pose.tilt2) * side + eye.rot * (1 - pose.lock),
      ),
    );
    if (small && rig.lid > 0) {
      // A lid would swallow a small eye, so it gets a brow; the pose tilt
      // slants it the same way it would slant the lid.
      final y = -eye.ry * height - eye.rx * 1.1;
      c.drawLine(
        Offset(-eye.rx * 1.35, y),
        Offset(eye.rx * 1.35, y),
        Paint()
          ..color = ink.withValues(alpha: (rig.lid * 3).clamp(0.0, 1.0))
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round,
      );
    }
    // A closed eye is a thick pale crescent, as in the drawings: ^ when
    // glad, ‿ asleep. It fades in as the eye fades out, so an eye never
    // passes through a broken shape on the way.
    final bend = rig.arc + picked * rig.wink;
    final shut = small ? 0.0 : ((bend.abs() - .9) / 1.1).clamp(0.0, 1.0);
    // The open eye leaves in the first half, the crescent comes in the
    // second: never two half-seen eyes at once.
    final arcIn = (shut * 2 - 1).clamp(0.0, 1.0);
    if (arcIn > 0) {
      final k = bend > 0 ? 1.0 : -1.0;
      final rx = eye.rx, ry = eye.ry;
      // A filled crescent, thick in the middle and fine at the ends; glad
      // eyes arch high, sleeping ones sag only a little.
      final rise = bend > 0 ? 1.0 : .62;
      final crescent = Path()
        ..moveTo(-rx * .82, ry * .16 * k)
        ..quadraticBezierTo(
          0,
          -ry * (1.1 * rise + .2) * k,
          rx * .82,
          ry * .16 * k,
        )
        ..quadraticBezierTo(
          0,
          -ry * (1.1 * rise - .55) * k,
          -rx * .82,
          ry * .16 * k,
        )
        ..close();
      final pale = Color.lerp(
        color,
        Colors.white,
        .6,
      )!.withValues(alpha: arcIn);
      c.drawPath(crescent, Paint()..color = pale);
      c.drawPath(
        crescent,
        Paint()
          ..color = pale
          ..style = PaintingStyle.stroke
          ..strokeWidth = ry * .1
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final seen = (1 - shut * 2).clamp(0.0, 1.0);
    if (seen <= .01) {
      c.restore();
      return;
    }
    c.scale(width, height);
    c.rotate(_rad(motion.wrap.rotation * side));
    c.scale(
      1 + motion.wrap.magnitudeX + motion.wrap.side * side * damp,
      (1 + motion.wrap.scaleY) * motion.blink,
    );

    final closing = (1 - motion.blink).clamp(0.0, 1.0);
    final path = _eyePath(
      eye,
      (rig.arc + picked * rig.wink) * (1 - shut * .6) - closing * 1.4,
    );
    final bead = kind == CatEyes.bead && !profile.look.darkEyes;
    if (rig.lid > 0 && !small) {
      c.clipRect(
        Rect.fromLTRB(
          -eye.rx * 3,
          -eye.ry * (1 + rig.arc.abs()) + eye.ry * 2 * rig.lid,
          eye.rx * 3,
          eye.ry * 3,
        ),
      );
    }
    c.drawPath(path, Paint()..color = bead ? _beadColor(ink) : color);
    // While the lid comes down the iris stays: a squinting pose must not
    // leave a white eye without one.
    final open = shut > 0
        ? 1.0
        : ((height * motion.blink - .5) / .3).clamp(0.0, 1.0);
    if (open > 0 && kind != CatEyes.pill) {
      c.save();
      c.clipPath(path);
      _eyeDetail(c, eye, kind, motion, color, ink, open);
      c.restore();
    }
    if (seen < 1 && !small) {
      // Closing, a lid of fur comes down over the eye with a dark lash
      // line on its edge, so the white never shows without its iris.
      final box = path.getBounds();
      final lid = box.top + box.height * (1 - seen);
      c.save();
      c.clipPath(path);
      c.drawRect(
        Rect.fromLTRB(box.left - 1, box.top - 1, box.right + 1, lid),
        Paint()..color = profile.head,
      );
      c.restore();
      final half =
          box.width /
          2 *
          math.sqrt(
            math.max(
              0,
              1 - math.pow((lid - box.center.dy) / (box.height / 2), 2),
            ),
          );
      c.drawLine(
        Offset(box.center.dx - half, lid),
        Offset(box.center.dx + half, lid),
        Paint()
          ..color = ink
          ..strokeWidth = eye.ry * .16
          ..strokeCap = StrokeCap.round,
      );
    }
    c.restore();
  }

  Color _beadColor(Color ink) =>
      ink.computeLuminance() > .3 ? profile.eyeColor : ink;

  void _eyeDetail(
    Canvas c,
    blob.Eye eye,
    CatEyes kind,
    blob.MotionFrame motion,
    Color fill,
    Color ink,
    double alpha,
  ) {
    final look = profile.look;
    final rx = eye.rx, ry = eye.ry;
    final shine = Paint()..color = Colors.white.withValues(alpha: alpha);
    if (kind == CatEyes.pupil) {
      final dot = look.darkEyes ? Colors.black : ink;
      c.drawOval(
        Rect.fromCircle(center: Offset.zero, radius: rx * .68),
        Paint()..color = dot.withValues(alpha: alpha),
      );
    }
    if (kind == CatEyes.slit) {
      c.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * .42, height: ry * 1.7),
        Paint()..color = ink.withValues(alpha: alpha),
      );
      return;
    }
    final hasDark = kind == CatEyes.pupil || kind == CatEyes.bead;
    if (kind == CatEyes.moon && !look.darkEyes) {
      // A pupil in a deeper shade of the eye, or for about half the cats a
      // dark one ringed by the eye's pale colour; bare, the shine was lost
      // on the pale fill.
      final dark = profile.traits('cat.eye.dark') < .5;
      // Iris and pupil, as in the drawings: a wide ring tinted with the
      // cat's own fur and a deep centre under the shine.
      // Tinted with the cat's own fur, a good deal darker than it.
      final iris = Color.lerp(profile.head, ink, dark ? .62 : .3)!;
      c.drawCircle(
        Offset(0, ry * .08),
        rx * (dark ? .74 : .76),
        Paint()..color = iris.withValues(alpha: alpha),
      );
      c.drawCircle(
        Offset(0, ry * .12),
        rx * (dark ? .46 : .42),
        Paint()
          ..color = Color.lerp(
            profile.head,
            ink,
            dark ? .92 : .8,
          )!.withValues(alpha: alpha),
      );
      c.drawCircle(Offset(-rx * .28, -ry * .3), rx * .26, shine);
      c.drawCircle(Offset(rx * .32, ry * .32), rx * .11, shine);
      return;
    }
    if (hasDark || look.darkEyes) {
      c.drawCircle(Offset(-rx * .3, -ry * .36), rx * .24, shine);
      c.drawCircle(Offset(rx * .3, ry * .3), rx * .1, shine);
    }
  }

  Path _eyePath(blob.Eye eye, double arc) {
    final path = Path();
    const steps = 40;
    final power = 2 / eye.n;
    for (var i = 0; i < steps; i++) {
      final a = i / steps * 2 * math.pi;
      final cos = math.cos(a), sin = math.sin(a);
      final u = cos.sign * math.pow(cos.abs(), power);
      final v = sin.sign * math.pow(sin.abs(), power);
      final x = eye.rx * u;
      final y = eye.ry * (v + arc * (u * u - .5));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path..close();
  }

  void _paintMark(Canvas c, blob.Body b, Color head, Color ink) {
    final look = profile.look;
    final w = b.rx;
    Offset o(double x, double y) => Offset(b.cx + x * w, b.cy + y * w);
    final deep = Color.lerp(head, ink, .42)!;
    final light = head.computeLuminance() > .55
        ? deep
        : const Color(0xfffbeec4);
    final eyeY = (profile.layout.eyes[0].cy - b.cy) / w;
    switch (look.mark) {
      case CatMark.none:
        break;
      case CatMark.crescent:
        final top = o(0, -.365);
        c.drawPath(
          Path.combine(
            PathOperation.difference,
            Path()..addOval(Rect.fromCircle(center: top, radius: w * .145)),
            Path()..addOval(
              Rect.fromCircle(
                center: top + Offset(w * .07, -w * .04),
                radius: w * .125,
              ),
            ),
          ),
          Paint()..color = light,
        );
      case CatMark.stars:
        void star(Offset at, double r) {
          final k = r * .22;
          c.drawPath(
            Path()
              ..moveTo(at.dx, at.dy - r)
              ..quadraticBezierTo(
                at.dx + k * .4,
                at.dy - k * .4,
                at.dx + r,
                at.dy,
              )
              ..quadraticBezierTo(
                at.dx + k * .4,
                at.dy + k * .4,
                at.dx,
                at.dy + r,
              )
              ..quadraticBezierTo(
                at.dx - k * .4,
                at.dy + k * .4,
                at.dx - r,
                at.dy,
              )
              ..quadraticBezierTo(
                at.dx - k * .4,
                at.dy - k * .4,
                at.dx,
                at.dy - r,
              )
              ..close(),
            Paint()..color = light,
          );
        }
        star(o(0, -.39), w * .13);
        star(o(.22, -.31), w * .06);
        star(o(-.2, -.3), w * .05);
      case CatMark.stripes:
        final line = Paint()
          ..color = deep
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * .085
          ..strokeCap = StrokeCap.round;
        for (final x in [-.2, 0.0, .2]) {
          c.drawLine(o(x, -.72), o(x * .8, x == 0 ? -.36 : -.44), line);
        }
        for (final s in [-1.0, 1.0]) {
          c.drawLine(o(s * 1.24, .1), o(s * .92, .14), line);
          c.drawLine(o(s * 1.2, .4), o(s * .9, .36), line);
        }
      case CatMark.mask:
        // Siamese points: a soft dark face and matching ear tips.
        final paint = Paint()
          ..color = deep
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .09);
        c.drawOval(
          Rect.fromCenter(
            center: o(0, eyeY + .14),
            width: w * 1.5,
            height: w * 1.02,
          ),
          paint,
        );
        for (final s in [-1.0, 1.0]) {
          c.drawCircle(o(s * .78, -1.34), w * .4, paint);
        }
      case CatMark.patch:
        final side = profile.traits('cat.mark.side') < .5 ? -1.0 : 1.0;
        c.drawOval(
          Rect.fromCenter(
            center: o(side * .7, -.42),
            width: w * 1.5,
            height: w * 1.7,
          ),
          Paint()..color = deep,
        );
      case CatMark.muzzle:
        // Two whisker pads meeting under the mouth, small enough to sit
        // between the eyes rather than under them.
        final pad = Paint()..color = Color.lerp(head, Colors.white, .55)!;
        for (final side in [-1.0, 1.0]) {
          c.drawCircle(o(side * .09, eyeY + .25), w * .105, pad);
        }
    }
    if (look.ears == CatEars.fold) {
      for (final s in [-1.0, 1.0]) {
        c.drawPath(
          Path()
            ..moveTo(o(s * .46, -.72).dx, o(s * .46, -.72).dy)
            ..quadraticBezierTo(
              o(s * .96, -.86).dx,
              o(s * .96, -.86).dy,
              o(s * .96, -.46).dx,
              o(s * .96, -.46).dy,
            )
            ..quadraticBezierTo(
              o(s * .72, -.62).dx,
              o(s * .72, -.62).dy,
              o(s * .46, -.72).dx,
              o(s * .46, -.72).dy,
            ),
          Paint()..color = deep,
        );
      }
    }
  }

  void _paintCheeks(
    Canvas c,
    blob.Body b,
    Color ink,
    Color blush,
    double heat,
  ) {
    final kind = profile.look.cheeks;
    final w = b.rx;
    final eye = profile.layout.eyes;
    final y = eye[0].cy + w * .24;
    final x = w * .8;
    final strength = kind == CatCheeks.blush ? heat : heat - 1;
    if (strength > 0) {
      final paint = Paint()
        ..color = blush.withValues(alpha: (.78 * strength).clamp(0.0, 1.0))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.4);
      for (final s in [-1.0, 1.0]) {
        c.drawOval(
          Rect.fromCenter(
            center: Offset(b.cx + s * x, y),
            width: w * .44,
            height: w * .24,
          ),
          paint,
        );
      }
    }
    if (kind == CatCheeks.freckles) {
      final dot = Paint()..color = ink.withValues(alpha: .55);
      for (final s in [-1.0, 1.0]) {
        for (final (dx, dy) in const [(.72, .22), (.88, .2), (.8, .34)]) {
          c.drawCircle(
            Offset(b.cx + s * dx * w, eye[0].cy + dy * w),
            w * .032,
            dot,
          );
        }
      }
    }
  }

  void _paintWhiskers(Canvas c, blob.Body b, Color ink) {
    if (profile.look.cheeks != CatCheeks.whiskers) return;
    final w = b.rx;
    final y = profile.layout.eyes[0].cy + w * .22;
    final line = Paint()
      ..color = ink.withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..strokeCap = StrokeCap.round;
    for (final s in [-1.0, 1.0]) {
      for (final (from, to) in const [(-.03, -.09), (.08, .14)]) {
        c.drawPath(
          Path()
            ..moveTo(b.cx + s * w * .78, y + from * w)
            ..quadraticBezierTo(
              b.cx + s * w * .98,
              y + (from + to) / 2 * w,
              b.cx + s * w * 1.14,
              y + to * w,
            ),
          line,
        );
      }
    }
  }

  void _paintMouth(Canvas c, blob.Body b, Color ink, CatRig r, double speech) {
    final look = profile.look;
    final w = b.rx;
    final y = profile.layout.eyes[0].cy + w * .13;
    final half = w * .078;
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = .95
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final open = (r.open + speech * .75).clamp(0.0, 1.0);
    if (open > .02) {
      c.drawOval(
        Rect.fromCenter(
          center: Offset(b.cx, y + w * .05),
          width: half * (1.2 + open * .7),
          height: w * .17 * open + 1,
        ),
        Paint()..color = ink,
      );
      return;
    }
    if (r.frown > .5) {
      // Wider and lower than the resting caret, so a sad face cannot be
      // mistaken for a calm one at any size.
      final drop = half * 1.15 * r.frown;
      final low = y + w * .05;
      c.drawPath(
        Path()
          ..moveTo(b.cx - half * 1.25, low + drop * .5)
          ..quadraticBezierTo(
            b.cx,
            low - drop * 1.1,
            b.cx + half * 1.25,
            low + drop * .5,
          ),
        line,
      );
      return;
    }
    switch (look.mouth) {
      case CatMouth.dot:
        c.drawOval(
          Rect.fromCenter(
            center: Offset(b.cx, y),
            width: half * .9,
            height: half * .68,
          ),
          Paint()..color = ink,
        );
      case CatMouth.omega:
        final dip = w * .07 * (1.25 - .35 * r.curve);
        c.drawPath(
          Path()
            ..moveTo(b.cx - half * 1.7, y)
            ..quadraticBezierTo(b.cx - half * .85, y + dip * 2, b.cx, y)
            ..quadraticBezierTo(
              b.cx + half * .85,
              y + dip * 2,
              b.cx + half * 1.7,
              y,
            ),
          line,
        );
      case CatMouth.caret || CatMouth.fang:
        final rise = half * r.curve;
        final mouth = Path()..moveTo(b.cx - half * .78, y + rise * .4);
        // A pointed caret at rest, as in the old drawing; a curve reads as a
        // frown at this size. Smiles stay curved.
        if (r.curve > 0) {
          mouth
            ..lineTo(b.cx, y - rise * .4)
            ..lineTo(b.cx + half * .78, y + rise * .4);
        } else {
          mouth.quadraticBezierTo(
            b.cx,
            y - rise * 1.3,
            b.cx + half * .78,
            y + rise * .4,
          );
        }
        c.drawPath(mouth, line);
        if (look.mouth == CatMouth.fang) {
          final x = b.cx + half * .62;
          final top = y - rise * .14;
          c.drawPath(
            Path()
              ..moveTo(x - 1, top)
              ..lineTo(x + .1, top + 2.1)
              ..lineTo(x + 1.1, top)
              ..close(),
            Paint()..color = const Color(0xfffffdf6),
          );
        }
    }
  }

  void _paintWear(Canvas c, blob.Body b, Color ink, Color blush, double ear) {
    final w = b.rx;
    Offset o(double x, double y) => Offset(b.cx + x * w, b.cy + y * w);
    switch (profile.look.wear) {
      case CatWear.none:
        return;
      case CatWear.bow:
        c.save();
        c.translate(o(.62, -.74).dx, o(.62, -.74).dy);
        c.rotate(.28 + ear * .8);
        final ribbon = Paint()..color = blush;
        for (final s in [-1.0, 1.0]) {
          c.drawPath(
            Path()
              ..moveTo(0, 0)
              ..quadraticBezierTo(s * w * .16, -w * .25, s * w * .36, -w * .15)
              ..quadraticBezierTo(s * w * .42, 0, s * w * .36, w * .15)
              ..quadraticBezierTo(s * w * .16, w * .25, 0, 0),
            ribbon,
          );
        }
        c.drawCircle(
          Offset.zero,
          w * .085,
          Paint()..color = Color.lerp(blush, Colors.white, .45)!,
        );
        c.restore();
      case CatWear.flower:
        final at = o(.6, -.7);
        final petal = Paint()..color = const Color(0xfffff6f0);
        for (var i = 0; i < 5; i++) {
          final a = i * 2 * math.pi / 5 - math.pi / 2;
          c.drawCircle(
            at + Offset(math.cos(a), math.sin(a)) * (w * .15),
            w * .115,
            petal,
          );
        }
        c.drawCircle(at, w * .09, Paint()..color = const Color(0xfff6c549));
      case CatWear.phones:
        final band = Color.lerp(ink, Colors.black, .25)!;
        c.drawPath(
          Path()
            ..moveTo(b.cx - w * .98, b.cy - w * .06)
            ..cubicTo(
              b.cx - w * .9,
              b.cy - w * 1.02,
              b.cx + w * .9,
              b.cy - w * 1.02,
              b.cx + w * .98,
              b.cy - w * .06,
            ),
          Paint()
            ..color = band
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * .085
            ..strokeCap = StrokeCap.round,
        );
        for (final s in [-1.0, 1.0]) {
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: o(s * 1.0, .04),
                width: w * .27,
                height: w * .5,
              ),
              Radius.circular(w * .13),
            ),
            Paint()..color = blush,
          );
        }
      case CatWear.cap:
        final paint = Paint()..color = blush;
        c.drawPath(
          Path()
            ..moveTo(b.cx - w * .36, b.cy - w * .58)
            ..quadraticBezierTo(
              b.cx - w * .2,
              b.cy - w * 1.26,
              b.cx + w * .3,
              b.cy - w * 1.28,
            )
            ..quadraticBezierTo(
              b.cx + w * .54,
              b.cy - w * 1.26,
              b.cx + w * .6,
              b.cy - w * .98,
            )
            ..quadraticBezierTo(
              b.cx + w * .46,
              b.cy - w * 1.06,
              b.cx + w * .36,
              b.cy - w * .58,
            )
            ..close(),
          paint,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: o(0, -.57),
              width: w * .86,
              height: w * .17,
            ),
            Radius.circular(w * .085),
          ),
          Paint()..color = const Color(0xfffff6ea),
        );
        c.drawCircle(
          o(.61, -.94),
          w * .105,
          Paint()..color = const Color(0xfffff6ea),
        );
    }
  }

  @override
  bool shouldRepaint(covariant CatPainter oldDelegate) =>
      oldDelegate.profile.text != profile.text ||
      oldDelegate.mood != mood ||
      oldDelegate.glow != glow;
}
