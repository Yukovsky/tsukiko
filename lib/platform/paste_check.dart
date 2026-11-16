/// Стоит ли курсор в поле ввода, по данным «Универсального доступа» на миг остановки
/// записи. unknown: приложение о себе ничего не рассказывает (терминалы, игры,
/// Chromium без дерева доступности). Это не запрещает попытку вставки.
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
      return MarkedTarget(reply['id'] as int, FieldState.parse(reply['field']));
    }
    return null;
  }
}

/// Чем кончилась вставка. Родная сторона отвечает `true`, `false` или
/// строками `"focus"` / `"unverified"`: старый ответ `bool` читается как раньше.
enum PasteOutcome {
  /// macOS: появление текста подтверждено. Прежние сборки / Windows: нажатие отправлено.
  pasted,

  /// Вставить было нечем: нет «Универсального доступа», пусто, идёт правка.
  failed,

  /// Нажатие отправлено, но появление текста в поле не подтверждено.
  unverified,

  /// Фокус не вернулся в поле цели: вслепую вставлять не стали.
  focusLost;

  static PasteOutcome parse(Object? reply) =>
      switch (reply is Map ? reply['outcome'] : reply) {
        true => pasted,
        'focus' => focusLost,
        'unverified' => unverified,
        _ => failed,
      };
}

/// Показывать ли предупреждение: поле не найдено либо не удалось проверить,
/// настройка включена и есть к чему возвращаться.
bool showFieldHint(
  FieldState field, {
  required bool warn,
  required bool hasTarget,
}) => warn && hasTarget && field != FieldState.yes;
