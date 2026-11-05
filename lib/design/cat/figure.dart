part of 'cat.dart';

// The whole cat, after the drawn sheets (tsukiko, lumi, yuko): a big head on
// a small soft body, everything inked with one dark line whose lower edge is
// a touch heavier, fur that breaks the line into little tufts, a paler chest
// and a darker far side. Nothing here is a picture: every part is a few
// numbers in [BodyPose], and moods only move those numbers.
//
// Units are head widths: 1 is half the head's width (Blobatar's `rx`), the
// origin is the floor under the cat, y grows downward.

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
  late final Color shade = Color.lerp(fur, ink, .13)!;
  late final Color light = Color.lerp(fur, Colors.white, .2)!;
  late final Color deep = Color.lerp(fur, ink, .38)!;

  /// A line of the outline colour. Painted under the fill, so half of it
  /// shows.
  Paint line(double width) => Paint()
    ..color = outline
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
}

/// Movements a mood keeps going on top of its pose. Each is an amplitude in
/// the pose, so it fades in and out with the pose instead of switching.
enum Move {
  /// Quick happy tail.
  wag,

  /// A paw tapping the chin.
  tap,

  /// A paw waving hello.
  wave,

  /// Little hops on the spot.
  bounce,

  /// Fine shivers.
  tremble,

  /// Rocking side to side.
  sway,

  /// An angry tail whipping.
  lash,

  /// Small business while nothing happens: steps, kneads, flicks.
  fidget,
}

/// Little drawn signs around the head.
enum Emote { dashes, hearts, zzz, question, dots, sweat, anger }

/// Everything that places the body, as plain numbers. Two poses blend
/// point by point, so a sitting cat can lie down or stand up through every
/// shape in between.
class BodyPose {
  const BodyPose({
    required this.head,
    this.headTilt = 0,
    required this.torso,
    required this.haunch,
    required this.legs,
    this.front = const [1, 1, 1, 1],
    this.over = const [0, 0],
    this.shade = const [0, 0, 0, 0],
    required this.tail,
    this.tailFront = 0,
    this.puff = 0,
    this.chest = 1,
    this.merge = 1,
    this.shadow = const Offset(.1, 2.5),
    this.emote = const [0, 0, 0, 0, 0, 0, 0],
    this.move = const [0, 0, 0, 0, 0, 0, 0, 0],
    this.squash = 0,
  });

  /// Centre of the head (Blobatar's body centre) and its roll in radians.
  final Offset head;
  final double headTilt;

  /// Eight points of a closed smooth loop, clockwise from the neck's left:
  /// left shoulder, left side, left hip, floor left, floor right, right hip,
  /// right side, right shoulder.
  final List<Offset> torso;

  /// Centre and radii of the left and the right thigh.
  final List<Offset> haunch;

  /// Root and paw of the front left, front right, back left, back right leg.
  final List<Offset> legs;

  /// Per leg: 1 in front of the body, 0 behind it.
  final List<double> front;

  /// Per front paw: 1 when it is raised over the face. It goes over only
  /// once nearly there, so a paw on its way never crosses the eyes.
  final List<double> over;

  /// Per leg: 1 for the far side, a shade darker.
  final List<double> shade;

  /// The tail as five points from root to tip; a smooth curve runs
  /// through them. Poses blend these points directly, so between two poses
  /// the tail moves straight to its new place instead of swinging round.
  final List<Offset> tail;

  /// 1 when the tail lies in front of the body, wrapped round the paws.
  final double tailFront;

  /// Fur standing up on the tail.
  final double puff;

  /// How much of the pale chest shows.
  final double chest;

  /// 1 when head and body share one outline (sitting, the chin sunk into the
  /// chest fur); 0 when the head is drawn in front of the body.
  final double merge;

  /// Centre x and width of the floor shadow.
  final Offset shadow;

  /// Amplitudes per [Emote] and per [Move].
  final List<double> emote, move;

  /// Squash and stretch: positive is squashed. Rests at 0; a change of
  /// pose kicks it.
  final double squash;

  double operator [](Move m) => move[m.index];
  double emoteOf(Emote e) => emote[e.index];

  BodyPose copyWith({
    Offset? head,
    double? headTilt,
    List<Offset>? torso,
    List<Offset>? haunch,
    List<Offset>? legs,
    List<double>? front,
    List<double>? over,
    List<double>? shade,
    List<Offset>? tail,
    double? tailFront,
    double? puff,
    double? chest,
    double? merge,
    Offset? shadow,
    Map<Emote, double> emotes = const {},
    Map<Move, double> moves = const {},
  }) => BodyPose(
    head: head ?? this.head,
    headTilt: headTilt ?? this.headTilt,
    torso: torso ?? this.torso,
    haunch: haunch ?? this.haunch,
    legs: legs ?? this.legs,
    front: front ?? this.front,
    over: over ?? this.over,
    shade: shade ?? this.shade,
    tail: tail ?? this.tail,
    tailFront: tailFront ?? this.tailFront,
    puff: puff ?? this.puff,
    chest: chest ?? this.chest,
    merge: merge ?? this.merge,
    shadow: shadow ?? this.shadow,
    emote: [for (final e in Emote.values) emotes[e] ?? emote[e.index]],
    move: [for (final m in Move.values) moves[m] ?? move[m.index]],
    squash: squash,
  );

  /// The same pose with one leg moved.
  BodyPose withLeg(int leg, Offset root, Offset paw, {double? over}) {
    final next = [...legs];
    next[leg * 2] = root;
    next[leg * 2 + 1] = paw;
    final o = [...this.over];
    if (over != null && leg < 2) o[leg] = over;
    return copyWith(legs: next, over: o);
  }

  // Flattened: the spring works on one list of numbers. [_springs] holds
  // how fast each number follows, so the head leads, the body follows
  // and the tail trails behind.
  void _write(void Function(double value, double omega, double zeta) w) {
    void p(Offset o, double omega, [double zeta = .8]) {
      w(o.dx, omega, zeta);
      w(o.dy, omega, zeta);
    }

    p(head, 6);
    w(headTilt, 6, .75);
    for (final o in torso) {
      p(o, 4.2);
    }
    for (final o in haunch) {
      p(o, 4.2);
    }
    for (final o in legs) {
      p(o, 6.5, .8);
    }
    for (final v in [...front, ...over, ...shade]) {
      w(v, 10, 1);
    }
    for (final o in tail) {
      p(o, 6, .75);
    }
    w(tailFront, 8, 1);
    w(puff, 9, .7);
    w(chest, 12, 1);
    w(merge, 9, 1);
    p(shadow, 7.5, 1);
    for (final v in emote) {
      w(v, 11, 1);
    }
    for (final v in move) {
      w(v, 6, 1);
    }
    w(squash, 15, .32);
  }

  List<double> flat() {
    final out = <double>[];
    _write((v, _, _) => out.add(v));
    return out;
  }

  static final List<(double, double)> _springs = () {
    final out = <(double, double)>[];
    sit._write((_, omega, zeta) => out.add((omega, zeta)));
    return out;
  }();

  factory BodyPose.unflat(List<double> v) {
    var i = 0;
    double n() => v[i++];
    Offset o() => Offset(n(), n());
    List<Offset> os(int count) => [for (var k = 0; k < count; k++) o()];
    List<double> ns(int count) => [for (var k = 0; k < count; k++) n()];
    return BodyPose(
      head: o(),
      headTilt: n(),
      torso: os(8),
      haunch: os(4),
      legs: os(8),
      front: ns(4),
      over: ns(2),
      shade: ns(4),
      tail: os(5),
      tailFront: n(),
      puff: n(),
      chest: n(),
      merge: n(),
      shadow: o(),
      emote: ns(Emote.values.length),
      move: ns(Move.values.length),
      squash: n(),
    );
  }

  // The six drawn poses. Everything else is one of these with a paw, the
  // tail or the head moved.

  /// Sitting upright, paws together, tail curling up behind.
  static const sit = BodyPose(
    head: Offset(-.1, -2.56),
    torso: [
      Offset(-.66, -1.95),
      Offset(-.8, -1.2),
      Offset(-.98, -.45),
      Offset(-.74, 0),
      Offset(.86, 0),
      Offset(1.14, -.55),
      Offset(.86, -1.25),
      Offset(.5, -1.97),
    ],
    haunch: [
      Offset(-.62, -.38),
      Offset(.4, .38),
      Offset(.75, -.6),
      Offset(.55, .55),
    ],
    legs: [
      Offset(-.31, -1.0),
      Offset(-.38, -.08),
      Offset(.09, -1.0),
      Offset(.16, -.08),
      Offset(-.8, -.2),
      Offset(-.94, -.1),
      Offset(.98, -.2),
      Offset(1.12, -.1),
    ],
    tail: [
      Offset(1.0, -.15),
      Offset(1.7, -.35),
      Offset(2.0, -.85),
      Offset(1.85, -1.35),
      Offset(1.55, -1.6),
    ],
    shadow: Offset(.2, 2.9),
  );

