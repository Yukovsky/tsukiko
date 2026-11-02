import 'dart:io';
import 'dart:ui' as ui;

import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/design/cat/cat.dart';

/// Кот для образа macOS и мастера установки Windows: design/dmg-mascot.png,
/// из него рисуют tool/dmg-background.py и tool/installer-images.py.
/// Запуск: BRAND_ART=1 flutter test test/design/cat/brand_art_test.dart
void main() {
  test('brand art', skip: Platform.environment['BRAND_ART'] == null, () async {
    const side = 1024.0;
    final profile = CatProfile('tsukiko');
    const mood = CatMood.happy;
    final palette = profile.colorsFor(mood.expression);
    final recorder = ui.PictureRecorder();
    CatPainter(
      profile: profile,
      mood: mood,
      glow: false,
      frame: () => CatFrame(
        pose: mood.expression.pose,
        motion: blob.motionAt(profile.seeds, 0, 0),
        headColor: CatProfile.hex(palette[blob.colorHead]!),
        eyeColor: CatProfile.hex(palette[blob.colorEye]!),
      ),
    ).paint(Canvas(recorder), const Size.square(side));
    final image = await recorder.endRecording().toImage(
      side.round(),
      side.round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('design/dmg-mascot.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
