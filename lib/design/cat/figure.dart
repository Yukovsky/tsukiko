part of 'cat.dart';

// The whole cat, from the drawn sheets. The body is not built from
// ellipses and splines any more: tool/cat_trace/trace.py traces each drawn
// pose (tsukiko, lumi, yuko × six poses) into tone layers — fur, light
// fluff, shade, deep shade and stripes, ink — and figure_data.dart holds
// them as contours. The painter recolours them for the cat's coat, sways
// the tail, breathes, and puts the generated head where the drawn one was.
//
// Moods pick one of the six poses and add their own movements, paws and
// signs. Between poses the body outline morphs and the drawn details fade
// across, while the head glides from one place to the other.
//
// Units are the head's half width; the origin is the floor under the cat,
// y grows downward.

/// Movements a mood keeps going on top of its pose.
enum Move { wag, lash, bounce, tremble, sway, fidget }

/// Little drawn signs around the head.
enum Emote { dashes, hearts, zzz, question, dots, sweat, anger }

/// A front paw raised over the face for a mood.
enum Paws { none, chin, clasp, cheeks, wave }

/// The six drawn poses, in the order of the sheets.
enum Stance { sit, glad, hunch, loaf, curl, stand }

/// A mood's pose: which drawing, which paws, which signs and movements.
class BodyPose {
  const BodyPose(
    this.stance, {
    this.paws = Paws.none,
    this.emotes = const {},
    this.moves = const {},
  });

  final Stance stance;
  final Paws paws;
  final Map<Emote, double> emotes;
  final Map<Move, double> moves;

  static BodyPose forMood(CatMood mood) => switch (mood) {
    CatMood.idle => const BodyPose(Stance.sit, moves: {Move.fidget: 1}),
    CatMood.listening => const BodyPose(Stance.sit, moves: {Move.wag: .15}),
    CatMood.thinking => const BodyPose(
      Stance.sit,
      paws: Paws.chin,
      emotes: {Emote.dots: 1},
    ),
    CatMood.happy => const BodyPose(
      Stance.glad,
      emotes: {Emote.dashes: 1},
      moves: {Move.wag: .8, Move.bounce: .6},
    ),
    CatMood.love => const BodyPose(
      Stance.glad,
      paws: Paws.clasp,
      emotes: {Emote.hearts: 1},
      moves: {Move.sway: .7, Move.wag: .3},
    ),
    CatMood.wink => const BodyPose(
      Stance.glad,
      paws: Paws.wave,
      moves: {Move.wag: .4},
    ),
    CatMood.smug => const BodyPose(Stance.sit, moves: {Move.wag: .12}),
    CatMood.shy => const BodyPose(
      Stance.sit,
      paws: Paws.cheeks,
      moves: {Move.sway: .4},
    ),
    CatMood.scared => const BodyPose(
      Stance.hunch,
      emotes: {Emote.sweat: 1},
      moves: {Move.tremble: 1},
    ),
    CatMood.sad => const BodyPose(Stance.hunch),
    CatMood.sick => const BodyPose(
      Stance.curl,
      emotes: {Emote.sweat: .8},
      moves: {Move.tremble: .35},
    ),
    CatMood.sleepy => const BodyPose(Stance.curl, emotes: {Emote.zzz: 1}),
    CatMood.unsure => const BodyPose(
      Stance.loaf,
      emotes: {Emote.question: 1},
      moves: {Move.sway: .5},
    ),
    CatMood.surprised => const BodyPose(
      Stance.stand,
      emotes: {Emote.dashes: 1},
    ),
    CatMood.mad => const BodyPose(
      Stance.stand,
      emotes: {Emote.anger: 1},
      moves: {Move.lash: 1, Move.tremble: .3},
    ),
  };
}

/// One frame of the body: the two poses being blended and how far, with
/// every amplitude already eased.
class FigureState {
  const FigureState({
    required this.from,
    required this.to,
    required this.t,
    required this.paws,
    required this.pawsIn,
    required this.emotes,
    required this.moves,
    this.squash = 0,
  });

  /// A pose held still, for pickers and art.
  factory FigureState.at(BodyPose pose) => FigureState(
    from: pose.stance,
    to: pose.stance,
    t: 1,
    paws: pose.paws,
    pawsIn: 1,
    emotes: [for (final e in Emote.values) pose.emotes[e] ?? 0],
    moves: [for (final m in Move.values) pose.moves[m] ?? 0],
  );

  final Stance from, to;

  /// 0 at [from], 1 at [to], eased.
  final double t;
  final Paws paws;
  final double pawsIn;
  final List<double> emotes, moves;
  final double squash;

