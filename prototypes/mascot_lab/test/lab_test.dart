import 'dart:io';
import 'dart:ui' as ui;
import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko_mascot_lab/cat.dart';
import 'package:tsukiko_mascot_lab/main.dart';
import 'render_preview.dart';

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
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'three native shapes share controls and keep recording during petting',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const capture = ValueKey('capture');
      await tester.pumpWidget(
        const RepaintBoundary(key: capture, child: MascotLab()),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LivingCat), findsNWidgets(4));
      for (final shape in CatShape.values) {
        expect(
          tester
              .widget<LivingCat>(find.byKey(ValueKey('cat-${shape.name}')))
              .profile
              .layout
              .shape,
          switch (shape) {
            CatShape.round => 'round',
            CatShape.square => 'boxy',
            CatShape.drop => 'droplet',
          },
        );
      }
      final painted = find.descendant(
        of: find.byKey(const ValueKey('cat-round')),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is CatPainter,
        ),
      );
      CatFrame frame() =>
          (tester.widget<CustomPaint>(painted).painter! as CatPainter).frame();
      await tester.tap(find.text('Слушает').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(frame().rig!.attention, 1);
      await tester.tap(find.byKey(const ValueKey('cat-round')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(frame().pet, greaterThan(0));
      expect(find.text('Записывает · демо'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1400));
      expect(frame().rig!.attention, 1);
      await tester.tap(find.text('Сердится'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final tint = frame().headColor;
      await tester.tap(find.text('Влюблён'));
      await tester.pump();
      expect(
        frame().headColor,
        tint,
      ); // Retarget from the current tint, without a jump.
      await tester.tap(find.text('Покой'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Остановить движение'));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      final output = Platform.environment['PREVIEW_DIR'];
      if (output != null)
        await tester.runAsync(() async {
          Directory(output).createSync(recursive: true);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(capture),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$output/blob-cats-lab.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
          if (Platform.environment['MOTION_PREVIEW'] == '1')
            await renderMotion(output);
        });
      await tester.enterText(find.byType(TextFormField), 'komorebi');
      await tester.pump();
      for (final shape in CatShape.values) {
        expect(
          tester
              .widget<LivingCat>(find.byKey(ValueKey('cat-${shape.name}')))
              .profile
              .seed,
          'komorebi',
        );
      }
      await tester.tap(find.byKey(const ValueKey('cat-drop')));
      await tester.pump();
      expect(
        tester
            .widget<LivingCat>(find.byKey(const ValueKey('compact-cat')))
            .profile
            .shape,
        CatShape.drop,
      );
      await tester.pump(const Duration(milliseconds: 1300));
      for (final width in [536.0, 390.0]) {
        tester.view.physicalSize = Size(width, 844);
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reduced motion stops frames and keeps keyboard reaction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: LivingCat(profile: CatProfile(), mood: CatMood.thinking),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('Подмигнул')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gaze pursues, releases and pauses', (tester) async {
    Widget subject(bool active) => MaterialApp(
      home: Center(
        child: LivingCat(
          profile: CatProfile(),
          animate: active,
          key: const ValueKey('subject'),
        ),
      ),
    );
    await tester.pumpWidget(subject(true));
    final painted = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is CatPainter,
    );
    CatFrame frame() =>
        (tester.widget<CustomPaint>(painted).painter! as CatPainter).frame();
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(painted) + const Offset(80, -45));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(frame().gaze.dx, greaterThan(1));
    expect(frame().gaze.dy, lessThan(-.4));
    await mouse.moveTo(Offset.zero);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(frame().gaze.distance, lessThan(.05));
    await tester.pumpWidget(subject(false));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'all native expressions and seeded shapes fit the transparent frame',
    () async {
      for (final word in ['yuko', '日本語', '🌙', 'Кот', '']) {
        for (final shape in CatShape.values) {
          final p = CatProfile(seed: word, shape: shape);
          expect(
            blob.contrast(
              blob.fromHex(p.base[blob.colorHead]!),
              blob.fromHex(p.base[blob.colorEye]!),
            ),
            greaterThanOrEqualTo(4.5),
          );
          for (final mood in CatMood.values) {
            final recorder = ui.PictureRecorder();
            CatPainter(
              profile: p,
              mood: mood,
              frame: () => CatFrame(
                pose: mood.expression.pose,
                rig: CatRig.forMood(mood),
                motion: blob.motionAt(blob.motionSeedsFor(word), 700, 1),
                gaze: const Offset(3, -2),
                tracking: 1,
              ),
            ).paint(Canvas(recorder), const Size(128, 128));
            final picture = recorder.endRecording();
            final image = await picture.toImage(128, 128);
            final data = (await image.toByteData())!.buffer.asUint8List();
            for (var i = 0; i < 128; i++) {
              for (final index in [
                i * 4 + 3,
                ((127 * 128 + i) * 4) + 3,
                (i * 128 * 4) + 3,
                ((i * 128 + 127) * 4) + 3,
              ]) {
                expect(
                  data[index],
                  0,
                  reason:
                      '$word / ${shape.name} / ${mood.name} clips the frame',
                );
              }
            }
            image.dispose();
            picture.dispose();
          }
        }
      }
    },
  );
}
