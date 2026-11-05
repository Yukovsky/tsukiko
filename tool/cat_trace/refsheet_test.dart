import 'dart:io';
import 'dart:ui' as ui;
import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/design/cat/cat.dart';

void main() {
  test('ref sheets', () async {
    final out = Platform.environment['OUT']!;
    const cats = {
      'tsukiko': 'tsukiko',
      'lumi': 'lumi пепел полоски кисточки налегке простой хвостик',
      'yuko': 'yuko лунный месяц кисточки омега пушистый налегке простой',
    };
    const moods = [CatMood.idle, CatMood.happy, CatMood.sad, CatMood.unsure, CatMood.sleepy, CatMood.surprised];
    for (final MapEntry(key: name, value: text) in cats.entries) {
      final p = CatProfile(text);
      final r = ui.PictureRecorder();
      final c = Canvas(r);
      c.drawColor(const Color(0xffefeae7), BlendMode.src);
      for (var i = 0; i < 6; i++) {
        final mood = moods[i];
        final palette = p.colorsFor(mood.expression);
        c.save();
        c.translate(30.0 + (i % 3) * 492, 110.0 + (i ~/ 3) * 450);
        CatPainter(
          profile: p,
          mood: mood,
          glow: false,
          frame: () => CatFrame(
            body: FigureState.at(BodyPose.forMood(mood)),
            pose: mood.expression.pose,
            motion: blob.motionAt(p.seeds, 0, 0),
            rig: CatRig.forMood(mood),
            time: 900,
            headColor: CatProfile.hex(palette[blob.colorHead]!),
            eyeColor: CatProfile.hex(palette[blob.colorEye]!),
          ),
        ).paint(c, const Size(480, 420));
        c.restore();
      }
      final img = await r.endRecording().toImage(1536, 1024);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }
  });
}