  double operator [](Move m) => moves[m.index];
  double emoteOf(Emote e) => emotes[e.index];
}

/// The body in motion: a change of mood morphs to the new pose over a
/// little more than half a second, squashing the body for a beat; signs,
/// movements and paws fade across on their own.
class BodySpring {
  BodySpring(BodyPose pose)
    : _from = pose.stance,
      _to = pose.stance,
      _paws = pose.paws,
      _target = pose,
      _emotes = [for (final e in Emote.values) pose.emotes[e] ?? 0],
      _moves = [for (final m in Move.values) pose.moves[m] ?? 0];

  Stance _from, _to;
  double _t = 1;
  BodyPose _target;
  Paws _paws;
  double _pawsIn = 1;
  final List<double> _emotes, _moves;
  double _squash = 0, _squashV = 0;

  static const _morphMs = 620.0;

  void aim(BodyPose pose) {
    if (pose.stance != _to) {
      // From wherever the body is now: mid-way, the nearer pose.
      _from = _t < .5 ? _from : _to;
      _to = pose.stance;
      _t = 0;
      _squashV += 2.4;
    }
    _target = pose;
  }

  void poke() => _squashV += 3.2;

  void snap() {
    _from = _to;
    _t = 1;
    _paws = _target.paws;
    _pawsIn = 1;
    for (final e in Emote.values) {
      _emotes[e.index] = _target.emotes[e] ?? 0;
    }
    for (final m in Move.values) {
      _moves[m.index] = _target.moves[m] ?? 0;
    }
    _squash = _squashV = 0;
  }

  void step(double ms) {
    _t = math.min(1, _t + ms / _morphMs);
    final k = 1 - math.exp(-ms / 140);
    for (final e in Emote.values) {
      _emotes[e.index] += ((_target.emotes[e] ?? 0) - _emotes[e.index]) * k;
    }
    for (final m in Move.values) {
      _moves[m.index] += ((_target.moves[m] ?? 0) - _moves[m.index]) * k;
    }
    // Paws: the old ones go down first, then the new ones come up, once
    // the body has nearly arrived.
    if (_paws != _target.paws) {
      _pawsIn = math.max(0, _pawsIn - ms / 160);
      if (_pawsIn == 0) _paws = _target.paws;
    } else if (_t > .7) {
      _pawsIn = math.min(1, _pawsIn + ms / 220);
    }
    // Squash: an underdamped spring.
    var left = ms / 1000;
    while (left > 0) {
      final dt = math.min(1 / 240, left);
      left -= dt;
      final a = -2 * .32 * 15 * _squashV - 15 * 15 * _squash;
      _squashV += a * dt;
      _squash += _squashV * dt;
    }
  }

  FigureState get pose => FigureState(
    from: _from,
    to: _to,
    t: _ease(_t),
    paws: _paws,
    pawsIn: _ease(_pawsIn),
    emotes: [..._emotes],
    moves: [..._moves],
    squash: _squash,
  );
}

double _ease(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// A traced pose decoded once: its layers as contours of points with tail
/// weights, and its morph outline.
class _Pose {
  _Pose(TracedPose p)
    : head = p.head,
      tilt = p.tilt,
      root = p.root,
      layers = _decodeLayers(p.layers),
      morph = _decodePoints(p.morph);

  final Offset head;
  final double tilt;
  final Offset? root;

  /// Per class (see [tracedClasses]): contours, each a list of points with
  /// their tail weight.
  final Map<int, List<List<(Offset, double)>>> layers;
  final List<(Offset, double)> morph;

  /// Paths of contours the tail does not move, built once.
  final _still = <int, Path>{};

  static Int16List _ints(String b64) {
    final bytes = base64Decode(b64);
    return bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2);
  }

  static Map<int, List<List<(Offset, double)>>> _decodeLayers(String b64) {
    final v = _ints(b64);
    var i = 0;
    final out = <int, List<List<(Offset, double)>>>{};
    final n = v[i++];
    for (var l = 0; l < n; l++) {
      final cls = v[i++], count = v[i++];
      final list = <List<(Offset, double)>>[];
      for (var c = 0; c < count; c++) {
        final pts = v[i++];
        list.add([
          for (var k = 0; k < pts; k++)
            (
              Offset(v[i + k * 3] / 1000, v[i + k * 3 + 1] / 1000),
              v[i + k * 3 + 2] / 1000,
            ),
        ]);
        i += pts * 3;
      }
      out[cls] = list;
    }
    return out;
  }

  static List<(Offset, double)> _decodePoints(String b64) {
    final v = _ints(b64);
    return [
      for (var k = 0; k + 2 < v.length; k += 3)
        (Offset(v[k] / 1000, v[k + 1] / 1000), v[k + 2] / 1000),
    ];
  }

  static bool _isStill(List<(Offset, double)> c) => c.every((q) => q.$2 < .002);

  /// The class's contours as one path, the tail turned by [tail] radians.
  Path path(int cls, double tail) {
    final contours = layers[cls];
    if (contours == null) return Path();
    final still = _still.putIfAbsent(cls, () {
      final p = Path()..fillType = PathFillType.evenOdd;
      for (final c in contours) {
        if (_isStill(c)) _smooth(p, [for (final q in c) q.$1]);
      }
      return p;
    });
    final r = root;
    final moving = contours.where((c) => !_isStill(c)).toList();
    if (moving.isEmpty) return still;
    final out = Path()..fillType = PathFillType.evenOdd;
    out.addPath(still, Offset.zero);
    for (final c in moving) {
      _smooth(out, [
        for (final q in c) r == null ? q.$1 : _turn(q.$1, r, tail * q.$2),
      ]);
    }
    return out;
  }
}

