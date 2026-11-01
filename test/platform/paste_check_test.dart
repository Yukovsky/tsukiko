import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/paste_check.dart';

void main() {
  group('PasteOutcome.parse', () {
    test('старый ответ bool читается как раньше', () {
      expect(PasteOutcome.parse(true), PasteOutcome.pasted);
      expect(PasteOutcome.parse(false), PasteOutcome.failed);
      expect(PasteOutcome.parse(null), PasteOutcome.failed);
    });

    test('"focus" — курсор не в поле', () {
      expect(PasteOutcome.parse('focus'), PasteOutcome.focusLost);
      expect(PasteOutcome.parse('что-то другое'), PasteOutcome.failed);
    });
  });

  group('MarkedTarget.parse', () {
    test('число — как у Windows и прежних сборок', () {
      final t = MarkedTarget.parse(7)!;
      expect(t.id, 7);
      expect(t.field, FieldState.unknown);
    });

    test('карта с состоянием поля', () {
      expect(MarkedTarget.parse({'id': 3, 'field': 'no'})!.field, FieldState.no);
      expect(MarkedTarget.parse({'id': 3, 'field': 'yes'})!.field, FieldState.yes);
      expect(MarkedTarget.parse({'id': 3, 'field': 'x'})!.field, FieldState.unknown);
    });

    test('нечего запоминать', () {
      expect(MarkedTarget.parse(null), isNull);
      expect(MarkedTarget.parse({'field': 'no'}), isNull);
    });
  });

  group('showFieldHint', () {
    test('подсказка только при явном «не поле»', () {
      expect(showFieldHint(FieldState.no, warn: true, hasTarget: true), isTrue);
      expect(showFieldHint(FieldState.yes, warn: true, hasTarget: true), isFalse);
      expect(
        showFieldHint(FieldState.unknown, warn: true, hasTarget: true),
        isFalse,
      );
    });

    test('выключенная настройка или нет цели — без подсказки', () {
      expect(showFieldHint(FieldState.no, warn: false, hasTarget: true), isFalse);
      expect(showFieldHint(FieldState.no, warn: true, hasTarget: false), isFalse);
    });
  });
}
