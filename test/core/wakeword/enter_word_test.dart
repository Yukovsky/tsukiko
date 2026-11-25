import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/keyword_tokenizer.dart';

void main() {
  group('слово «с Enter»', () {
    test('совпадение с wake или close запрещает слово', () {
      expect(effectiveEnterWord('вставь', 'Джеф', 'пока'), 'вставь');
      expect(effectiveEnterWord('Пока', 'Джеф', 'пока'), '');
      expect(effectiveEnterWord('джеф', 'Джеф', 'пока'), '');
      expect(effectiveEnterWord('', 'Джеф', 'пока'), '');
    });
  });
}
