/// Стоит ли курсор в поле ввода — по данным «Универсального доступа»
/// на миг остановки записи. unknown — когда приложение ничего не
/// рассказывает о себе (терминалы, игры, Chromium без дерева доступности):
/// тогда ведём себя как раньше и ни о чём не предупреждаем.
enum FieldState {
  yes,
  no,
  unknown;

  static FieldState parse(Object? value) => switch (value) {
    'yes' => yes,
    'no' => no,
    _ => unknown,
  };
}

/// Запомненное место вставки: номер у родной стороны и состояние поля.
class MarkedTarget {
  const MarkedTarget(this.id, [this.field = FieldState.unknown]);
  final int id;
  final FieldState field;

  /// Ответ родной стороны: число (Windows и прежние сборки) или
  /// `{id, field}`; null — запоминать было нечего.
  static MarkedTarget? parse(Object? reply) {
    if (reply is int) return MarkedTarget(reply);
    if (reply is Map && reply['id'] is int) {
      return MarkedTarget(
        reply['id'] as int,
        FieldState.parse(reply['field']),
      );
    }
    return null;
  }
}

/// Чем кончилась вставка. Родная сторона отвечает `true`, `false` или
/// строкой `"focus"`: старый ответ `bool` читается как раньше.
enum PasteOutcome {
  /// ⌘V / Ctrl+V отправлен.
  pasted,

  /// Вставить было нечем: нет «Универсального доступа», пусто, идёт правка.
  failed,

  /// Фокус не вернулся в поле цели — вслепую вставлять не стали.
  focusLost;

  static PasteOutcome parse(Object? reply) => switch (reply) {
    true => pasted,
    'focus' => focusLost,
    _ => failed,
  };
}

/// Показывать ли на плашке «Поставьте курсор в поле». Только когда
/// поле точно не поле, настройка включена и есть к чему возвращаться.
bool showFieldHint(FieldState field, {required bool warn, required bool hasTarget}) =>
    warn && hasTarget && field == FieldState.no;
