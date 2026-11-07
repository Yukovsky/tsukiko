import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/queue/paste.dart';

/// ⌘V (Ctrl+V) в окне очереди.
void main() {
  late Directory dir;
  late String song, notes;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tsukiko_paste');
    song = (File('${dir.path}/песня.mp3')..writeAsStringSync('')).path;
    notes = (File('${dir.path}/заметки.xlsx')..writeAsStringSync('')).path;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<List<String>> paste({List<String>? files, String? text}) =>
      pastedPaths(files: () async => files, text: () async => text);

  group('pastedPaths', () {
    test('файлы из буфера идут как есть, текст тогда не читается', () async {
      var textRead = false;
      final got = await pastedPaths(
        files: () async => [song, notes],
        text: () async {
          textRead = true;
          return song;
        },
      );
      expect(got, [song, notes],
          reason: 'неподходящий файл тоже идёт: очередь сама скажет, '
              'что такие не берёт');
      expect(textRead, isFalse);
    });

    test('путь, скопированный текстом, принимается', () async {
      expect(await paste(text: song), [song]);
      expect(await paste(files: const [], text: '"$song"'), ['"$song"'],
          reason: '«Копировать как путь» в Проводнике даёт путь в кавычках');
      expect(await paste(text: Uri.file(song).toString()),
          [Uri.file(song).toString()]);
      expect(await paste(text: '$song\r\n${dir.path}\n'), [song, dir.path],
          reason: 'несколько путей и папка, строки по CRLF и LF');
    });

    test('обычный текст вне поля ввода никуда не идёт', () async {
      expect(await paste(text: 'привет, мир'), isEmpty);
      expect(await paste(text: '$song\nи ещё строка'), isEmpty,
          reason: 'хоть одна строка не путь, значит это текст');
      expect(await paste(text: '${dir.path}/нет-такого.mp3'), isEmpty);
      expect(await paste(text: '   \n'), isEmpty);
      expect(await paste(), isEmpty, reason: 'буфер пуст');
    });

    test('раннер упал: остаётся текст', () async {
      final got = await pastedPaths(
        files: () async => throw PlatformException(code: 'boom'),
        text: () async => song,
      );
      expect(got, [song]);
    });
  });

  testWidgets('в поле ввода ⌘V остаётся вставкой текста', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': 'из буфера'}
          : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final field = TextEditingController();
    final button = FocusNode();
    addTearDown(field.dispose);
    addTearDown(button.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: Column(children: [
          TextField(controller: field),
          Focus(focusNode: button, child: const SizedBox(width: 10, height: 10)),
        ]),
      ),
    ));

    button.requestFocus();
    await tester.pump();
    expect(textFieldFocused(), isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(textFieldFocused(), isTrue);
    // Ровно так окно очереди отдаёт ⌘V полю.
    Actions.maybeInvoke(primaryFocus!.context!,
        const PasteTextIntent(SelectionChangedCause.keyboard));
    await tester.pumpAndSettle();
    expect(field.text, 'из буфера');
  });
}
