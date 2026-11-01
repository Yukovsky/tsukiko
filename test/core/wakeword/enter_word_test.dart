import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/keyword_tokenizer.dart';

void main() {
  group('слово «с Enter»', () {
    test('вырезается только из конца фразы', () {
      expect(takeTrailingEnterWord('открой файл, вставь.', 'вставь'), (
        'открой файл',
        true,
      ));
      expect(takeTrailingEnterWord('вставь', 'Вставь'), ('', true));
      expect(takeTrailingEnterWord('вставь это в чат', 'вставь'), (
        'вставь это в чат',
        false,
      ));
      expect(takeTrailingEnterWord('надо вставьте', 'вставь'), (
        'надо вставьте',
        false,
      ));
    });

    test('пустое слово выключено', () {
      expect(takeTrailingEnterWord('ls -la', ' '), ('ls -la', false));
    });

    test('совпадение с wake или close запрещает слово', () {
      expect(effectiveEnterWord('вставь', 'Джеф', 'пока'), 'вставь');
      expect(effectiveEnterWord('Пока', 'Джеф', 'пока'), '');
      expect(effectiveEnterWord('джеф', 'Джеф', 'пока'), '');
      expect(effectiveEnterWord('', 'Джеф', 'пока'), '');
    });
  });
}
