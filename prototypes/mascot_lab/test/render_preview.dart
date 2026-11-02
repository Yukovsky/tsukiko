import 'dart:io';
import 'dart:ui' as ui;
import 'package:blobatar/blobatar.dart' as blob;
import 'package:blobatar/flutter.dart' as native;
import 'package:flutter/material.dart';
import 'package:tsukiko_mascot_lab/cat.dart';

Future<void> renderMotion(String output) async {
  final dir = Directory('$output/blob-frames')..createSync(recursive: true);
  const moods = [CatMood.idle, CatMood.thinking, CatMood.happy];
  for (var index = 0; index < 72; index++) {
    final time = index * 1000 / 15;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    c.drawColor(const Color(0xff202024), BlendMode.src);
    void text(String value, double x, double y, double size, Color color) {
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(fontFamily: 'LabSans', fontSize: size, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(c, Offset(x, y));
    }

    text('tsukiko / blob cats', 35, 25, 15, const Color(0xffbcb3d3));
    text(
      'Три новых кота на родной геометрии Blobatar',
      35,
      63,
      27,
      const Color(0xffece7f5),
    );
    for (var i = 0; i < CatShape.values.length; i++) {
      final shape = CatShape.values[i];
      final p = CatProfile(shape: shape);
      final x = 32.0 + i * 318;
      c.save();
      c.translate(x + 5, 113);
      CatPainter(
        profile: p,
        mood: CatMood.idle,
        frame: () => CatFrame(
          pose: blob.idle.pose,
          motion: blob.motionAt(blob.motionSeedsFor(p.seed), time, 1),
          time: time,
        ),
      ).paint(c, const Size(280, 280));
      c.restore();
      text(shape.label, x + 38, 406, 23, const Color(0xffece7f5));
      c.save();
      c.translate(x + 24, 450);
      final renderer = native.AnimatedBlobatarRenderer(
        name: p.seed,
        options: p.options,
      );
      renderer.paint(
        c,
        const Size(54, 54),
        native.AnimatedBlobatarFrame(
          motion: blob.motionAt(blob.motionSeedsFor(p.seed), time, 0),
          pose: blob.idle.pose,
          headColor: p.head,
          eyeColor: p.eyeColor,
        ),
      );
      c.restore();
      text('исходная форма', x + 88, 466, 13, const Color(0xffbcb3d3));
      for (var j = 0; j < moods.length; j++) {
        final mood = moods[j];
        c.save();
        c.translate(x + j * 100, 542);
        CatPainter(
          profile: p,
          mood: mood,
          frame: () => CatFrame(
            pose: mood.expression.pose,
            rig: CatRig.forMood(mood),
            motion: blob.motionAt(blob.motionSeedsFor(p.seed), time, 1),
            time: time,
          ),
        ).paint(c, const Size(95, 100));
        c.restore();
      }
    }
    text('Покой · думает · радуется', 35, 657, 13, const Color(0xffbcb3d3));
    text(
      'Один seed и одна палитра. Меняется форма; глаза и эмоции рисует официальный Flutter-порт.',
      35,
      697,
      14,
      const Color(0xffbcb3d3),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(1018, 744);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      '${dir.path}/${index.toString().padLeft(3, '0')}.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
  }
}