Offset _turn(Offset p, Offset about, double a) {
  if (a == 0) return p;
  final d = p - about;
  final c = math.cos(a), s = math.sin(a);
  return about + Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
}

/// A closed smooth curve through [p]: quadratic arcs between midpoints,
/// which rounds off the tracer's polygon corners.
void _smooth(Path path, List<Offset> p) {
  final n = p.length;
  if (n < 3) return;
  final m0 = (p[n - 1] + p[0]) / 2;
  path.moveTo(m0.dx, m0.dy);
  for (var i = 0; i < n; i++) {
    final q = p[i], m = (p[i] + p[(i + 1) % n]) / 2;
    path.quadraticBezierTo(q.dx, q.dy, m.dx, m.dy);
  }
  path.close();
}

final _sheets = <String, List<_Pose>>{};

/// The drawn sheet a cat's body comes from: striped coats wear lumi's,
/// plumed tails yuko's, everyone else tsukiko's.
List<_Pose> _sheetFor(CatLook look) {
  final name = look.mark == CatMark.stripes
      ? 'lumi'
      : look.tail == CatTail.bushy
      ? 'yuko'
      : 'tsukiko';
  return _sheets.putIfAbsent(
    name,
    () => [for (final p in tracedSheets[name]!) _Pose(p)],
  );
}

/// The head is drawn this much bigger than the drawn eyes put it: the
/// chibi head of the sheets. The tracer cuts the drawn head out a little
/// wider (tool/cat_trace/trace.py, HK).
const _headScale = 1.1;

const _plug = 0, _base = 1, _shade = 2, _deep = 3, _light = 4, _inkCls = 5;

/// Colours of one frame, derived from the coat.
class _Inks {
  _Inks(this.fur, this.eye, this.ink, this.blush);
  final Color fur, eye, ink, blush;

  /// The line: deep but soft, a muted violet-grey rather than navy, as the
  /// drawings' ink is.
  late final Color outline = () {
    final c = HSLColor.fromColor(Color.lerp(fur, ink, .66)!);
    return c.withSaturation(c.saturation * .72).toColor();
  }();
  late final Color shade = Color.lerp(fur, ink, .14)!;
  late final Color light = Color.lerp(fur, Colors.white, .2)!;
  late final Color deep = Color.lerp(fur, ink, .38)!;

  /// A line of the outline colour.
  Paint line(double width) => Paint()
    ..color = outline
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;

  Color of(int cls, CatLook look) => switch (cls) {
    _shade => shade,
    _deep => look.mark == CatMark.muzzle ? Color.lerp(deep, fur, .3)! : deep,
    _light =>
      look.mark == CatMark.muzzle ? Color.lerp(fur, Colors.white, .55)! : light,
    _inkCls => outline,
    _ => fur,
  };
}

extension on CatPainter {
  /// The whole cat on the floor of [size]: the traced body, the generated
  /// head where the drawn one was, raised paws, signs around the head.
  void _paintFigure(
    Canvas canvas,
    Size size,
    CatFrame f,
    FigureState st,
    CatRig r,
    blob.MotionFrame motion,
    _Inks inks,
  ) {
    final look = profile.look;
    final sheet = _sheetFor(look);
    final a = sheet[st.from.index], b = sheet[st.to.index];
    final t = st.t, time = f.time;
    final kitten = look.size == CatSize.kitten;
    final s = math.min(size.width / 5.0, size.height / 4.3);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + s * 1.95);
    canvas.scale(s * (kitten ? .84 : 1));

