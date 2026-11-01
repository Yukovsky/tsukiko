import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/dictation/enter_mark.dart';

void main() {
  group('lastMarkable', () {
    test('берёт последнее недоставленное и неотменённое', () {
      final a = EnterMark(), b = EnterMark(), c = EnterMark();
      c.aborted = true;
      expect(lastMarkable([a, b, c]), same(b));
      b.delivering = true;
      expect(lastMarkable([a, b, c]), same(a));
    });

    test('без подходящих — null', () {
      final a = EnterMark()..delivering = true;
      expect(lastMarkable([a]), isNull);
      expect(lastMarkable(const []), isNull);
    });
  });

  group('clearEnterBefore', () {
    test('снимает пометку у прежних, кроме доставляемых', () {
      final queued = EnterMark()..enter = true;
      final delivering = EnterMark()
        ..enter = true
        ..delivering = true;
      clearEnterBefore([delivering, queued]);
      expect(queued.enter, isFalse);
      expect(delivering.enter, isTrue);
    });

    test('новое задание без пометки всё равно снимает чужие', () {
      final earlier = EnterMark()..enter = true;
      final fresh = EnterMark();
      clearEnterBefore([earlier]);
      expect(earlier.enter, isFalse);
      expect(fresh.enter, isFalse);
    });
  });
}
