import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset;

import 'package:blobatar/blobatar.dart' as blob;

import 'genome.dart';

/// A control point in head units: 1 is half the head width. [soft] is how much
/// of each neighbouring edge the corner eats; .5 leaves no straight run at all.
class Vertex {
  const Vertex(this.x, this.y, [this.soft = .5]);
  final double x, y, soft;
}

/// Top of the valley between the ears, shared so no head grows a nub there.
const _crown = -.54;

/// Right side of the head below the ear, ending on the chin axis.
const _sides = {
  // Round temples, cheeks full below the eyes, and a soft rounded jaw
  // instead of corners: the drawn cats' head.
  CatHead.mochi: [
    Vertex(1.06, -.26),
    Vertex(1.24, .24, .5),
    Vertex(1.04, .64, .5),
    Vertex(.6, .86),
    Vertex(0, .9),
  ],
  CatHead.bun: [
    Vertex(1.04, -.12),
    Vertex(1.34, .28, .44),
    Vertex(1.0, .76),
    Vertex(0, .76),
  ],
  CatHead.round: [
    Vertex(1.08, -.2),
    Vertex(1.1, .52),
    Vertex(.62, .98),
    Vertex(0, .98),
  ],
  CatHead.fluff: [
    Vertex(1.0, -.18),
    Vertex(1.18, .04, .32),
    Vertex(1.06, .16, .46),
    Vertex(1.28, .36, .32),
    Vertex(1.08, .5, .46),
    Vertex(1.14, .7, .32),
    Vertex(.84, .74, .46),
    Vertex(.72, .92, .36),
    Vertex(.42, .82, .46),
    Vertex(0, .92),
  ],
  CatHead.cube: [Vertex(1.08, -.2, .3), Vertex(1.12, .86, .26), Vertex(0, .88)],
};

/// Right ear from the valley to the head side. Each is a leaf: the two
/// shoulders keep both edges convex near the tip, as in the original drawing.
const _ears = {
  // A high round crown with the ears on its shoulders, as in the drawings.
  CatEars.moon: [
    Vertex(.24, -.68),
    Vertex(.46, -.98),
    Vertex(.84, -1.33, .46),
    Vertex(1.08, -.88),
    Vertex(1.06, -.4),
  ],
  CatEars.tiny: [
    Vertex(.3, -.58),
    Vertex(.54, -.92),
    Vertex(.8, -1.3, .46),
    Vertex(.98, -.92),
    Vertex(1.0, -.46),
  ],
  CatEars.wide: [
    Vertex(.1, -.54),
    Vertex(.56, -1.0),
    Vertex(1.06, -1.48, .46),
    Vertex(1.24, -.9),
    Vertex(1.02, -.38),
  ],
  CatEars.fold: [
    Vertex(.28, -.58),
    Vertex(.56, -.88),
    Vertex(.98, -.92),
    Vertex(1.04, -.4),
  ],
  // The moon ear's soft leaf, a little lower; the brush grows out of its
  // tip (see the painter).
  CatEars.tuft: [
    Vertex(.24, -.68),
    Vertex(.46, -.96),
    Vertex(.82, -1.3, .46),
    Vertex(1.07, -.86),
    Vertex(1.05, -.42),
  ],
  CatEars.bear: [
    Vertex(.34, -.58),
    Vertex(.4, -1.04),
    Vertex(.92, -1.22),
    Vertex(1.16, -.86),
    Vertex(1.02, -.42),
  ],
};

/// The cat as a Blobatar silhouette: its own body, face region and eye fit
/// fed through the public style seam, so expressions and motion stay native.
class CatSilhouette extends blob.Shape {
  CatSilhouette(this.look, this.traits) : super('cat-${look.head.name}', 1);

  final CatLook look;
  final blob.Traits traits;

  /// The drawn cats have broad, low ears: the tall leaf of the first sketch
  /// is pressed down towards the crown, the short kinds a little less.
  static const _earScale = {
    CatEars.moon: 1.0,
    CatEars.tiny: .9,
    CatEars.wide: .74,
    CatEars.fold: 1.0,
    CatEars.tuft: 1.0,
    CatEars.bear: .92,
  };
  late final double _earLength =
      traits.numIn('cat.ear.long', .92, 1.04) * _earScale[look.ears]!;
  late final double _cheek = traits.numIn('cat.cheek', .95, 1.05);

  @override
  void body(blob.Traits t, blob.Body b) {
    b.rot = 0;
    final kitten = look.size == CatSize.kitten;
    b.cx = 50;
    // Smaller but standing on the same chin line.
    b.cy = kitten ? 65 : 60;
    b.rx = t.numIn('cat.head.size', 31, 33.5) * (kitten ? .8 : 1);
    b.ry = b.rx * t.numIn('cat.head.tall', .96, 1.05);
  }

  @override
  blob.Ellipse face(blob.Body b) =>
      blob.Ellipse(b.cx, b.cy + b.ry * .16, b.rx * .9, b.ry * .6);

  @override
  blob.BlobPath path(blob.Body b) => trace(b);