    // Floor shadow.
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, .02), width: 3.6, height: .3),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(0, .02),
          1.8,
          [inks.ink.withValues(alpha: .18), inks.ink.withValues(alpha: 0)],
          [.45, 1],
          TileMode.clamp,
          Matrix4.diagonal3Values(1, .3 / 3.6, 1).storage,
        ),
    );

    // Hops, sway and shivers move the whole cat about its feet; it
    // breathes from the floor up.
    final hop = _hop(st, time);
    final squash = (st.squash + hop.$2).clamp(-.25, .25);
    canvas.translate(math.sin(time / 22) * .022 * st[Move.tremble], -hop.$1);
    canvas.rotate(math.sin(time / 820) * .045 * st[Move.sway]);
    final breath = math.sin(time / 650) * .012;
    canvas.scale(1 + squash * .5 - breath * .3, 1 - squash + breath);

    // The tail: an idle sway, faster for a wag, a lash when angry, and
    // now and then a flick.
    final at = time % (profile.twitchEvery * 1.3);
    final flick =
        st[Move.fidget] * (at < 1300 ? math.sin(math.pi * at / 1300) : 0);
    final tail =
        math.sin(time / 900) * .07 +
        math.sin(time / 95) * .16 * st[Move.wag] +
        math.sin(time / 150) * .3 * st[Move.lash] -
        flick * .25;

    if (t >= 1) {
      _paintBody(canvas, b, tail, inks, 1);
    } else {
      // Between poses the outline morphs; the drawn details of the old
      // pose fade out inside it and those of the new one fade in.
      final shape = _morph(a, b, t, tail);
      canvas.drawPath(shape, Paint()..color = inks.fur);
      canvas.save();
      canvas.clipPath(shape);
      _paintBody(canvas, a, tail, inks, 1 - _ease(t * 2), clipped: true);
      _paintBody(canvas, b, tail, inks, _ease(t * 2 - 1), clipped: true);
      canvas.restore();
      canvas.drawPath(
        shape,
        inks.line(.15)
          ..color = inks.outline.withValues(alpha: 1 - _ease((t - .75) * 4)),
      );
    }
    _paintMarks(canvas, b, tail, inks, t);
    _paintCharm(canvas, a, b, t, tail, inks);

    // The head, placed by the drawn eyes and rolled with the drawn tilt.
    final anchor = Offset.lerp(a.head, b.head, t)!;
    final tilt = a.tilt + (b.tilt - a.tilt) * t;
    final bb = profile.layout.body;
    final e = profile.layout.eyes;
    final eyeMid = Offset((e[0].cx + e[1].cx) / 2, (e[0].cy + e[1].cy) / 2);
    canvas.save();
    canvas.translate(anchor.dx, anchor.dy);
    canvas.rotate(tilt);
    canvas.scale(_headScale / bb.rx);
    canvas.translate(-eyeMid.dx, -eyeMid.dy);
    _paintHead(canvas, f, r, motion, inks, chinOpen: .55);
    canvas.restore();

    _paintPaws(canvas, st, anchor, tilt, time, inks);
    _paintEmotes(canvas, st, anchor, time, inks);
    canvas.restore();
  }

  /// The traced layers of one pose at [alpha]. Not [clipped], the plug of
  /// fur under the head and the body's fill go down first.
  void _paintBody(
    Canvas c,
    _Pose p,
    double tail,
    _Inks inks,
    double alpha, {
    bool clipped = false,
  }) {
    if (alpha <= .01) return;
    final look = profile.look;
    for (final cls in [_plug, _base, _shade, _deep, _light, _inkCls]) {
      if (clipped && (cls == _plug || cls == _base)) continue;
      if (!p.layers.containsKey(cls)) continue;
      final color = inks.of(cls, look);
      c.drawPath(
        p.path(cls, tail),
        Paint()..color = color.withValues(alpha: color.a * alpha),
      );
    }
  }

  /// The body outline between two poses: their resampled outlines blended
  /// point by point, the tail turned in both.
  Path _morph(_Pose a, _Pose b, double t, double tail) {
    final n = math.min(a.morph.length, b.morph.length);
    final pts = <Offset>[];
    for (var i = 0; i < n; i++) {
      final (pa, wa) = a.morph[i];
      final (pb, wb) = b.morph[i];
      final qa = a.root == null ? pa : _turn(pa, a.root!, tail * wa);
      final qb = b.root == null ? pb : _turn(pb, b.root!, tail * wb);
      pts.add(Offset.lerp(qa, qb, t)!);
    }
    final path = Path();
    _smooth(path, pts);
    return path;
  }

  (double, double) _hop(FigureState st, double t) {
    final k = st[Move.bounce];
    if (k <= 0) return (0, 0);
    final phase = (t % 1150) / 1150;
    if (phase < .36) {
      final up = math.sin(math.pi * phase / .36);
      return (up * .24 * k, -up * .08 * k);
    }
    if (phase < .5) {
      return (0, math.sin(math.pi * (phase - .36) / .14) * .09 * k);
    }
    return (0, 0);
  }

  /// The body's tail point at weight [w] (0 root, 1 tip), turned with it.
  Offset? _tailPoint(_Pose p, double tail, double w) {
    final r = p.root;
    if (r == null) return null;
    (Offset, double)? best;
    for (final q in p.morph) {
      if (best == null || (q.$2 - w).abs() < (best.$2 - w).abs()) best = q;
    }
    if (best == null || best.$2 < w * .5) return null;
    return _turn(best.$1, r, tail * best.$2);
  }

  /// Marks the drawings don't carry: a patch on the back, stars on the
  /// haunch, a dark or pale tail tip. Clipped to the body.
  void _paintMarks(Canvas c, _Pose p, double tail, _Inks inks, double t) {
    final look = profile.look;
    if (t < .99) return;
    final tipColor = look.mark == CatMark.mask
        ? inks.deep
        : look.tail == CatTail.tipped
        ? (inks.fur.computeLuminance() > .45
              ? inks.deep
              : Color.lerp(inks.fur, Colors.white, .75)!)
        : null;
    final hasMark = look.mark == CatMark.patch || look.mark == CatMark.stars;
    if (tipColor == null && !hasMark) return;
    final body = p.path(_base, tail);
    final bounds = body.getBounds();
    c.save();
    c.clipPath(body);
    if (tipColor != null) {
      final tip = _tailPoint(p, tail, .95);
      if (tip != null) c.drawCircle(tip, .42, Paint()..color = tipColor);
    }
    switch (look.mark) {
      case CatMark.patch:
        final side = profile.traits('cat.mark.side') < .5 ? .35 : .65;
        c.drawOval(
          Rect.fromCenter(
            center: Offset(
              bounds.left + bounds.width * side,
              bounds.top + bounds.height * .35,
            ),
            width: 1.1,
            height: .8,
          ),
          Paint()..color = inks.deep,
        );
      case CatMark.stars:
        final o0 = Offset(
          bounds.left + bounds.width * .7,
          bounds.top + bounds.height * .55,
        );
        for (final (dx, dy, r) in const [(0.0, 0.0, .1), (-.22, .2, .06)]) {
          final o = o0 + Offset(dx, dy);
          final k = r * .25;
          c.drawPath(
            Path()
              ..moveTo(o.dx, o.dy - r)
              ..quadraticBezierTo(o.dx + k, o.dy - k, o.dx + r, o.dy)
              ..quadraticBezierTo(o.dx + k, o.dy + k, o.dx, o.dy + r)
              ..quadraticBezierTo(o.dx - k, o.dy + k, o.dx - r, o.dy)
              ..quadraticBezierTo(o.dx - k, o.dy - k, o.dx, o.dy - r)
              ..close(),
            Paint()..color = const Color(0xfffbeec4),
          );
        }
      default:
        break;
    }
    c.restore();
    // The ink goes back over what was laid on the fur.
    c.drawPath(p.path(_inkCls, tail), Paint()..color = inks.outline);
  }

  /// What the cat wears on its body: one thing at most.
  void _paintCharm(
    Canvas c,
    _Pose a,
    _Pose b,
    double t,
    double tail,
    _Inks inks,
  ) {
    final look = profile.look;
    final head = Offset.lerp(a.head, b.head, t)!;
    final chin = head + const Offset(0, .86);
    const lw = .08;
    switch (look.charm) {
      case CatCharm.none:
        return;
      case CatCharm.collar:
        final band = Path()
          ..moveTo(chin.dx - .55, chin.dy - .12)
          ..quadraticBezierTo(
            chin.dx,
            chin.dy + .24,
            chin.dx + .55,
            chin.dy - .12,
          );
        c.drawPath(band, inks.line(.16 + lw * 2));
        c.drawPath(
          band,
          Paint()
            ..color = inks.blush
            ..style = PaintingStyle.stroke
            ..strokeWidth = .16
            ..strokeCap = StrokeCap.round,
        );
        final bell = chin + const Offset(0, .16);
        c.drawCircle(bell, .12 + lw, Paint()..color = inks.outline);
        c.drawCircle(bell, .12, Paint()..color = const Color(0xfff6cf5a));
        c.drawCircle(
          bell + const Offset(-.04, -.04),
          .035,
          Paint()..color = const Color(0xfffff6d8),
        );
      case CatCharm.scarf:
        final cloth = Color.lerp(inks.blush, inks.fur, .25)!;
        final band = Path()
          ..moveTo(chin.dx - .62, chin.dy - .14)
          ..quadraticBezierTo(
            chin.dx,
            chin.dy + .3,
            chin.dx + .62,
            chin.dy - .14,
          );
        final end = Path()
          ..moveTo(chin.dx + .18, chin.dy + .04)
          ..quadraticBezierTo(
            chin.dx + .4,
            chin.dy + .3,
            chin.dx + .34,
            chin.dy + .62,
          )
          ..lineTo(chin.dx + .56, chin.dy + .58)
          ..quadraticBezierTo(
            chin.dx + .56,
            chin.dy + .22,
            chin.dx + .4,
            chin.dy,
          )
          ..close();
        c.drawPath(end, inks.line(lw * 2));
        c.drawPath(band, inks.line(.28 + lw * 2));
        c.drawPath(end, Paint()..color = cloth);
        c.drawPath(
          band,
          Paint()
            ..color = cloth
            ..style = PaintingStyle.stroke
            ..strokeWidth = .28
            ..strokeCap = StrokeCap.round,
        );
      case CatCharm.ribbon:
        final at = _tailPoint(t < .5 ? a : b, tail, .55);
        if (at == null) return;
        c.save();
        c.translate(at.dx, at.dy);
        final bow = Path();
        for (final d in [-1.0, 1.0]) {
          bow
            ..moveTo(0, 0)
            ..quadraticBezierTo(d * .14, -.22, d * .3, -.12)
            ..quadraticBezierTo(d * .36, 0, d * .3, .12)
            ..quadraticBezierTo(d * .14, .22, 0, 0);
        }
        c.drawPath(bow, inks.line(lw * 1.6));
        c.drawPath(bow, Paint()..color = inks.blush);
        c.drawCircle(Offset.zero, .08 + lw * .6, Paint()..color = inks.outline);
        c.drawCircle(
          Offset.zero,
          .08,
          Paint()..color = Color.lerp(inks.blush, Colors.white, .4)!,
        );
        c.restore();
    }
  }

  /// Paws raised over the face: soft mittens with their toes on top, a
  /// short arm under each running down into the chest.
  void _paintPaws(
    Canvas c,
    FigureState st,
    Offset head,
    double tilt,
    double time,
    _Inks inks,
  ) {
    if (st.paws == Paws.none || st.pawsIn <= .01) return;
    final k = st.pawsIn;
    final spots = switch (st.paws) {
      Paws.none => const <(Offset, double)>[],
      Paws.chin => const [(Offset(.42, .78), -.3)],
      Paws.clasp => const [(Offset(-.17, .86), .35), (Offset(.17, .86), -.35)],
      Paws.cheeks => const [
        (Offset(-1.02, .42), .45),
        (Offset(1.02, .42), -.45),
      ],
      Paws.wave => [(Offset(1.35 + math.sin(time / 170) * .12, .05), -.2)],
    };
    for (final (rel, turn) in spots) {
      // Paws rise from the chest as they come in.
      final at = head + _turn(rel, Offset.zero, tilt) + Offset(0, (1 - k) * .9);
      c.save();
      c.translate(at.dx, at.dy);
      c.rotate(turn);
      c.translate(-at.dx, -at.dy);
      final arm = Path()
        ..moveTo(at.dx - .13, at.dy)
        ..lineTo(at.dx - .15, at.dy + .55)
        ..lineTo(at.dx + .15, at.dy + .55)
        ..lineTo(at.dx + .13, at.dy)
        ..close();
      c.drawPath(arm, Paint()..color = inks.fur.withValues(alpha: k));
      final side = inks.line(.06)..color = inks.outline.withValues(alpha: k);
      c.drawLine(
        at + const Offset(-.14, .05),
        at + const Offset(-.15, .5),
        side,
      );
      c.drawLine(at + const Offset(.14, .05), at + const Offset(.15, .5), side);
      final foot = Rect.fromCenter(center: at, width: .4, height: .3);
      c.drawOval(
        foot.inflate(.04),
        Paint()..color = inks.outline.withValues(alpha: k),
      );
      c.drawOval(
        foot,
        Paint()
          ..color = Color.lerp(
            inks.fur,
            Colors.white,
            .08,
          )!.withValues(alpha: k),
      );
      for (final x in const [-.08, 0.0, .08]) {
        c.drawLine(at + Offset(x, -.15), at + Offset(x, -.09), side);
      }
      c.restore();
    }
  }

  /// The little drawn signs: lines of excitement, hearts, sleep, a question,
  /// thinking dots, a sweat drop, a cross vein.
  void _paintEmotes(
    Canvas c,
    FigureState st,
    Offset head,
    double t,
    _Inks inks,
  ) {
    final at = head + const Offset(1.42, -1.2);
    final ink = inks.outline;

    final dashes = st.emoteOf(Emote.dashes);
    if (dashes > .02) {
      final pulse = .85 + .15 * math.sin(t / 160);
      final paint = inks.line(.07)
        ..color = ink.withValues(alpha: dashes.clamp(0.0, 1.0));
      for (final a in const [-1.15, -.6, -.05]) {
        final dir = Offset(math.cos(a), math.sin(a));
        c.drawLine(
          at + dir * (.2 * pulse),
          at + dir * (.2 + .2 * pulse * dashes),
          paint,
        );
      }
    }

    final hearts = st.emoteOf(Emote.hearts);
    if (hearts > .02) {
      for (var k = 0; k < 2; k++) {
        final phase = ((t / 2600) + k * .5) % 1;
        final o =
            at +
            Offset(math.sin(phase * 6 + k) * .12 + k * .25, -phase * .9 + .2);
        _heart(c, o, .13 + .05 * k, inks, math.sin(math.pi * phase) * hearts);
      }
    }

    final zzz = st.emoteOf(Emote.zzz);
    if (zzz > .02) {
      for (var k = 0; k < 3; k++) {
        final phase = ((t / 3200) + k / 3) % 1;
        final size = .1 + .1 * phase;
        final o = head + Offset(.95 + phase * .7, -1.35 - phase * .8);
        final a = (math.sin(math.pi * phase) * zzz).clamp(0.0, 1.0);
        c.drawPath(
          Path()
            ..moveTo(o.dx - size, o.dy - size)
            ..lineTo(o.dx + size, o.dy - size)
            ..lineTo(o.dx - size, o.dy + size)
            ..lineTo(o.dx + size, o.dy + size),
          inks.line(.055)..color = ink.withValues(alpha: a),
        );
      }
    }

    final question = st.emoteOf(Emote.question);
    if (question > .02) {
      final o = at + Offset(0, math.sin(t / 420) * .06);
      final a = question.clamp(0.0, 1.0);
      c.drawPath(
        Path()
          ..moveTo(o.dx - .14, o.dy - .2)
          ..quadraticBezierTo(o.dx - .12, o.dy - .38, o.dx + .02, o.dy - .38)
          ..quadraticBezierTo(o.dx + .18, o.dy - .36, o.dx + .16, o.dy - .2)
          ..quadraticBezierTo(o.dx + .14, o.dy - .08, o.dx + .02, o.dy - .02)
          ..lineTo(o.dx + .02, o.dy + .06),
        inks.line(.085)..color = ink.withValues(alpha: a),
      );
      c.drawCircle(
        o + const Offset(.02, .2),
        .055,
        Paint()..color = ink.withValues(alpha: a),
      );
    }

    final dots = st.emoteOf(Emote.dots);
    if (dots > .02) {
      final step = (t / 380).floor() % 4;
      for (var k = 0; k < step && k < 3; k++) {
        c.drawCircle(
          at + Offset(k * .17 - .05, .12 - k * .06),
          .05,
          Paint()..color = ink.withValues(alpha: dots.clamp(0.0, 1.0)),
        );
      }
    }

    final sweat = st.emoteOf(Emote.sweat);
    if (sweat > .02) {
      final phase = (t / 1800) % 1;
      final o = head + Offset(-1.15, -.85 + phase * .25);
      final a = (math.sin(math.pi * phase) * 1.4).clamp(0.0, 1.0) * sweat;
      final drop = Path()
        ..moveTo(o.dx, o.dy - .2)
        ..quadraticBezierTo(o.dx + .12, o.dy - .02, o.dx + .1, o.dy + .06)
        ..arcToPoint(
          Offset(o.dx - .1, o.dy + .06),
          radius: const Radius.circular(.1),
        )
        ..quadraticBezierTo(o.dx - .12, o.dy - .02, o.dx, o.dy - .2)
        ..close();
      c.drawPath(drop, inks.line(.1)..color = ink.withValues(alpha: a));
      c.drawPath(
        drop,
        Paint()..color = const Color(0xffbfe4fb).withValues(alpha: a),
      );
    }

    final anger = st.emoteOf(Emote.anger);
    if (anger > .02) {
      final pulse = 1 + .12 * math.sin(t / 120);
      final paint = Paint()
        ..color = const Color(0xffe8506e).withValues(alpha: anger.clamp(0, 1))
        ..style = PaintingStyle.stroke
        ..strokeWidth = .07
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < 4; k++) {
        final a = k * math.pi / 2 + math.pi / 4;
        final dir = Offset(math.cos(a), math.sin(a));
        final normal = Offset(-dir.dy, dir.dx);
        final mid = at + dir * (.14 * pulse);
        c.drawPath(
          Path()
            ..moveTo(mid.dx + normal.dx * .09, mid.dy + normal.dy * .09)
            ..quadraticBezierTo(
              at.dx + dir.dx * .05,
              at.dy + dir.dy * .05,
              mid.dx - normal.dx * .09,
              mid.dy - normal.dy * .09,
            ),
          paint,
        );
      }
    }
  }

  void _heart(Canvas c, Offset o, double r, _Inks inks, double alpha) {
    if (alpha <= .01) return;
    final h = Path()
      ..moveTo(o.dx, o.dy + r)
      ..cubicTo(
        o.dx - r * 1.6,
        o.dy - r * .2,
        o.dx - r * .7,
        o.dy - r * 1.3,
        o.dx,
        o.dy - r * .45,
      )
      ..cubicTo(
        o.dx + r * .7,
        o.dy - r * 1.3,
        o.dx + r * 1.6,
        o.dy - r * .2,
        o.dx,
        o.dy + r,
      )
      ..close();
    c.drawPath(
      h,
      inks.line(.07)..color = inks.outline.withValues(alpha: alpha),
    );
    c.drawPath(h, Paint()..color = inks.blush.withValues(alpha: alpha));
  }
}