  /// Lying hunched, chin on the paws, tail along the floor in front.
  static const hunch = BodyPose(
    head: Offset(-.5, -1.48),
    headTilt: .04,
    torso: [
      Offset(-.5, -1.72),
      Offset(-1.0, -1.15),
      Offset(-1.02, -.4),
      Offset(-.72, 0),
      Offset(1.15, 0),
      Offset(1.62, -.45),
      Offset(1.42, -1.36),
      Offset(.5, -1.76),
    ],
    haunch: [
      Offset(.95, -.5),
      Offset(.3, .3),
      Offset(1.1, -.58),
      Offset(.56, .54),
    ],
    legs: [
      Offset(-.74, -.34),
      Offset(-.76, -.11),
      Offset(-.24, -.34),
      Offset(-.2, -.11),
      Offset(1.0, -.2),
      Offset(.95, -.1),
      Offset(1.2, -.26),
      Offset(1.36, -.1),
    ],
    front: [1, 1, 0, 1],
    over: [1, 1],
    tail: [
      Offset(1.45, -.32),
      Offset(1.2, -.16),
      Offset(.6, -.15),
      Offset(.05, -.16),
      Offset(-.15, -.42),
    ],
    tailFront: 1,
    merge: 0,
    chest: 0,
    shadow: Offset(.4, 3.5),
  );

  /// Lying as a loaf, head up and alert.
  static final loaf = hunch.copyWith(
    head: const Offset(-.45, -1.66),
    headTilt: 0,
    torso: const [
      Offset(-.45, -1.62),
      Offset(-1.0, -1.1),
      Offset(-1.04, -.38),
      Offset(-.72, 0),
      Offset(1.3, 0),
      Offset(1.82, -.46),
      Offset(1.6, -1.28),
      Offset(.55, -1.66),
    ],
    haunch: const [
      Offset(.92, -.55),
      Offset(.3, .3),
      Offset(1.08, -.62),
      Offset(.58, .56),
    ],
    tail: const [
      Offset(1.5, -.32),
      Offset(1.25, -.16),
      Offset(.65, -.15),
      Offset(.1, -.16),
      Offset(-.08, -.44),
    ],
    chest: 0,
  );

  /// Curled up asleep, head resting on a paw, tail wrapped round.
  static const curl = BodyPose(
    head: Offset(-.94, -1.12),
    headTilt: -.36,
    torso: [
      Offset(-.65, -1.55),
      Offset(-1.3, -.95),
      Offset(-1.3, -.3),
      Offset(-.95, 0),
      Offset(1.4, 0),
      Offset(2, -.48),
      Offset(1.8, -1.45),
      Offset(.8, -1.86),
    ],
    haunch: [
      Offset(1.1, -.5),
      Offset(.3, .3),
      Offset(1.25, -.62),
      Offset(.62, .6),
    ],
    legs: [
      Offset(-.82, -.32),
      Offset(-.86, -.11),
      Offset(-.4, -.3),
      Offset(-.35, -.11),
      Offset(1.1, -.2),
      Offset(1.05, -.1),
      Offset(1.35, -.26),
      Offset(1.5, -.1),
    ],
    front: [1, 0, 0, 0],
    over: [1, 0],
    tail: [
      Offset(1.7, -.32),
      Offset(1.35, -.16),
      Offset(.3, -.15),
      Offset(-.3, -.17),
      Offset(-.55, -.36),
    ],
    tailFront: 1,
    merge: 0,
    chest: 0,
    shadow: Offset(.25, 3.5),
  );

  /// Standing on all four, head turned to us, tail up.
  static const prowl = BodyPose(
    head: Offset(-1.1, -1.55),
    headTilt: -.14,
    torso: [
      Offset(-.55, -1.9),
      Offset(-1.05, -1.25),
      Offset(-.9, -.6),
      Offset(0, -.64),
      Offset(.95, -.68),
      Offset(1.6, -.98),
      Offset(1.64, -1.7),
      Offset(.5, -1.84),
    ],
    haunch: [
      Offset(.9, -1.1),
      Offset(.34, .36),
      Offset(1.15, -1.12),
      Offset(.48, .48),
    ],
    legs: [
      Offset(-.7, -1.0),
      Offset(-1.26, -.12),
      Offset(-.4, -.96),
      Offset(-.84, -.12),
      Offset(.86, -.98),
      Offset(.44, -.12),
      Offset(1.2, -1.0),
      Offset(1.32, -.12),
    ],
    front: [0, 1, 0, 1],
    shade: [1, 0, 1, 0],
    tail: [
      Offset(1.5, -1.42),
      Offset(1.88, -1.85),
      Offset(1.95, -2.45),
      Offset(1.78, -2.88),
      Offset(1.5, -2.95),
    ],
    merge: 0,
    chest: 0,
    shadow: Offset(.1, 3.5),
  );

  /// Each mood's own pose: one of the drawn poses with its paws, tail and
  /// head placed for the feeling, and the movements it keeps going.
  static BodyPose forMood(CatMood mood) => switch (mood) {
    CatMood.idle => sit.copyWith(moves: {Move.fidget: 1}),
    CatMood.listening => sit.copyWith(
      head: const Offset(-.1, -2.7),
      tail: [
        Offset(1.0, -.18),
        Offset(1.5, -.55),
        Offset(1.66, -1.25),
        Offset(1.6, -1.95),
        Offset(1.38, -2.3),
      ],
      moves: {Move.wag: .15},
    ),
    // A paw to the chin.
    CatMood.thinking =>
      sit
          .withLeg(1, const Offset(.2, -1.1), const Offset(.36, -1.8), over: 1)
          .copyWith(emotes: {Emote.dots: 1}, moves: {Move.tap: 1}),
    CatMood.happy => sit.copyWith(
      head: const Offset(-.1, -2.72),
      tail: [
        Offset(1.0, -.18),
        Offset(1.55, -.5),
        Offset(1.78, -1.2),
        Offset(1.68, -1.85),
        Offset(1.35, -2.12),
      ],
      emotes: {Emote.dashes: 1},
      moves: {Move.wag: .8, Move.bounce: .6},
    ),
    CatMood.love =>
      sit
          .withLeg(
            0,
            const Offset(-.38, -1.0),
            const Offset(-.22, -1.46),
            over: 1,
          )
          .withLeg(
            1,
            const Offset(.18, -1.0),
            const Offset(.02, -1.52),
            over: 1,
          )
          .copyWith(
            tail: [
              Offset(1.0, -.18),
              Offset(1.6, -.45),
              Offset(1.85, -1.05),
              Offset(1.62, -1.55),
              Offset(1.3, -1.45),
            ],
            emotes: {Emote.hearts: 1},
            moves: {Move.sway: .7, Move.wag: .3},
          ),
    // Waves a paw by the face.
    CatMood.wink =>
      sit
          .withLeg(
            1,
            const Offset(.2, -1.32),
            const Offset(.88, -2.25),
            over: 1,
          )
          .copyWith(
            head: const Offset(-.14, -2.66),
            tail: [
              Offset(1.0, -.18),
              Offset(1.55, -.5),
              Offset(1.78, -1.2),
              Offset(1.68, -1.85),
              Offset(1.35, -2.12),
            ],
            moves: {Move.wave: 1, Move.wag: .4},
          ),
    // Tail wrapped round the front paws.
    CatMood.smug => sit.copyWith(
      head: const Offset(-.1, -2.66),
      tail: const [
        Offset(.95, -.18),
        Offset(.55, -.15),
        Offset(-.05, -.15),
        Offset(-.6, -.16),
        Offset(-.85, -.38),
      ],
      tailFront: 1,
      moves: {Move.wag: .12},
    ),
    // Paws over the cheeks.
    CatMood.shy =>
      sit
          .withLeg(
            0,
            const Offset(-.4, -1.3),
            const Offset(-.96, -1.94),
            over: 1,
          )
          .withLeg(1, const Offset(.2, -1.3), const Offset(.76, -1.94), over: 1)
          .copyWith(
            head: const Offset(-.1, -2.54),
            tail: const [
              Offset(.95, -.18),
              Offset(.55, -.15),
              Offset(0, -.15),
              Offset(-.5, -.16),
              Offset(-.72, -.36),
            ],
            tailFront: 1,
            moves: {Move.sway: .4},
          ),
    // Pressed low, tail tucked, shivering.
    CatMood.scared => sit.copyWith(
      head: const Offset(-.1, -2.08),
      torso: [for (final p in sit.torso) Offset(p.dx * 1.12, p.dy * .8)],
      legs: [
        for (final (i, p) in sit.legs.indexed)
          i.isEven ? Offset(p.dx * 1.1, p.dy * .76) : p,
      ],
      tail: const [
        Offset(.95, -.18),
        Offset(.6, -.15),
        Offset(.1, -.15),
        Offset(-.35, -.17),
        Offset(-.55, -.35),
      ],
      tailFront: 1,
      puff: .2,
      emotes: {Emote.sweat: 1},
      moves: {Move.tremble: 1},
    ),
    CatMood.sad => hunch,
    // Flat on the floor, shivering a little.
    CatMood.sick => curl.copyWith(
      head: const Offset(-.62, -1.34),
      headTilt: .08,
      front: const [1, 1, 0, 0],
      emotes: {Emote.sweat: .8},
      moves: {Move.tremble: .35},
    ),
    CatMood.sleepy => curl.copyWith(emotes: {Emote.zzz: 1}),
    CatMood.unsure => loaf.copyWith(
      emotes: {Emote.question: 1},
      moves: {Move.sway: .5},
    ),
    CatMood.surprised => prowl.copyWith(emotes: {Emote.dashes: 1}),
    // Back up in an arch, tail straight up and bristling.
    CatMood.mad => prowl.copyWith(
      head: const Offset(-1.02, -1.5),
      torso: const [
        Offset(-.5, -1.85),
        Offset(-1.05, -1.25),
        Offset(-.78, -.62),
        Offset(0, -.64),
        Offset(.95, -.58),
        Offset(1.48, -.95),
        Offset(1.42, -1.85),
        Offset(.4, -2.4),
      ],
      tail: const [
        Offset(1.35, -1.75),
        Offset(1.45, -2.25),
        Offset(1.5, -2.75),
        Offset(1.5, -3.15),
        Offset(1.42, -3.4),
      ],
      puff: 1,
      emotes: {Emote.anger: 1},
      moves: {Move.lash: 1},
    ),
  };
}