  /// Eye placement in the same traits-to-geometry role as [blob.faceFit].
  List<blob.Eye> fit(blob.Traits t, blob.Body b, blob.Ellipse face) {
    final (size, ratio, gap, n) = switch (look.eyes) {
      CatEyes.moon => (t.numIn('cat.eye.size', .27, .32), 1.08, .48, 2.1),
      CatEyes.pupil => (t.numIn('cat.eye.size', .24, .29), 1.1, .47, 2.1),
      CatEyes.slit => (t.numIn('cat.eye.size', .23, .27), 1.0, .48, 2.0),
      CatEyes.bead => (t.numIn('cat.eye.size', .15, .18), 1.1, .44, 2.0),
      CatEyes.pill => (t.numIn('cat.eye.size', .1, .12), 2.3, .34, 3.6),
    };
    final x = gap * t.numIn('cat.eye.gap', .96, 1.06) * b.rx;
    // Big eyes never come closer than the brand cat's: past that they read
    // as one blob, so the eye shrinks instead of the gap.
    final rx = math.min(size * b.rx, x - .176 * b.rx);
    final y = face.cy + t.numIn('cat.eye.y', -.08, .03) * face.ry;
    // No seeded lean: a cat with tilted eyes reads as lopsided, not as itself.
    return [
      blob.Eye(face.cx - x, y, rx, rx * ratio, n, 0),
      blob.Eye(face.cx + x, y, rx, rx * ratio, n, 0),
    ];
  }

  /// Turns the ear around its root as one piece, so it keeps its width; only
  /// the two points where it grows from the head follow a little behind.
  Vertex _bent(Vertex v, double angle, double length) {
    const px = .72, py = -.56;
    final dx = v.x - px, dy = (v.y - py) * length;
    final a = v.y < -.7 ? angle : angle * .3;
    final c = math.cos(a), s = math.sin(a);
    return Vertex(px + dx * c - dy * s, py + dx * s + dy * c, v.soft);
  }

  /// The ear's rounded tip in body coordinates: where the rounding leaves the
  /// inner edge, the sharp corner it rounds off, and where it rejoins the
  /// outer edge. Anything drawn from the first to the last along the two
  /// edges continues the outline without a kink.
  (Offset, Offset, Offset) earTip(
    blob.Body b,
    double angle, {
    bool left = false,
  }) {
    final ear = _ear(angle);
    var i = 0;
    for (var k = 1; k < ear.length; k++) {
      if (ear[k].y < ear[i].y) i = k;
    }
    final p = ear[i], side = left ? -1.0 : 1.0;
    Offset at(Vertex to, double k) => Offset(
      b.cx + side * (p.x + (to.x - p.x) * k) * b.rx,
      b.cy + (p.y + (to.y - p.y) * k) * b.ry,
    );
    return (at(ear[i - 1], p.soft), at(p, 0), at(ear[i + 1], p.soft));
  }

  List<Vertex> _ear(double angle) => [
    for (final v in _ears[look.ears]!) _bent(v, angle, _earLength),
  ];

  List<Vertex> _side(double angle) => [
    ..._ear(angle),
    for (final v in _sides[look.head]!.take(_sides[look.head]!.length - 1))
      Vertex(
        v.x > .9 ? 1.05 + (v.x * _cheek - 1.05) * .75 : v.x * _cheek,
        v.y,
        v.soft,
      ),
  ];

  /// The whole outline as one loop, with each ear drooped by its angle in
  /// radians. Rebuilt per frame while the ears move; it is only ~24 points.
  blob.BlobPath trace(blob.Body b, {double left = 0, double right = 0}) {
    final chin = _sides[look.head]!.last;
    // The crown rises with ears set high on it: a dome between them, a
    // touch above their roots.
    final root = _ears[look.ears]!.first.y;
    final crown = root < _crown ? root - .08 : _crown;
    final loop = [
      Vertex(0, crown),
      ..._side(right),
      chin,
      for (final v in _side(left).reversed) Vertex(-v.x, v.y, v.soft),
    ];
    return _round([
      for (final v in loop)
        Vertex(b.cx + v.x * b.rx, b.cy + v.y * b.ry, v.soft),
    ]);
  }

  blob.BlobPath _round(List<Vertex> v) {
    final n = v.length;
    (double, double) toward(Vertex from, Vertex to, double k) =>
        (from.x + (to.x - from.x) * k, from.y + (to.y - from.y) * k);
    final (sx, sy) = toward(v[0], v[n - 1], v[0].soft);
    final segments = <blob.PathSegment>[blob.MoveTo(sx, sy)];
    for (var i = 0; i < n; i++) {
      final p = v[i], next = v[(i + 1) % n];
      final (ex, ey) = toward(p, next, p.soft);
      segments.add(blob.QuadTo(p.x, p.y, ex, ey));
      final (lx, ly) = toward(next, p, next.soft);
      if ((lx - ex).abs() + (ly - ey).abs() > .001) {
        segments.add(blob.LineTo(lx, ly));
      }
    }
    return blob.BlobPath([...segments, const blob.ClosePath()]);
  }
}

/// Only the commands [CatSilhouette] emits; the package bridge is private.
ui.Path toPath(blob.BlobPath path) {
  final out = ui.Path();
  for (final segment in path.segments) {
    switch (segment) {
      case blob.MoveTo(:final x, :final y):
        out.moveTo(x, y);
      case blob.LineTo(:final x, :final y):
        out.lineTo(x, y);
      case blob.QuadTo(:final cx, :final cy, :final x, :final y):
        out.quadraticBezierTo(cx, cy, x, y);
      case blob.ClosePath():
        out.close();
      default:
        break;
    }
  }
  return out;
}
