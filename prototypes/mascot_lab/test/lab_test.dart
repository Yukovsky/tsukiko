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
    final loader = FontLoader('LabSans');
    loader.addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
        ),
      ),
    );
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets(
    'full and face rigs retain recording during petting and fit a small window',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const captureKey = ValueKey('capture');
      await tester.pumpWidget(
        const RepaintBoundary(key: captureKey, child: MascotLab()),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LivingCat), findsNWidgets(3));
      expect(find.text('Кот целиком'), findsOneWidget);
      expect(find.text('Только мордочка'), findsOneWidget);
      final painted = find.descendant(
        of: find.byKey(const ValueKey('cat-full')),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is CatPainter,
        ),
      );
      CatFrame frame() =>
          (tester.widget<CustomPaint>(painted).painter! as CatPainter).frame();
      final idle = frame().rig!;
      await tester.tap(find.text('Слушает').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(frame().rig!.headY, lessThan(idle.headY - 3));
      expect(frame().rig!.attention, 1);
      await tester.tap(find.byKey(const ValueKey('cat-full')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(frame().pet, greaterThan(0));
      expect(frame().rig!.attention, 1);
      expect(find.text('Записывает · демо'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1400));
      expect(frame().rig!.attention, 1);
      await tester.tap(find.text('Думает').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      final interruptedTilt = frame().rig!.headTilt;
      await tester.tap(find.text('Радуется').first);
      await tester.pump();
      expect(frame().rig!.headTilt, closeTo(interruptedTilt, .0001));
      await tester.pump(const Duration(milliseconds: 500));
      expect(frame().rig!.smile, 1);
      await tester.tap(find.text('Покой'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Остановить'));
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      final output = Platform.environment['PREVIEW_DIR'];
      if (output != null) {
        await tester.runAsync(() async {
          Directory(output).createSync(recursive: true);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$output/living-cat-lab.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
          if (Platform.environment['MOTION_PREVIEW'] == '1')
            await renderMotion(output);
        });
      }
      await tester.enterText(find.byType(TextFormField), 'komorebi');
      await tester.pump();
      expect(
        tester
            .widget<LivingCat>(find.byKey(const ValueKey('cat-full')))
            .profile
            .kind,
        CatKind.personal,
      );
      expect(
        tester
            .widget<LivingCat>(find.byKey(const ValueKey('cat-face')))
            .profile
            .seed,
        'komorebi',
      );
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion has no continuous frames and supports keyboard poke',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: LivingCat(
              profile: CatProfile(kind: CatKind.moon),
              mood: CatMood.thinking,
            ),
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'gaze follows the pointer, releases smoothly, and stops when paused',
    (tester) async {
      Widget subject(bool animate) => MaterialApp(
        home: Center(
          child: LivingCat(
            key: const ValueKey('subject'),
            profile: CatProfile(kind: CatKind.moon),
            animate: animate,
          ),
        ),
      );
      await tester.pumpWidget(subject(true));
      final painted = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CatPainter,
      );
      CatFrame frame() =>
          (tester.widget<CustomPaint>(painted).painter! as CatPainter).frame();
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
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
    },
  );

  test(
    'every expression paints at extreme proportions, with deterministic profiles',
    () {
      for (final word in ['yuko', '日本語', '🌙', 'Кот', '']) {
        final p = CatProfile(kind: CatKind.personal, seed: word);
        expect(p.head, CatProfile(kind: CatKind.personal, seed: word).head);
        for (final expression in blob.expressions) {
          for (final eye in [.75, 1.2]) {
            final recorder = ui.PictureRecorder();
            CatPainter(
              profile: CatProfile(
                kind: CatKind.personal,
                seed: word,
                eyeScale: eye,
                width: 1.14,
                ears: 1.15,
                form: 2,
              ),
              mood: CatMood.idle,
              frame: () => CatFrame(
                pose: expression.pose,
                motion: blob.motionAt(blob.motionSeedsFor(word), 500, 1),
              ),
            ).paint(Canvas(recorder), const Size(320, 320));
            recorder.endRecording().dispose();
          }
        }
      }
    },
  );
}
