import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/painting.dart';

/// One choosable look. [word] is also how it is typed in the look string.
abstract interface class CatOption implements Enum {
  String get word;
}

enum CatHead implements CatOption {
  mochi('моти'),
  bun('булочка'),
  round('круглая'),
  fluff('пушистая'),
  cube('кубик');

  const CatHead(this.word);
  @override
  final String word;
}

/// A kitten is drawn smaller in its frame. Bead eyes come with it: on a
/// grown head they read as specks.
enum CatSize implements CatOption {
  grown('взрослый'),
  kitten('малыш');

  const CatSize(this.word);
  @override
  final String word;
}

enum CatEars implements CatOption {
  moon('острые'),
  tiny('кроха'),
  wide('лопухи'),
  fold('вислые'),
  tuft('кисточки'),
  bear('мишка');

  const CatEars(this.word);
  @override
  final String word;
}

enum CatEyes implements CatOption {
  moon('луны'),
  pupil('зрачки'),
  slit('щёлки'),
  bead('бусинки'),
  pill('таблетки');

  const CatEyes(this.word);
  @override
  final String word;
}

enum CatMouth implements CatOption {
  caret('уголок'),
  omega('омега'),
  fang('клычок'),
  dot('точка');

  const CatMouth(this.word);
  @override
  final String word;
}

enum CatCheeks implements CatOption {
  blush('румянец'),
  freckles('веснушки'),
  whiskers('усы'),
  plain('гладкие');

  const CatCheeks(this.word);
  @override
  final String word;
}

enum CatMark implements CatOption {
  crescent('месяц'),
  none('чистый'),
  stars('звёзды'),
  stripes('полоски'),
  mask('маска'),
  patch('пятно'),
  muzzle('мордочка');

  const CatMark(this.word);
  @override
  final String word;
}

enum CatWear implements CatOption {
  none('налегке'),
  bow('бантик'),
  flower('цветок'),
  phones('наушники'),
  cap('колпак');

  const CatWear(this.word);
  @override
  final String word;
}

/// Hand-checked colour sets: the body hue alone would not guarantee a face.
enum CatCoat implements CatOption {
  moon('лунный', 0xff8e92da, 0xffe6e4f1, 0xff2e2c6e, 0xffee7fb6),
  dusk('сумерки', 0xff5f60a4, 0xffe9e6ec, 0xff1f1e4a, 0xffd86ea8),
  sky('небо', 0xff7db6ea, 0xff123350, 0xff1c4670, 0xfff09ab4),
  mint('мята', 0xff8ad4bf, 0xff1f443d, 0xff256055, 0xfff29a9a),
  sakura('сакура', 0xfff1a8c4, 0xff4a2740, 0xff7c3560, 0xffe9608f),
  ginger('рыжий', 0xffeca65c, 0xff3b2415, 0xff7c4417, 0xffe9633f),
  cream('сливки', 0xfff2e4cf, 0xff4a372f, 0xff75584a, 0xfff0a0a0),
  wine('вино', 0xff8d4869, 0xffffe6ef, 0xff3c1a2e, 0xffe878a4),
  ash('пепел', 0xff8c8b98, 0xfff6f3ec, 0xff35343f, 0xffd98caf),
  coal('уголь', 0xff33313f, 0xffffd872, 0xff8b87a8, 0xffb0568a);

  const CatCoat(this.word, this.head, this.eye, this.ink, this.blush);
  @override
  final String word;
  final int head, eye, ink, blush;
}

/// One independent part of the look and how often a string lands on each value.
class Gene<T extends CatOption> {
  const Gene(this.title, this.key, this.values, this.weights);
  final String title, key;
  final List<T> values;
  final List<double> weights;

  /// Weighted pick from the gene's own Blobatar trait key.
  T pick(blob.Traits t) {
    final total = weights.reduce((a, b) => a + b);
    var left = t(key) * total;
    for (var i = 0; i < values.length; i++) {
      left -= weights[i];
      if (left < 0) return values[i];
    }
    return values.last;
  }
}