/// The body pose in motion: every number chases the mood's pose on its own
/// spring. Heads arrive first and tails last, a change of pose squashes
/// the body for a beat, and paws on the move lift off the floor.
class BodySpring {
  BodySpring(BodyPose pose)
    : _x = pose.flat(),
      _v = List.filled(pose.flat().length, 0),
      _target = pose.flat();

  final List<double> _x, _v;
  List<double> _target;
  static const _paws = [1, 3, 5, 7];
  late final int _legsAt = () {
    // Index of the first leg number in the flat list.
    var i = 0;
    i += 2 + 1 + 16 + 8;
    return i;
  }();

  /// Turns towards [pose]; a real change of pose kicks the squash.
  void aim(BodyPose pose, {double kick = 1}) {
    final next = pose.flat();
    var moved = 0.0;
    for (var i = 0; i < next.length; i++) {
      moved += (next[i] - _target[i]).abs();
    }
    _target = next;
    if (moved > .5) _v[_v.length - 1] += 2.4 * kick;
  }

  /// A poke: a quick squash and bounce back.
  void poke() => _v[_v.length - 1] += 3.2;

  void snap() {
    for (var i = 0; i < _x.length; i++) {
      _x[i] = _target[i];
      _v[i] = 0;
    }
  }

  void step(double ms) {
    var left = ms / 1000;
    const h = 1 / 240;
    final springs = BodyPose._springs;
    while (left > 0) {
      final dt = math.min(h, left);
      left -= dt;
      for (var i = 0; i < _x.length; i++) {
        final (w, z) = springs[i];
        final a = -2 * z * w * _v[i] - w * w * (_x[i] - _target[i]);
        _v[i] += a * dt;
        _x[i] += _v[i] * dt;
      }
    }
  }

  BodyPose get pose {
    final x = [..._x];
    // A paw on the move rises by how fast it goes, so it steps instead of
    // sliding.
    for (final p in _paws) {
      final i = _legsAt + p * 2;
      final speed = math.sqrt(_v[i] * _v[i] + _v[i + 1] * _v[i + 1]);
      x[i + 1] -= math.min(.32, speed * .09);
      // A front paw on its way stays behind the face until it arrives.
      if (p < 4 && speed > .6) x[_legsAt + 16 + 4 + p ~/ 2] = 0;
    }
    return BodyPose.unflat(x);
  }
}