/// A faint grain of light and dark specks in unit space, recorded once:
/// laid over the fills it takes the vector flatness off, as paper and a
/// soft brush do in the drawings.
final ui.Picture _grain = () {
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  final rnd = math.Random(7);
  final light = Paint()..color = const Color(0x0cffffff);
  final dark = Paint()..color = const Color(0x061c1730);
  for (var i = 0; i < 1400; i++) {
    final at = Offset(
      rnd.nextDouble() * 6.4 - 3.2,
      rnd.nextDouble() * 5.4 - 4.8,
    );
    c.drawCircle(at, .008 + rnd.nextDouble() * .016, i % 4 == 0 ? dark : light);
  }
  return r.endRecording();
}();

/// Soft painted tone: large blurred patches a few percent lighter or darker,
/// recorded once per kind. Lighter ones gather where the light falls (up
/// and left), darker ones towards the shade (down and right), so they read
/// as painting rather than smudges. [face] keeps darker patches out of the
/// middle of the face and halves the strength; [soft] scales it down for
/// grey coats, where tone reads as dust.
final _tones = <(bool, bool), ui.Picture>{};
ui.Picture _tone({bool face = false, bool soft = false}) =>
    _tones.putIfAbsent((face, soft), () {
      final r = ui.PictureRecorder();
      final c = Canvas(r);
      final rnd = math.Random(11);
      final k = (face ? .6 : 1.0) * (soft ? .7 : 1.0);
      // Face patches live in head units around the head's centre; body
      // patches in floor units round the middle of a sitting cat.
      final centre = face ? Offset.zero : const Offset(.3, -1.6);
      for (var i = 0; i < 46; i++) {
        final at =
            centre +
            Offset(rnd.nextDouble() * 4.4 - 2.2, rnd.nextDouble() * 4.0 - 2.0);
        final radius = .3 + rnd.nextDouble() * .45;
        final rel = at - centre;
        final lit = rel.dx + rel.dy < 0;
        if (face && !lit && rel.distance < .7) continue;
        final color = lit
            ? Color.fromRGBO(255, 255, 255, .07 * k)
            : Color.fromRGBO(28, 23, 48, .055 * k);
        c.drawCircle(
          at,
          radius,
          Paint()
            ..shader = ui.Gradient.radial(at, radius, [
              color,
              color.withValues(alpha: 0),
            ]),
        );
      }
      return r.endRecording();
    });