const headGene = Gene('Голова', 'cat.head', CatHead.values, [5, 3, 2, 2, 1]);
const sizeGene = Gene('Размер', 'cat.size', CatSize.values, [4, 1]);
const earsGene = Gene('Уши', 'cat.ears', CatEars.values, [6, 2, 2, 2, 2, 1]);
const eyesGene = Gene('Глаза', 'cat.eyes', CatEyes.values, [6, 2, 2, 2, 1]);
const mouthGene = Gene('Рот', 'cat.mouth', CatMouth.values, [5, 3, 2, 1]);
const cheeksGene = Gene('Щёки', 'cat.cheeks', CatCheeks.values, [6, 2, 2, 1]);
const markGene = Gene('Узор', 'cat.mark', CatMark.values, [
  3,
  4,
  2,
  2,
  2,
  2,
  2,
]);
const wearGene = Gene('Наряд', 'cat.wear', CatWear.values, [8, 2, 2, 2, 1]);
const coatGene = Gene('Окрас', 'cat.coat', CatCoat.values, [
  6,
  3,
  2,
  2,
  2,
  2,
  2,
  1,
  2,
  1,
]);

const List<Gene<CatOption>> genes = [
  headGene,
  sizeGene,
  earsGene,
  eyesGene,
  mouthGene,
  cheeksGene,
  markGene,
  wearGene,
  coatGene,
];

/// The brand cat: this name always resolves to each gene's first value.
const brandName = 'tsukiko';

/// Its proportions are pinned too: big low eyes with soft pupils, middle ears
/// and cheeks.
const _brandShape = {
  'cat.eye.size': .7,
  'cat.eye.gap': .45,
  'cat.eye.y': .6,
  'cat.eye.dark': .7,
  'cat.ear.long': .55,
  'cat.cheek': .5,
  'cat.head.size': .6,
  'cat.head.tall': .45,
};

String _folded(String word) => word.toLowerCase().replaceAll('ё', 'е');

/// Picked parts written as a nickname tail, `yuko-kimi`: one syllable per
/// part, its consonant naming the gene and its vowel the option. Genes with
/// more than five options run on into a second consonant.
const _vowels = 'aeiou';
const _consonants = {
  headGene: 'k',
  sizeGene: 's',
  earsGene: 'mb',
  eyesGene: 'n',
  mouthGene: 't',
  cheeksGene: 'r',
  markGene: 'ld',
  wearGene: 'p',
  coatGene: 'hv',
};

String _syllable(Gene<CatOption> gene, CatOption option) {
  final i = gene.values.indexOf(option);
  return _consonants[gene]![i ~/ 5] + _vowels[i % 5];
}

final _bySyllable = {
  for (final gene in genes)
    for (final option in gene.values) _syllable(gene, option): (gene, option),
};

/// The tail's pins, or null when it is not made only of syllables.
Map<Gene<CatOption>, CatOption>? _decode(String tail) {
  final text = tail.toLowerCase();
  if (text.isEmpty || text.length.isOdd) return null;
  final pins = <Gene<CatOption>, CatOption>{};
  for (var i = 0; i < text.length; i += 2) {
    final hit = _bySyllable[text.substring(i, i + 2)];
    if (hit == null) return null;
    pins[hit.$1] = hit.$2;
  }
  return pins;
}

/// The look string. Plain words seed the cat; a syllable tail after a hyphen
/// or a known word pins a gene, and `#rrggbb` paints any body colour.
/// Nothing else is stored anywhere.
class CatGenome {
  CatGenome._(this.seed, this.pins, this.paint);

  factory CatGenome.parse(String text) {
    final seed = <String>[];
    final pins = <Gene<CatOption>, CatOption>{};
    Color? paint;
    for (final token in text.trim().split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final hex = RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(token);
      if (hex) {
        paint = Color(0xff000000 | int.parse(token.substring(1), radix: 16));
        pins.remove(coatGene);
        continue;
      }
      final cut = token.lastIndexOf('-');
      final tail = cut < 0 ? null : _decode(token.substring(cut + 1));
      if (tail != null) {
        pins.addAll(tail);
        if (tail.containsKey(coatGene)) paint = null;
        if (cut > 0) seed.add(token.substring(0, cut));
        continue;
      }
      final match = _find(token);
      if (match == null) {
        seed.add(token);
      } else {
        pins[match.$1] = match.$2;
        if (match.$1 == coatGene) paint = null;
      }
    }
    return CatGenome._(seed.join(' '), pins, paint);
  }

