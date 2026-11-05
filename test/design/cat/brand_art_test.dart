import 'dart:io';
import 'dart:ui' as ui;

import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/design/cat/cat.dart';

/// Кот для образа macOS и мастера установки Windows: design/dmg-mascot.png
/// (голова), из него рисуют tool/dmg-background.py и
/// tool/installer-images.py. Заодно кот целиком для README:
/// docs/images/mascot.png.
/// Запуск: BRAND_ART=1 flutter test test/design/cat/brand_art_test.dart
void main() {
  test('brand art', skip: Platform.environment['BRAND_ART'] == null, () async {
    final profile = CatProfile('tsukiko');
    const mood = CatMood.happy;
    final palette = profile.colorsFor(mood.expression);

    Future<void> paint(String path, double side, {required bool body}) async {
      final recorder = ui.PictureRecorder();
      CatPainter(
        profile: profile,
        mood: mood,
        glow: false,
        frame: () => CatFrame(
          body: body ? FigureState.at(BodyPose.forMood(mood)) : null,
          pose: mood.expression.pose,
          motion: blob.motionAt(profile.seeds, 0, 0),
          headColor: CatProfile.hex(palette[blob.colorHead]!),
          eyeColor: CatProfile.hex(palette[blob.colorEye]!),
        ),
      ).paint(Canvas(recorder), Size.square(side));
      final image = await recorder.endRecording().toImage(
        side.round(),
        side.round(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await paint('design/dmg-mascot.png', 1024, body: false);
    await paint('docs/images/mascot.png', 512, body: true);
  });
}
