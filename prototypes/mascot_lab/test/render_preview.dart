import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/material.dart';
import 'package:tsukiko_mascot_lab/cat.dart';

/// Export frames from the production painter, rather than a second animation.
Future<void> renderMotion(String output) async {
  final directory = Directory('$output/frames')..createSync(recursive: true);
  final p = CatProfile(kind: CatKind.moon);
  final seeds = blob.motionSeedsFor(p.motionSeed);
  const moods = [
    CatMood.idle,
    CatMood.listening,
    CatMood.thinking,
    CatMood.happy,
  ];
  for (var i = 0; i < 72; i++) {
    final elapsed = i * 1000 / 15;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    c.drawColor(const Color(0xff222223), BlendMode.src);
    void text(String label, double x, double y, double size, Color color) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontFamily: 'LabSans', fontSize: size, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(c, Offset(x, y));
    }

    text('tsukiko / живая мастерская', 32, 24, 15, const Color(0xffbdb8cd));
    text('Состояние меняет всего кота', 32, 62, 30, const Color(0xffebe7f1));
    for (var j = 0; j < moods.length; j++) {
      final mood = moods[j];
      final rig = CatRig.forMood(mood);
      final x = 18.0 + j * 240;
      final frame = CatFrame(
        pose: mood.expression.pose,
        rig: rig,
        motion: blob.motionAt(seeds, elapsed, 1),
        time: elapsed,
        speech: mood == CatMood.listening
            ? .65 * (.35 + .65 * math.pow(math.sin(elapsed / 130), 2))
            : 0,
      );
      c.save();
      c.translate(x, 107);
      CatPainter(
        profile: p,
        mood: mood,
        frame: () => frame,
      ).paint(c, const Size(230, 276));
      c.restore();
      text(mood.label, x + 58, 398, 18, const Color(0xffe2ddea));
      c.save();
      c.translate(x + 52, 438);
      CatPainter(
        profile: p,
        mood: mood,
        view: CatView.face,
        frame: () => frame,
      ).paint(c, const Size(124, 113));
      c.restore();
    }
    text(
      'Целый кот и компактная мордочка · общий профиль и эмоции Blobatar',
      32,
      575,
      14,
      const Color(0xffbdb8cd),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(996, 610);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      '${directory.path}/${i.toString().padLeft(3, '0')}.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  }
}
