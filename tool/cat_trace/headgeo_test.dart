import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/design/cat/cat.dart';
import 'package:tsukiko/design/cat/silhouette.dart';

void main() {
  test('head geometry', () {
    final out = <String, dynamic>{};
    for (final name in ['tsukiko', 'lumi пепел полоски кисточки налегке простой хвостик', 'yuko лунный месяц кисточки омега пушистый налегке простой']) {
      final p = CatProfile(name);
      final b = p.layout.body;
      final e = p.layout.eyes;
      final mx = (e[0].cx + e[1].cx) / 2, my = (e[0].cy + e[1].cy) / 2;
      final path = toPath(p.silhouette.trace(b));
      final m = path.computeMetrics().first;
      final pts = [
        for (var i = 0; i < 200; i++)
          () {
            final t = m.getTangentForOffset(m.length * i / 200)!.position;
            return [(t.dx - mx) / b.rx, (t.dy - my) / b.rx];
          }(),
      ];
      out[name.split(' ').first] = {
        'gap': (e[1].cx - e[0].cx) / b.rx,
        'chin': (b.cy + b.ry * .86 - my) / b.rx,
        'eyeR': e[0].rx / b.rx,
        'outline': pts,
      };
    }
    File('tool/cat_trace/head.json').writeAsStringSync(jsonEncode(out));
  });
}
