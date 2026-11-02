import 'dart:io';
import 'dart:ui' as ui;
import 'package:blobatar/blobatar.dart' as blob;
import 'package:flutter/material.dart';
import 'package:tsukiko_mascot_lab/cat.dart';

/// Paints [rows] of (look string, mood) cells on the lab's dark background;
/// [top] adds room above each cat for whatever grows past its frame.
Future<void> sheet(
  String path,
  List<(String, CatMood)> cells, {
  int columns = 5,
  double cell = 260,
  double top = 0,
  bool body = false,
}) async {
  final rows = (cells.length / columns).ceil();
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawColor(const Color(0xff202024), BlendMode.src);
  for (var i = 0; i < cells.length; i++) {
    final (text, mood) = cells[i];
    final p = CatProfile(text);
    final palette = p.colorsFor(mood.expression);
    c.save();
    c.translate((i % columns) * cell, (i ~/ columns) * (cell + top) + top);
    CatPainter(
      profile: p,
      mood: mood,
      body: body,
      frame: () => CatFrame(
        pose: mood.expression.pose,
        motion: blob.motionAt(p.seeds, 0, 0),
        headColor: CatProfile.hex(palette[blob.colorHead]!),
        eyeColor: CatProfile.hex(palette[blob.colorEye]!),
      ),
    ).paint(c, Size.square(cell));
    c.restore();
  }
  final image = await recorder.endRecording().toImage(
    (columns * cell).round(),
    (rows * (cell + top)).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
}
