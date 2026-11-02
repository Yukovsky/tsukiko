import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko_mascot_lab/cat.dart';
import 'package:tsukiko_mascot_lab/genome.dart';
import 'package:tsukiko_mascot_lab/main.dart';
import 'package:tsukiko_mascot_lab/silhouette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('LabSans')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
          ),
        ),
      );
    await fonts.load();
  });

  test('the look string pins genes and keeps the name', () {
    final g = CatGenome.parse('Yuko  сакура ЛОПУХИ звезды');
    expect(g.seed, 'Yuko');
    expect(CatLook(g, g.traits).coat, CatCoat.sakura);
    expect(CatLook(g, g.traits).ears, CatEars.wide);
    expect(CatLook(g, g.traits).mark, CatMark.stars);

    final swapped = CatGenome.parse(g.withPin(earsGene, CatEars.bear));
    expect(swapped.pins[earsGene], CatEars.bear);
    expect(swapped.pins[coatGene], CatCoat.sakura);
    expect(CatGenome.parse(g.withPin(earsGene, null)).pins[earsGene], isNull);
    expect(CatGenome.parse(g.withSeed('mori')).seed, 'mori');

    // Picks are written as a syllable tail, read back the same way, and a
    // hyphenated name that is not all syllables stays a name.
    expect(CatGenome.parse('yuko').withPin(earsGene, CatEars.wide), 'yuko-mi');
    expect(g.withPin(earsGene, CatEars.bear), 'Yuko-balihu');
    final tail = CatGenome.parse('yuko-mukahu');
    expect(tail.seed, 'yuko');
    expect(tail.pins, {
      headGene: CatHead.mochi,
      earsGene: CatEars.tuft,
      coatGene: CatCoat.sakura,
    });
    expect(CatGenome.parse('anna-maria').seed, 'anna-maria');
    expect(CatGenome.parse('').withPin(eyesGene, CatEyes.bead), 'tsukiko-no');

    final painted = CatGenome.parse('yuko #7fb8ec');
    expect(painted.seed, 'yuko');
    expect(painted.paint, const Color(0xff7fb8ec));
    expect(CatGenome.parse(painted.withPin(coatGene, null)).paint, isNull);
    expect(CatGenome.parse('сакура').name, brandName);

    CatLook resolve(String text) {
      final g = CatGenome.parse(text);
      return CatLook(g, g.traits);
    }

    expect(resolve('mori бусинки').size, CatSize.kitten);
    expect(resolve('mori бусинки взрослый').size, CatSize.grown);

    final brand = CatGenome.parse(brandName);
    final look = CatLook(brand, brand.traits);
    expect(genes.map(look.of), genes.map((g) => g.values.first));
  });

  test('names spread over every gene', () {
    final looks = [
      for (var i = 0; i < 400; i++)
        () {
          final g = CatGenome.parse('cat$i');
          return CatLook(g, g.traits);
        }(),
    ];
    for (final gene in genes) {
      expect(
        looks.map((l) => l.of(gene)).toSet().length,
        gene.values.length,
        reason: gene.title,
      );
    }
  });

  test('every head and ear stays inside the frame at any droop', () {
    for (final head in CatHead.values) {
      for (final ears in CatEars.values) {
        for (final seed in ['yuko', 'mori', 'lumi', 'cat7']) {
          final p = CatProfile('$seed ${head.word} ${ears.word}');
          for (final droop in [-.2, 0.0, .6]) {
            final box = toPath(
              p.silhouette.trace(p.layout.body, left: droop, right: droop),
            ).getBounds();
            expect(box.top, greaterThan(-6), reason: p.text);
            expect(box.left, greaterThan(-6), reason: p.text);
            expect(box.right, lessThan(106), reason: p.text);
            expect(box.bottom, lessThan(106), reason: p.text);
            if (ears == CatEars.tuft) {
              // The hair reaches past the corner the outline rounds off.
              final (_, corner, _) = p.silhouette.earTip(p.layout.body, droop);
              expect(corner.dy - .3 * p.layout.body.rx, greaterThan(-6));
            }
          }
        }
      }
    }
  });

  testWidgets('pinning, moods and petting all work from the lab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MascotLab());
    await tester.pump(const Duration(milliseconds: 300));

    String look() => tester
        .widget<TextField>(find.byKey(const ValueKey('look')))
        .controller!
        .text;

    await tester.tap(find.byKey(const ValueKey('option-лопухи')));
    await tester.pump();
    expect(look(), 'tsukiko-mi');
    await tester.tap(find.byKey(const ValueKey('option-лопухи')));
    await tester.pump();
    expect(look(), 'tsukiko');

    await tester.tap(find.text('Слушает'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('hero')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Записывает'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1400));

    await tester.tap(find.byTooltip('Остановить движение'));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layout survives a phone width', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MascotLab());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