/// Piecewise-linear value at [u] (0…1) through evenly spaced [v].
double _along(List<double> v, double u) {
  final x = u.clamp(0.0, 1.0) * (v.length - 1);
  final k = math.min(x.floor(), v.length - 2);
  return v[k] + (v[k + 1] - v[k]) * (x - k);
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

/// Smoothstep on 0…1, clamped.
double _ease(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// A closed loop through [p], as a smooth Catmull-Rom curve.
Path _loop(List<Offset> p) {
  final n = p.length;
  final path = Path()..moveTo(p[0].dx, p[0].dy);
  for (var i = 0; i < n; i++) {
    final p0 = p[(i - 1 + n) % n], p1 = p[i];
    final p2 = p[(i + 1) % n], p3 = p[(i + 2) % n];
    final c1 = p1 + (p2 - p0) / 6, c2 = p2 - (p3 - p1) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path..close();
}

/// A limb: two round ends joined by their common tangents.
Path _capsule(Offset a, double ra, Offset b, double rb) {
  final d = b - a;
  final len = d.distance;
  if (len < 1e-3) {
    return Path()
      ..addOval(Rect.fromCircle(center: a, radius: math.max(ra, rb)));
  }
  final ang = math.atan2(d.dy, d.dx);
  final n = Offset(-d.dy, d.dx) / len;
  return Path()
    ..moveTo(a.dx + n.dx * ra, a.dy + n.dy * ra)
    ..lineTo(b.dx + n.dx * rb, b.dy + n.dy * rb)
    ..arcTo(
      Rect.fromCircle(center: b, radius: rb),
      ang + math.pi / 2,
      -math.pi,
      false,
    )
    ..lineTo(a.dx - n.dx * ra, a.dy - n.dy * ra)
    ..arcTo(
      Rect.fromCircle(center: a, radius: ra),
      ang - math.pi / 2,
      -math.pi,
      false,
    )
    ..close();
}

/// Smooth open line through [p] by midpoints.
void _through(Path path, List<Offset> p, {bool start = true}) {
  if (start) {
    path.moveTo(p[0].dx, p[0].dy);
  } else {
    path.lineTo(p[0].dx, p[0].dy);
  }
  for (var i = 1; i < p.length - 1; i++) {
    final m = (p[i] + p[i + 1]) / 2;
    path.quadraticBezierTo(p[i].dx, p[i].dy, m.dx, m.dy);
  }
  path.lineTo(p.last.dx, p.last.dy);
}

/// A line of ink in the drawings' manner: full in the middle, tapering to
/// nothing at both ends.
void _brush(Canvas c, List<Offset> p, double width, Color color) {
  if (p.length < 3) return;
  final side = <Offset>[], back = <Offset>[];
  for (var i = 0; i < p.length; i++) {
    final d = p[math.min(i + 1, p.length - 1)] - p[math.max(i - 1, 0)];
    if (d.distance < 1e-6) return;
    final k = math.pow(math.sin(math.pi * i / (p.length - 1)).abs(), .35);
    final n = Offset(-d.dy, d.dx) / d.distance * (width / 2 * k);
    side.add(p[i] + n);
    back.add(p[i] - n);
  }
  final path = Path();
  _through(path, side);
  _through(path, back.reversed.toList(), start: false);
  c.drawPath(path..close(), Paint()..color = color);
}

/// Points of an ellipse arc, angles in radians.
List<Offset> _arc(Offset c, Offset r, double from, double to, [int n = 12]) => [
  for (var i = 0; i <= n; i++)
    c +
        Offset(
          math.cos(from + (to - from) * i / n) * r.dx,
          math.sin(from + (to - from) * i / n) * r.dy,
        ),
];

/// One frame of the tail: its spine and how wide it is along it.
class _TailShape {
  _TailShape(this.spine, this.width, this.path);
  final List<Offset> spine;
  final List<double> width;
  final Path path;
}

/// How big the head is against the body: the drawn cats are mostly head.
const _headScale = 1.16;

extension on CatPainter {
  /// The whole cat on the floor of [size]: body behind, head and face from
  /// [_paintHead] on top, raised paws over the face, signs around it.
  void _paintFigure(
    Canvas canvas,
    Size size,
    CatFrame f,
    BodyPose pose,
    CatRig r,
    blob.MotionFrame motion,
    _Inks inks,
  ) {
    final look = profile.look;
    final t = f.time;
    final kitten = look.size == CatSize.kitten;
    final s = math.min(size.width / 5.4, size.height / 4.6);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + s * 1.95);
    canvas.scale(s * (kitten ? .84 : 1));

    final p = _live(pose, t);
    final lw = .086;

    // Floor shadow: soft, cheap, and it stays on the floor during hops.
    final shadowAt = Offset(p.shadow.dx, .03);
    canvas.drawOval(
      Rect.fromCenter(center: shadowAt, width: p.shadow.dy, height: .26),
      Paint()
        ..shader = ui.Gradient.radial(
          shadowAt,
          p.shadow.dy / 2,
          [inks.ink.withValues(alpha: .2), inks.ink.withValues(alpha: 0)],
          [.5, 1],
          TileMode.clamp,
          Matrix4.diagonal3Values(1, .26 / p.shadow.dy, 1).storage,
        ),
    );

    // Hops, sway and shivers move the whole cat about its feet.
    final hop = _hop(p, t);
    final squash = (p.squash + hop.$2).clamp(-.25, .25);
    canvas.translate(math.sin(t / 22) * .022 * p[Move.tremble], -hop.$1);
    canvas.rotate(math.sin(t / 820) * .045 * p[Move.sway]);
    canvas.scale(1 + squash * .5, 1 - squash);

    final tail = _tailShape(p, t);
    final torso = _loop(_breathing(p.torso, t, p));
    final thighs = Path()
      ..addOval(
        Rect.fromCenter(
          center: p.haunch[0],
          width: p.haunch[1].dx * 2,
          height: p.haunch[1].dy * 2,
        ),
      )
      ..addOval(
        Rect.fromCenter(
          center: p.haunch[2],
          width: p.haunch[3].dx * 2,
          height: p.haunch[3].dy * 2,
        ),
      );
    final trunk = Path.combine(PathOperation.union, torso, thighs);
    // A paw raised above its shoulder is an arm in front of the chest: it
    // gets its own outline instead of melting into the body.
    bool raised(int leg) =>
        leg < 2 && p.legs[leg * 2 + 1].dy < p.legs[leg * 2].dy - .15;
    final limbLegs = [
      for (var leg = 0; leg < 4; leg++)
        if (p.front[leg] >= .5 && !raised(leg)) leg,
    ];
    final limbs = [for (final leg in limbLegs) _limb(p, leg)];

    // A tail goes in front only once it is down: on its way it passes
    // behind the body.
    final tailInFront = p.tailFront > .5 && p.tail.every((o) => o.dy > -.75);
    if (!tailInFront) _paintTail(canvas, tail, inks, lw);
    for (var leg = 0; leg < 4; leg++) {
      if (p.front[leg] < .5) _paintLeg(canvas, p, leg, inks, lw);
    }
    if (tailInFront) _paintTail(canvas, tail, inks, lw, low: true);

    final b = profile.layout.body;
    void inHead(void Function() draw) {
      canvas.save();
      canvas.translate(p.head.dx, p.head.dy);
      canvas.rotate(p.headTilt);
      canvas.scale(_headScale / b.rx);
      canvas.translate(-b.cx, -b.cy);
      draw();
      canvas.restore();
    }

    // Body, thighs and the legs in front share one outline: all the ink
    // goes down first and all the fill over it, so only the outer edge
    // stays. A sitting cat's head joins in, its chin sunk in chest fur.
    final merged = p.merge > .5;
    // Lying or standing, only the front legs stand apart as volumes of their
    // own; the hind legs grow out of the thighs.
    final parts = [
      trunk,
      for (final (i, l) in limbs.indexed)
        if (merged || limbLegs[i] >= 2) ...l,
      if (merged) _neckFur(p),
      _backFur(p),
      _furBreaks(trunk),
    ];
    for (final part in parts) {
      canvas.drawPath(part, inks.line(lw * 2));
      canvas.drawPath(part.shift(const Offset(.008, .014)), inks.line(lw * 2));
    }
    if (merged) inHead(() => _paintHeadInk(canvas, f, r, motion, inks));
    final fill = Paint()..color = inks.fur;
    for (final part in parts) {
      canvas.drawPath(part, fill);
    }
    final sock = _sock(inks);
    if (sock != null && merged) {
      for (final l in limbs) {
        canvas.drawPath(l[1], Paint()..color = sock);
      }
    }

    canvas.save();
    canvas.clipPath(trunk);
    // Cel shading as drawn: a flat crescent of shade along the lower right
    // of the body, the light coming from the upper left.
    _crescent(canvas, trunk, inks, .2);
    _rim(canvas, trunk, inks);
    canvas.drawPicture(_grain);
    // Two or three tapered strokes of fur clustered at the front of the
    // thigh, unevenly spaced, in the shade's colour: drawn hairs, not a
    // seam.
    final hc = p.haunch[2], hr = p.haunch[3];
    if (hr.dx > .4) {
      final strand = Color.lerp(inks.fur, inks.ink, .28)!;
      for (final (a, len) in const [(-2.45, .12), (-2.2, .09), (-1.82, .1)]) {
        final o =
            hc + Offset(math.cos(a) * hr.dx * .8, math.sin(a) * hr.dy * .8);
        final dir = Offset(math.cos(a + 2.1), math.sin(a + 2.1));
        final bend = Offset(-dir.dy, dir.dx) * .02;
        _brush(
          canvas,
          [o, o + dir * (len / 2) + bend, o + dir * len],
          lw * .55,
          strand,
        );
      }
    }
    _paintBodyMarks(canvas, p, inks);
    // Thighs go behind the front legs.
    canvas.save();
    var legs = Path();
    for (final l in limbs) {
      legs = Path.combine(PathOperation.union, legs, l[0]);
    }
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(const Rect.fromLTRB(-9, -9, 9, 9)),
        legs,
      ),
    );
    // Thigh lines: the front edge of each haunch where it rounds into the
    // body.
    for (final side in [0, 1]) {
      final c = p.haunch[side * 2], rr = p.haunch[side * 2 + 1];
      if (rr.dx < .33) continue;
      final right = c.dx > p.head.dx;
      final arc = right
          ? _arc(c, rr * .98, math.pi * 1.83, math.pi * 1.11)
          : _arc(c, rr * .98, math.pi * 1.17, math.pi * 1.89);
      _brush(canvas, arc, lw * 1.2, inks.outline);
    }
    canvas.restore();
    canvas.restore();
    // Each front leg is a volume of its own over the body, as the drawings
    // overlap them. Sitting, its top melts into the chest: the ink starts
    // a little way down the leg.
    for (final leg in [0, 1]) {
      if (p.front[leg] >= .5 && !raised(leg)) {
        _paintLeg(canvas, p, leg, inks, lw, melt: p.merge);
      }
    }
    for (var leg = 0; leg < 2; leg++) {
      if (raised(leg)) _paintArm(canvas, p, leg, inks, lw);
    }

    if (tailInFront) {
      // The tail wraps over the paws: drawn again on top, away from its
      // root so it still grows out of the body.
      canvas.save();
      canvas.clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(const Rect.fromLTRB(-9, -9, 9, 9)),
          Path()
            ..addOval(Rect.fromCircle(center: tail.spine.first, radius: .3)),
        ),
      );
      _paintTail(canvas, tail, inks, lw, low: true);
      canvas.restore();
    }

    // The head, placed by its centre and rolled about it.
    inHead(
      () => _paintHead(
        canvas,
        f,
        r.withEars(merged ? 1 : .85),
        motion,
        inks,
        inked: !merged,
      ),
    );
    // The ruff lies over the chin, as drawn: a wide bib when sitting, a
    // small ruff otherwise.
    if (p.chest > .02) _paintRuff(canvas, p, inks, big: merged);
    // What it wears goes over the fur.
    _paintCharm(canvas, p, tail, inks, lw);

    for (final leg in [0, 1]) {
      if (p.over[leg] > .9) {
        _paintPaw(canvas, p.legs[leg * 2 + 1], inks, lw, leg, p);
      }
    }
    _paintEmotes(canvas, p, t, inks, lw);
    canvas.restore();
  }

  /// The pose with this moment's movements added.
  BodyPose _live(BodyPose p, double t) {
    final legs = [...p.legs];
    // Tapping the chin.
    final tap = p[Move.tap];
    if (tap > 0) {
      legs[3] += Offset(0, -math.pow(math.sin(t / 150).abs(), 2) * .07 * tap);
    }
    // Waving: the paw swings round the wrist.
    final wave = p[Move.wave];
    if (wave > 0) {
      final a = math.sin(t / 170);
      legs[3] += Offset(a * .16, -a.abs() * .05) * wave;
    }
    // Idle business, one act at a time on the cat's own clock.
    var tailFlick = 0.0, lift = 0.0;
    final idle = p[Move.fidget];
    if (idle > 0) {
      final every = profile.twitchEvery * 1.3;
      final round = (t / every).floor();
      final at = t - round * every;
      final act = math.Random(round * 7919 + profile.text.hashCode).nextInt(4);
      double bump(double from, double len) => at < from || at > from + len
          ? 0
          : math.sin(math.pi * (at - from) / len);
      switch (act) {
        case 0:
          // Shifts its weight from paw to paw.
          legs[1] += Offset(0, -.15 * bump(0, 600) * idle);
          legs[3] += Offset(0, -.15 * bump(600, 600) * idle);
        case 1:
          // Kneads.
          final e = bump(0, 2600);
          final press = math.sin(2 * math.pi * at / 650);
          legs[1] += Offset(0, -.12 * math.max(0, press) * e * idle);
          legs[3] += Offset(0, -.12 * math.max(0, -press) * e * idle);
          lift = .04 * e * idle;
        case 2:
          tailFlick = bump(0, 1300) * idle;
        default:
          // Stretches its neck to look about.
          lift = -.1 * bump(0, 1800) * idle;
      }
    }
    return BodyPose(
      head: p.head + Offset(0, lift),
      headTilt: p.headTilt,
      torso: p.torso,
      haunch: p.haunch,
      legs: legs,
      front: p.front,
      over: p.over,
      shade: p.shade,
      tail: [
        for (final (i, o) in p.tail.indexed)
          o + Offset(tailFlick * .08 * i, -tailFlick * .14 * i),
      ],
      tailFront: p.tailFront,
      puff: p.puff,
      chest: p.chest,
      merge: p.merge,
      shadow: p.shadow,
      emote: p.emote,
      move: p.move,
      squash: p.squash,
    );
  }

  /// Height of the current hop and its squash: up, a stretch in the air and
  /// a squash on landing.
  (double, double) _hop(BodyPose p, double t) {
    final k = p[Move.bounce];
    if (k <= 0) return (0, 0);
    final phase = (t % 1150) / 1150;
    if (phase < .36) {
      final up = math.sin(math.pi * phase / .36);
      return (up * .26 * k, -up * .08 * k);
    }
    if (phase < .5) {
      return (0, math.sin(math.pi * (phase - .36) / .14) * .09 * k);
    }
    return (0, 0);
  }

  /// The torso rises a little with each breath; asleep it breathes deeper.
  List<Offset> _breathing(List<Offset> torso, double t, BodyPose p) {
    final deep = 1 + 1.6 * p.emoteOf(Emote.zzz);
    final k = math.sin(t / (650 * deep)) * .018 * deep;
    return [for (final o in torso) Offset(o.dx * (1 - k * .3), o.dy * (1 + k))];
  }

  _TailShape _tailShape(BodyPose p, double t) {
    final kind = profile.look.tail;
    const n = 18;
    final bushy = kind == CatTail.bushy;
    final puff = 1 + .45 * p.puff;
    final width = [
      for (var i = 0; i <= n; i++)
        (bushy
                ? (.26 + .5 * math.sin(math.pi * math.pow(i / n, 1.94))) *
                      (1 - .78 * _ease(((i / n) - .55) / .45))
                : _along(const [.3, .5, .64, .62, .46], i / n)) *
            puff,
    ];
    // The pose's five points, the last one turned further in for a tail
    // that ends in a curl.
    // A plume stands taller than a plain tail.
    final c = [
      for (final o in p.tail)
        kind == CatTail.bushy
            ? p.tail[0] +
                  Offset(o.dx - p.tail[0].dx, (o.dy - p.tail[0].dy) * 1.18)
            : o,
    ];
    if (kind == CatTail.curl || kind == CatTail.bushy) {
      final d = c[4] - c[3], e = c[3] - c[2];
      final k = kind == CatTail.curl ? .9 : .5;
      final turn = (e.dx * d.dy - e.dy * d.dx) >= 0 ? k : -k;
      c[4] =
          c[3] +
          Offset(
            d.dx * math.cos(turn) - d.dy * math.sin(turn),
            d.dx * math.sin(turn) + d.dy * math.cos(turn),
          );
    }
    // A smooth curve through them (Catmull-Rom, ends doubled).
    Offset at(double u) {
      final x = u * 4;
      final k = math.min(x.floor(), 3);
      final f = x - k;
      final p0 = c[math.max(k - 1, 0)], p1 = c[k];
      final p2 = c[k + 1], p3 = c[math.min(k + 2, 4)];
      final f2 = f * f, f3 = f2 * f;
      return (p1 * 2 +
              (p2 - p0) * f +
              (p0 * 2 - p1 * 5 + p2 * 4 - p3) * f2 +
              (p1 * 3 - p0 - p2 * 3 + p3) * f3) /
          2;
    }

    final wag = p[Move.wag], lash = p[Move.lash];
    final base = [for (var i = 0; i <= n; i++) at(i / n)];
    final spine = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      final d = base[math.min(i + 1, n)] - base[math.max(i - 1, 0)];
      final nn = Offset(-d.dy, d.dx) / d.distance;
      // A wave runs down the tail; wagging and lashing add faster ones.
      final wave =
          (math.sin(t / 900 - i * .32) * .06 +
              math.sin(t / 95 - i * .45) * .16 * wag +
              math.sin(t / 150 - i * .3) * .3 * lash) *
          u *
          u;
      var q = base[i] + nn * wave;
      // Lying on the floor, the tail rests on it: never through it.
      final floor = -width[i] / 2 - .02;
      if (q.dy > floor) q = Offset(q.dx, floor);
      spine.add(q);
    }
    final fur = bushy || p.puff > .25;
    final left = <Offset>[], right = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final d = spine[math.min(i + 1, n)] - spine[math.max(i - 1, 0)];
      final nn = Offset(-d.dy, d.dx) / d.distance;
      final along = d / d.distance;
      // Fur: every other point stands out and leans towards the tip.
      // A plume breaks into a few flames, not a saw.
      final tuft = bushy && p.puff < .25
          ? const {9, 12, 15}.contains(i)
          : fur && i > 2 && i < n - 1 && i.isOdd;
      final k = tuft ? 1.22 + .1 * p.puff : 1.0;
      final lean = tuft ? along * (width[i] * .25) : Offset.zero;
      left.add(spine[i] + nn * (width[i] / 2 * k) + lean);
      right.add(spine[i] - nn * (width[i] / 2 * k) + lean);
    }
    final path = Path();
    final spiky = p.puff > .25;
    if (spiky) {
      path.moveTo(left[0].dx, left[0].dy);
      for (final o in left.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
    } else {
      _through(path, left);
    }
    final radius = width.last / 2;
    // Round cap over the tip: from the left side, round the front, to the
    // right side, which on a y-down canvas runs anticlockwise.
    path.arcToPoint(
      right.last,
      radius: Radius.circular(radius),
      clockwise: false,
    );
    if (spiky) {
      for (final o in right.reversed.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
    } else {
      _through(path, right.reversed.toList(), start: false);
    }
    path.close();
    // Fur corners are softened by drawing the outline with round joins.
    return _TailShape(spine, width, path);
  }

  void _paintTail(
    Canvas c,
    _TailShape tail,
    _Inks inks,
    double lw, {
    bool low = false,
  }) {
    final look = profile.look;
    c.drawPath(tail.path, inks.line(lw * 2));
    c.drawPath(tail.path.shift(const Offset(.008, .014)), inks.line(lw * 2));
    // A tail laid on the floor in front is a shade darker, so it reads as
    // the tail and not a leg.
    c.drawPath(
      tail.path,
      Paint()..color = low ? Color.lerp(inks.fur, inks.ink, .12)! : inks.fur,
    );
    c.save();
    c.clipPath(tail.path);
    // The underside of the tail in shadow, as in the drawings.
    final under = <Offset>[];
    for (var i = 0; i < tail.spine.length; i++) {
      final s = tail.spine;
      final d = s[math.min(i + 1, s.length - 1)] - s[math.max(i - 1, 0)];
      under.add(s[i] + Offset(d.dy, -d.dx) / d.distance * tail.width[i] * .42);
    }
    _crescent(c, tail.path, inks, .2);
    final n = tail.spine.length - 1;
    Color? tip;
    var from = 0.0;
    if (look.mark == CatMark.mask) {
      tip = inks.deep;
      from = .45;
    } else if (look.tail == CatTail.tipped) {
      tip = inks.fur.computeLuminance() > .45
          ? inks.deep
          : Color.lerp(inks.fur, Colors.white, .75)!;
      from = .74;
    } else if (look.tail == CatTail.bushy) {
      tip = Color.lerp(inks.fur, inks.ink, .3)!;
      from = .6;
    }
    if (tip != null) {
      // The tip's colour starts on a fringe of hairs, not a straight cut.
      final k = (n * from).round();
      final sp = tail.spine;
      final band = Path();
      _through(band, [...sp.sublist(k), sp[n] + (sp[n] - sp[n - 1]) * 6]);
      c.drawPath(
        band,
        Paint()
          ..color = tip
          ..style = PaintingStyle.stroke
          ..strokeWidth = tail.width.reduce(math.max) * 2.4
          ..strokeCap = StrokeCap.butt,
      );
      final d = sp[k + 1] - sp[k];
      final along = d / d.distance;
      final nn = Offset(-along.dy, along.dx) * tail.width[k];
      for (final f in const [-.4, -.2, 0.0, .2, .4]) {
        final at = sp[k] + nn * f;
        final w = nn * .1;
        c.drawPath(
          Path()
            ..moveTo((at - w).dx, (at - w).dy)
            ..lineTo((at - along * .2).dx, (at - along * .2).dy)
            ..lineTo((at + w).dx, (at + w).dy)
            ..close(),
          Paint()..color = tip,
        );
      }
    }
    if (look.mark == CatMark.stripes) {
      // Rings, darker towards the tip.
      final ring = Paint()
        ..color = inks.deep
        ..strokeWidth = .15
        ..strokeCap = StrokeCap.round;
      for (final u in const [.24, .4, .56, .72, .88]) {
        final i = (n * u).round();
        final d = tail.spine[math.min(i + 1, n)] - tail.spine[i - 1];
        final nn = Offset(-d.dy, d.dx) / d.distance * tail.width[i];
        c.drawLine(tail.spine[i] - nn, tail.spine[i] + nn, ring);
      }
    }
    c.restore();
  }

  /// A leg and its paw, as two paths.
  List<Path> _limb(BodyPose p, int leg) {
    final root = p.legs[leg * 2], paw = p.legs[leg * 2 + 1];
    final hind = leg >= 2;
    return [
      _capsule(
        root,
        hind ? .27 : .24 - .03 * p.merge,
        paw - const Offset(0, .04),
        .22 - .04 * p.merge,
      ),
      Path()..addOval(
        Rect.fromCenter(
          center: paw,
          width: .52 - .08 * p.merge,
          height: .3 - .06 * p.merge,
        ),
      ),
    ];
  }

  void _paintLeg(
    Canvas c,
    BodyPose p,
    int leg,
    _Inks inks,
    double lw, {
    double melt = 0,
  }) {
    final root = p.legs[leg * 2], paw = p.legs[leg * 2 + 1];
    final [shape, foot] = _limb(p, leg);
    final unit = Path.combine(PathOperation.union, shape, foot);
    final fur = Color.lerp(inks.fur, inks.ink, .22 * p.shade[leg])!;
    c.save();
    if (melt > 0) {
      // Sitting, the leg's ink starts where the bib ends, so no bare stub
      // shows between them.
      final b = profile.layout.body;
      final chin = p.head.dy + b.ry * .86 / b.rx * _headScale;
      // Well below it, so the rounded top of the leg never shows as a knee.
      final from = math.max(
        chin - .3 + .8 * (.35 + .65 * .62) + .2,
        root.dy + .25,
      );
      c.clipRect(Rect.fromLTRB(-9, root.dy + (from - root.dy) * melt, 9, 9));
    }
    c.drawPath(unit, inks.line(lw * 2));
    c.drawPath(unit.shift(const Offset(.008, .014)), inks.line(lw * 2));
    c.restore();
    c.drawPath(unit, Paint()..color = fur);
    final sock = _sock(inks);
    if (sock != null) {
      c.save();
      c.clipPath(unit);
      c.drawOval(
        Rect.fromCenter(center: paw, width: .5, height: .4),
        Paint()..color = sock,
      );
      c.restore();
    }
    c.save();
    c.clipPath(unit);
    _crescent(c, unit, inks, .22);
    c.restore();
    if (leg < 2) _toes(c, paw, inks, lw);
  }

  /// A pale rim along the upper left of [shape], where the light falls.
  void _rim(Canvas c, Path shape, _Inks inks) {
    c.drawPath(
      Path.combine(
        PathOperation.difference,
        shape,
        shape.shift(const Offset(.1, .09)),
      ),
      Paint()
        ..color = Color.lerp(inks.fur, Colors.white, .07)!
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, .03),
    );
  }

  /// A flat crescent of shade along the lower right of [shape]: the part
  /// the light from the upper left does not reach. Callers clip to it.
  void _crescent(Canvas c, Path shape, _Inks inks, double depth) {
    c.drawPath(
      Path.combine(
        PathOperation.difference,
        shape,
        shape.shift(const Offset(-.24, -.2)),
      ),
      Paint()
        ..color = Color.lerp(inks.fur, inks.ink, depth)!.withValues(alpha: .5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, .05),
    );
  }

  /// A raised front leg: inked on its own over the chest, the paw end
  /// turned up.
  void _paintArm(Canvas c, BodyPose p, int leg, _Inks inks, double lw) {
    final root = p.legs[leg * 2], paw = p.legs[leg * 2 + 1];
    final arm = _capsule(root, .17, paw, .15);
    c.drawPath(arm, Paint()..color = inks.fur);
    // Only the arm's outer side is inked, running from the paw down into
    // the chest: inner lines would make the two paws read as goggles.
    final d = paw - root;
    var n = Offset(-d.dy, d.dx) / d.distance;
    final out = leg == 0 ? -1.0 : 1.0;
    if (n.dx * out < 0) n = -n;
    _brush(
      c,
      [for (var i = 0; i <= 8; i++) paw - d * (i / 8 * .85) + n * .16],
      lw * 1.6,
      inks.outline,
    );
    if (p.over[leg] <= .9) _paintPaw(c, paw, inks, lw, leg, p);
  }

  /// White socks for a cat with a pale muzzle, dark points for a masked one.
  Color? _sock(_Inks inks) => switch (profile.look.mark) {
    CatMark.muzzle => Color.lerp(inks.fur, Colors.white, .6),
    CatMark.mask => inks.deep,
    _ => null,
  };

  void _toes(Canvas c, Offset paw, _Inks inks, double lw, {bool up = false}) {
    final toe = inks.line(lw * .8);
    final k = up ? -1.0 : 1.0;
    for (final x in const [-.07, .07]) {
      c.drawLine(paw + Offset(x, .03 * k), paw + Offset(x * 1.1, .11 * k), toe);
    }
  }

  /// A paw raised over the face: only the paw, so the arm stays tucked
  /// behind the cheek.
  void _paintPaw(
    Canvas c,
    Offset paw,
    _Inks inks,
    double lw,
    int leg,
    BodyPose p,
  ) {
    final up = paw.dy < p.legs[leg * 2].dy - .15;
    // A raised paw tips a little inward, the way paws held up do.
    final tilt = up ? (leg == 0 ? .38 : -.38) : 0.0;
    c.save();
    c.translate(paw.dx, paw.dy);
    c.rotate(tilt);
    c.translate(-paw.dx, -paw.dy);
    final foot = Path()
      ..addOval(
        Rect.fromCenter(
          center: paw,
          width: up ? .44 : .3,
          height: up ? .34 : .24,
        ),
      );
    // Raised paws are soft mittens: a finer line and a lighter fill than
    // the body's, or two of them read as rings.
    c.drawPath(foot, inks.line(lw * (up ? 1.5 : 2)));
    c.drawPath(
      foot,
      Paint()
        ..color =
            _sock(inks) ??
            (up ? Color.lerp(inks.fur, Colors.white, .1)! : inks.fur),
    );
    if (up) {
      // Three short ticks on the top edge: the toes of a raised paw.
      final toe = inks.line(lw * .7);
      for (final x in const [-.08, 0.0, .08]) {
        c.drawLine(paw + Offset(x, -.145), paw + Offset(x, -.1), toe);
      }
    } else {
      _toes(c, paw, inks, lw);
    }
    c.restore();
  }

  /// A couple of small tufts on the top of the near thigh, so the outline
  /// reads as fur, not rubber.
  Path _backFur(BodyPose p) {
    final out = Path();
    void tuft(Offset at, Offset dir, double size) {
      final along = Offset(-dir.dy, dir.dx);
      final w = .07 * size, len = .09 * size;
      final tip = at + dir * len - along * (len * .5);
      final b0 = at - dir * .06 - along * w, b1 = at - dir * .06 + along * w;
      out.addPath(
        Path()
          ..moveTo(b0.dx, b0.dy)
          ..quadraticBezierTo(at.dx, at.dy, tip.dx, tip.dy)
          ..quadraticBezierTo(
            (at + along * w).dx,
            (at + along * w).dy,
            b1.dx,
            b1.dy,
          )
          ..close(),
        Offset.zero,
      );
    }

    final c = p.haunch[2], r = p.haunch[3];
    if (r.dx > .4) {
      for (final (a, k) in const [(-1.9, 1.0), (-1.55, .8)]) {
        final dir = Offset(math.cos(a), math.sin(a));
        tuft(c + Offset(dir.dx * r.dx, dir.dy * r.dy), dir, k);
      }
    }
    return out;
  }

  /// Tufts where the chest fur sticks out past the shoulders, leaning
  /// down: the cheek fur carried on below the head.
  Path _neckFur(BodyPose p) {
    final out = Path();
    for (final (side, a, b) in [(-1.0, 0, 1), (1.0, 7, 6)]) {
      for (final (k, size) in const [(.22, 1.0), (.5, .8)]) {
        final at = Offset.lerp(p.torso[a], p.torso[b], k)!;
        final w = .1 * size, len = .15 * size;
        final dir = Offset(side * math.cos(.7), math.sin(.7));
        final along = Offset(-dir.dy, dir.dx);
        final tip = at + dir * len + along * (len * .3 * side);
        final b0 = at - dir * .08 - along * w, b1 = at - dir * .08 + along * w;
        out.addPath(
          Path()
            ..moveTo(b0.dx, b0.dy)
            ..quadraticBezierTo(at.dx, at.dy, tip.dx, tip.dy)
            ..quadraticBezierTo(
              (at + along * w * .8).dx,
              (at + along * w * .8).dy,
              b1.dx,
              b1.dy,
            )
            ..close(),
          Offset.zero,
        );
      }
    }
    return out;
  }

  /// Little tufts all along the body's outline where it faces up or out,
  /// a quarter of a head apart, each leaning back along the fur: the
  /// drawn cats' outline breaks into fur about a third of the way round.
  Path _furBreaks(Path body) {
    final out = Path();
    final metrics = body.computeMetrics().toList();
    if (metrics.isEmpty) return out;
    final m = metrics.reduce((a, b) => a.length > b.length ? a : b);
    const step = .62;
    var k = 0;
    for (var d = step / 2; d < m.length; d += step, k++) {
      final t = m.getTangentForOffset(d)!;
      final at = t.position, dir = t.vector;
      var n = Offset(-dir.dy, dir.dx);
      if (body.contains(at + n * .04)) n = -n;
      // Fur on the back, flanks and chest, none on the floor or belly.
      if (n.dy > .2 || at.dy > -.5) continue;
      final size = k.isEven ? 1.0 : .8;
      final w = .07 * size, len = .055 * size;
      final lean = dir * (len * .9);
      final tip = at + n * len + lean;
      final b0 = at - n * .05 - dir * w, b1 = at - n * .05 + dir * w;
      out.addPath(
        Path()
          ..moveTo(b0.dx, b0.dy)
          ..quadraticBezierTo(at.dx, at.dy, tip.dx, tip.dy)
          ..quadraticBezierTo(
            (at + dir * w).dx,
            (at + dir * w).dy,
            b1.dx,
            b1.dy,
          )
          ..close(),
        Offset.zero,
      );
    }
    return out;
  }

  /// Pale fur under the chin: a wide bib over a sitting cat's chest, a
  /// smaller ruff under the chin of one lying or standing. Its lower edge
  /// breaks into scallops; it pales towards the middle and has no outline,
  /// being fur on fur.
  void _paintRuff(Canvas c, BodyPose p, _Inks inks, {required bool big}) {
    final b = profile.layout.body;
    final chin = p.head + Offset(0, b.ry * .86 / b.rx * _headScale);
    final muzzle = profile.look.mark == CatMark.muzzle;
    final w = big ? 1.36 : .82, h = big ? .8 : .42;
    final top = chin.dy - (big ? .3 : .26);
    final cx = chin.dx;
    // Upper half: a smooth arch hidden mostly under the chin; lower half:
    // five scallops.
    // Two lobes rising beside the chin, like a heart of fur.
    final path = Path()..moveTo(cx - w / 2, top + h * .35);
    path
      ..cubicTo(
        cx - w / 2,
        top - h * .12,
        cx - w * .08,
        top - h * .1,
        cx,
        top + h * .12,
      )
      ..cubicTo(
        cx + w * .08,
        top - h * .1,
        cx + w / 2,
        top - h * .12,
        cx + w / 2,
        top + h * .35,
      );
    const scallops = 5;
    for (var i = 0; i < scallops; i++) {
      final u0 = i / scallops, u1 = (i + 1) / scallops;
      // The bib narrows to a soft point in the middle of its lower edge.
      double x(double u) => cx + w / 2 - w * u;
      double y(double u) =>
          top + h * (.35 + .65 * (.62 + .38 * math.sin(math.pi * u)));
      final mid = (u0 + u1) / 2;
      path.quadraticBezierTo(x(mid), y(mid) + h * .16, x(u1), y(u1));
    }
    path.close();
    final a = p.chest.clamp(0.0, 1.0);
    final centre = Color.lerp(inks.fur, Colors.white, muzzle ? .62 : .27)!;
    final edge = Color.lerp(inks.fur, Colors.white, muzzle ? .5 : .2)!;
    c.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.radial(Offset(cx, top + h * .5), w * .62, [
          centre.withValues(alpha: a),
          edge.withValues(alpha: a),
        ]),
    );
    // Fading back into the fur at the top where it meets the chin, so it
    // has no edge there.
    c.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, top - h * .1),
          Offset(cx, top + h * .3),
          [inks.fur.withValues(alpha: a), inks.fur.withValues(alpha: 0)],
        ),
    );
    // A few strokes of fur near the lower edge.
    final fur = Paint()
      ..color = inks.outline.withValues(alpha: .22 * a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .03
      ..strokeCap = StrokeCap.round;
    for (final (x, y) in const [(-.18, .66), (.18, .66)]) {
      final o = Offset(cx + x * w, top + y * h);
      c.drawLine(o, o + Offset(x * .1, .1 * h), fur);
    }
    // Inked hairs along the lower edge, where the bib meets the fur.
    final hair = Paint()
      ..color = inks.outline.withValues(alpha: .5 * a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .045
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final u = (i + .5) / 6;
      final x = cx + w / 2 - w * u;
      final y = top + h * (.35 + .65 * (.62 + .38 * math.sin(math.pi * u)));
      final o = Offset(x, y + h * .06);
      c.drawLine(o - Offset((u - .5) * .06, .08), o, hair);
    }
  }

  /// Patterns that carry on from the face onto the body.
  void _paintBodyMarks(Canvas c, BodyPose p, _Inks inks) {
    final look = profile.look;
    final back = [p.torso[5], p.torso[6], p.torso[7]];
    final mid = p.torso.reduce((a, b) => a + b) / 8;
    switch (look.mark) {
      case CatMark.stripes:
        // Stripes dipped in from the back, shorter towards the tail.
        for (final (k, len) in const [
          (.15, .5),
          (.45, .58),
          (.75, .5),
          (1.1, .42),
          (1.45, .34),
        ]) {
          final a = k < 1
              ? Offset.lerp(back[2], back[1], k)!
              : Offset.lerp(back[1], back[0], k - 1)!;
          final dir = (mid - a) / (mid - a).distance;
          final bend = Offset(-dir.dy, dir.dx) * .06;
          _brush(
            c,
            [a - dir * .1, a + dir * (len * .5) + bend, a + dir * len],
            .17,
            Color.lerp(inks.fur, inks.ink, .42)!,
          );
        }
      case CatMark.patch:
        final side = profile.traits('cat.mark.side') < .5 ? 0 : 1;
        final at = Offset.lerp(back[1], mid, .3)! + Offset(side * .1 - .1, 0);
        c.drawOval(
          Rect.fromCenter(center: at, width: 1.1, height: .8),
          Paint()..color = inks.deep,
        );
      case CatMark.stars:
        final at = p.haunch[2];
        for (final (dx, dy, r) in const [(.05, -.1, .1), (-.18, .12, .06)]) {
          final o = at + Offset(dx, dy);
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
  }

  /// What the cat wears on its body: one thing at most.
  void _paintCharm(
    Canvas c,
    BodyPose p,
    _TailShape tail,
    _Inks inks,
    double lw,
  ) {
    final look = profile.look;
    final b = profile.layout.body;
    final chin = p.head + Offset(0, b.ry * .9 / b.rx * _headScale + .1);
    switch (look.charm) {
      case CatCharm.none:
        return;
      case CatCharm.collar:
        final band = Path()
          ..moveTo(chin.dx - .5, chin.dy - .16)
          ..quadraticBezierTo(
            chin.dx,
            chin.dy + .22,
            chin.dx + .5,
            chin.dy - .16,
          );
        c.drawPath(band, inks.line(.2 + lw * 2));
        c.drawPath(
          band,
          Paint()
            ..color = inks.blush
            ..style = PaintingStyle.stroke
            ..strokeWidth = .14
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
        c.drawLine(
          bell + const Offset(0, .03),
          bell + const Offset(0, .1),
          inks.line(lw * .7),
        );
      case CatCharm.scarf:
        final cloth = Color.lerp(inks.blush, inks.fur, .25)!;
        final band = Path()
          ..moveTo(chin.dx - .58, chin.dy - .16)
          ..quadraticBezierTo(
            chin.dx,
            chin.dy + .3,
            chin.dx + .58,
            chin.dy - .16,
          );
        final end = Path()
          ..moveTo(chin.dx + .18, chin.dy + .02)
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
            chin.dy - .02,
          )
          ..close();
        c.drawPath(end, inks.line(lw * 2));
        c.drawPath(band, inks.line(.26 + lw * 2));
        c.drawPath(end, Paint()..color = cloth);
        c.drawPath(
          band,
          Paint()
            ..color = cloth
            ..style = PaintingStyle.stroke
            ..strokeWidth = .26
            ..strokeCap = StrokeCap.round,
        );
        // A couple of stripes across the hanging end.
        final stripe = Paint()
          ..color = Color.lerp(cloth, Colors.white, .55)!
          ..strokeWidth = .05;
        c.save();
        c.clipPath(end);
        for (final y in const [.32, .46]) {
          c.drawLine(
            Offset(chin.dx + .2, chin.dy + y),
            Offset(chin.dx + .7, chin.dy + y - .06),
            stripe,
          );
        }
        c.restore();
      case CatCharm.ribbon:
        final i = (tail.spine.length * .52).round();
        final at = tail.spine[i];
        final d = tail.spine[i + 1] - tail.spine[i - 1];
        c.save();
        c.translate(at.dx, at.dy);
        c.rotate(math.atan2(d.dy, d.dx) + math.pi / 2);
        final bow = Path();
        for (final sdir in [-1.0, 1.0]) {
          bow
            ..moveTo(0, 0)
            ..quadraticBezierTo(sdir * .14, -.22, sdir * .3, -.12)
            ..quadraticBezierTo(sdir * .36, 0, sdir * .3, .12)
            ..quadraticBezierTo(sdir * .14, .22, 0, 0);
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

  /// The little drawn signs: lines of excitement, hearts, sleep, a question,
  /// thinking dots, a sweat drop, a cross vein. Each one pops in with its
  /// amplitude and moves on its own clock.
  void _paintEmotes(Canvas c, BodyPose p, double t, _Inks inks, double lw) {
    // Above the head on the right, clear of the ears; a cat in profile
    // has its back there, well below the signs.
    const side = 1.0;
    final at = p.head + Offset(side * 1.42, -1.12) * _headScale;
    final ink = inks.outline;

    final dashes = p.emoteOf(Emote.dashes);
    if (dashes > .02) {
      final pulse = .85 + .15 * math.sin(t / 160);
      final paint = inks.line(.07 * dashes)
        ..color = ink.withValues(alpha: dashes.clamp(0.0, 1.0));
      for (final a in const [-1.15, -.6, -.05]) {
        final dir = Offset(math.cos(a) * side, math.sin(a));
        c.drawLine(
          at + dir * (.2 * pulse),
          at + dir * (.2 + .2 * pulse * dashes),
          paint,
        );
      }
    }

    final hearts = p.emoteOf(Emote.hearts);
    if (hearts > .02) {
      for (var k = 0; k < 2; k++) {
        final phase = ((t / 2600) + k * .5) % 1;
        final o =
            at +
            Offset(
              side * (math.sin(phase * 6 + k) * .12 + k * .25),
              -phase * .9 + .2,
            );
        final a = math.sin(math.pi * phase) * hearts;
        _heart(c, o, .13 + .05 * k, inks, a);
      }
    }

    final zzz = p.emoteOf(Emote.zzz);
    if (zzz > .02) {
      for (var k = 0; k < 3; k++) {
        final phase = ((t / 3200) + k / 3) % 1;
        final size = .1 + .1 * phase;
        final o = p.head + Offset(.95 + phase * .7, -1.35 - phase * .8);
        final a = math.sin(math.pi * phase) * zzz;
        final z = Path()
          ..moveTo(o.dx - size, o.dy - size)
          ..lineTo(o.dx + size, o.dy - size)
          ..lineTo(o.dx - size, o.dy + size)
          ..lineTo(o.dx + size, o.dy + size);
        c.drawPath(
          z,
          inks.line(.055)..color = ink.withValues(alpha: a.clamp(0.0, 1.0)),
        );
      }
    }

    final question = p.emoteOf(Emote.question);
    if (question > .02) {
      final o = at + Offset(0, math.sin(t / 420) * .06);
      final paint = inks.line(.085)
        ..color = ink.withValues(alpha: question.clamp(0.0, 1.0));
      final q = Path()
        ..moveTo(o.dx - .14, o.dy - .2)
        ..quadraticBezierTo(o.dx - .12, o.dy - .38, o.dx + .02, o.dy - .38)
        ..quadraticBezierTo(o.dx + .18, o.dy - .36, o.dx + .16, o.dy - .2)
        ..quadraticBezierTo(o.dx + .14, o.dy - .08, o.dx + .02, o.dy - .02)
        ..lineTo(o.dx + .02, o.dy + .06);
      c.drawPath(q, paint);
      c.drawCircle(
        o + const Offset(.02, .2),
        .055,
        Paint()..color = ink.withValues(alpha: question.clamp(0.0, 1.0)),
      );
    }

    final dots = p.emoteOf(Emote.dots);
    if (dots > .02) {
      final step = (t / 380).floor() % 4;
      for (var k = 0; k < 3; k++) {
        if (k >= step) break;
        c.drawCircle(
          at + Offset(side * (k * .17 - .05), .12 - k * .06),
          .05,
          Paint()..color = ink.withValues(alpha: dots.clamp(0.0, 1.0)),
        );
      }
    }

    final sweat = p.emoteOf(Emote.sweat);
    if (sweat > .02) {
      final phase = (t / 1800) % 1;
      final o = p.head + Offset(-side * 1.15, -.85 + phase * .25);
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
      c.drawPath(drop, inks.line(lw * 1.4)..color = ink.withValues(alpha: a));
      c.drawPath(
        drop,
        Paint()..color = const Color(0xffbfe4fb).withValues(alpha: a),
      );
    }

    final anger = p.emoteOf(Emote.anger);
    if (anger > .02) {
      final pulse = 1 + .12 * math.sin(t / 120);
      final o = at;
      final paint = Paint()
        ..color = const Color(0xffe8506e).withValues(alpha: anger.clamp(0, 1))
        ..style = PaintingStyle.stroke
        ..strokeWidth = .07
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < 4; k++) {
        final a = k * math.pi / 2 + math.pi / 4;
        final dir = Offset(math.cos(a), math.sin(a));
        final normal = Offset(-dir.dy, dir.dx);
        final mid = o + dir * (.14 * pulse);
        c.drawPath(
          Path()
            ..moveTo(mid.dx + normal.dx * .09, mid.dy + normal.dy * .09)
            ..quadraticBezierTo(
              o.dx + dir.dx * .05,
              o.dy + dir.dy * .05,
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