  static (Gene<CatOption>, CatOption)? _find(String token) {
    final word = _folded(token);
    for (final gene in genes) {
      for (final option in gene.values) {
        if (_folded(option.word) == word) return (gene, option);
      }
    }
    return null;
  }

  /// What is left of the string once the pins are taken out.
  final String seed;
  final Map<Gene<CatOption>, CatOption> pins;
  final Color? paint;

  String get _name => seed.isEmpty ? brandName : seed;

  /// The canonical string: name, its syllable tail, then a custom colour.
  static String _write(
    String name,
    Map<Gene<CatOption>, CatOption> pins,
    Color? paint,
  ) {
    final tail = [
      for (final gene in genes)
        if (pins[gene] case final option?) _syllable(gene, option),
    ].join();
    final hex = paint == null
        ? null
        : '#${(paint.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
    return [
      if (tail.isEmpty) name else '$name-$tail',
      ?hex,
    ].where((w) => w.isNotEmpty).join(' ');
  }

  /// The same cat with one gene pinned, or back on auto when null.
  String withPin(Gene<CatOption> gene, CatOption? option) {
    final next = {...pins}..remove(gene);
    if (option != null) next[gene] = option;
    return _write(
      next.isEmpty ? seed : _name,
      next,
      gene == coatGene ? null : paint,
    );
  }

  /// The same pins on a different name.
  String withSeed(String name) => _write(name, pins, paint);

  /// Blobatar trait reader for the name part.
  blob.Traits get traits =>
      blob.traitsFor(_name, overrides: _name == brandName ? _brandShape : null);
  String get name => _name;
}

/// A fully resolved look: every gene decided.
class CatLook {
  CatLook(CatGenome g, blob.Traits t)
    : head = _gene(headGene, g, t),
      ears = _gene(earsGene, g, t),
      eyes = _gene(eyesGene, g, t),
      size =
          (g.pins[sizeGene] as CatSize?) ??
          (_gene(eyesGene, g, t) == CatEyes.bead
              ? CatSize.kitten
              : _gene(sizeGene, g, t)),
      mouth = _gene(mouthGene, g, t),
      cheeks = _gene(cheeksGene, g, t),
      mark = _gene(markGene, g, t),
      wear = _gene(wearGene, g, t),
      coat = _gene(coatGene, g, t),
      paint = g.paint;

  final CatHead head;
  final CatEars ears;
  final CatEyes eyes;
  final CatSize size;
  final CatMouth mouth;
  final CatCheeks cheeks;
  final CatMark mark;
  final CatWear wear;
  final CatCoat coat;
  final Color? paint;

  static T _gene<T extends CatOption>(
    Gene<T> gene,
    CatGenome g,
    blob.Traits t,
  ) =>
      (g.pins[gene] as T?) ??
      (g.name == brandName ? gene.values.first : gene.pick(t));

  CatOption of(Gene<CatOption> gene) => switch (gene) {
    _ when identical(gene, headGene) => head,
    _ when identical(gene, earsGene) => ears,
    _ when identical(gene, eyesGene) => eyes,
    _ when identical(gene, sizeGene) => size,
    _ when identical(gene, mouthGene) => mouth,
    _ when identical(gene, cheeksGene) => cheeks,
    _ when identical(gene, markGene) => mark,
    _ when identical(gene, wearGene) => wear,
    _ => coat,
  };

  /// Body, eye, line and blush colours, with a typed `#rrggbb` taken as is.
  (Color, Color, Color, Color) get colors {
    final custom = paint;
    if (custom == null) {
      return (
        Color(coat.head),
        Color(coat.eye),
        Color(coat.ink),
        Color(coat.blush),
      );
    }
    final dark = custom.computeLuminance() < .3;
    return (
      custom,
      dark ? const Color(0xfff6f3ec) : const Color(0xff2b2535),
      dark
          ? Color.lerp(custom, const Color(0xffffffff), .55)!
          : Color.lerp(custom, const Color(0xff1c1730), .68)!,
      const Color(0xffee7fb6),
    );
  }

  /// Dark eyes on a pale coat flip the catchlight and pupil logic.
  bool get darkEyes => colors.$2.computeLuminance() < .25;
}
