import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/models.dart';

void main() {
  test('пункты меню моделей: подпись, значение, отметка выбранной', () {
    final items = modelMenuItems([
      '/m/ggml-small.bin',
      '/m/ggml-base.bin',
    ], '/m/ggml-base.bin');
    expect(items.map((e) => e['value']), [
      '/m/ggml-small.bin',
      '/m/ggml-base.bin',
    ]);
    expect(items.map((e) => e['checked']), [false, true]);
    expect(items.every((e) => (e['title'] as String).isNotEmpty), isTrue);
    expect(modelMenuItems(['/m/a.bin'], null).single['checked'], false);
  });
}
