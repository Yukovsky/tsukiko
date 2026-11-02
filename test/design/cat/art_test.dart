import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/design/cat/cat.dart';
import 'package:tsukiko/design/cat/genome.dart';
import 'art_sheet.dart';

void main() {
  final out = Platform.environment['PREVIEW_DIR'];
  test('art sheets', skip: out == null, () async {
    await sheet(
      '$out/moon-cats-parts.png',
      [
        for (final head in CatHead.values)
          for (final ears in CatEars.values)
            ('tsukiko ${head.word} ${ears.word}', CatMood.idle),
      ],
      columns: 6,
      cell: 200,
      top: 24,
    );
    await sheet(
      '$out/moon-cats-moods.png',
      [for (final mood in CatMood.values) ('tsukiko', mood)],
      cell: 240,
      top: 24,
    );
    await sheet(
      '$out/moon-cats-names.png',
      [
        for (final name in const [
          'tsukiko',
          'yuko',
          'mori',
          'komorebi',
          'nori',
          'lumi',
          'sora',
          'hana',
          'kuro',
          'momo',
          'yuki',
          'aki',
          'ren',
          'miso',
          'taro',
        ])
          (name, CatMood.idle),
      ],
      cell: 220,
      top: 24,
    );
  });
}
