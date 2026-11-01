/// Пометка «после вставки нажать Enter» у задания диктовки.
///
/// Правила живут здесь, а не в кубите, чтобы их можно было проверить без
/// микрофона и очереди.
class EnterMark {
  /// Нажать Enter после вставки этого задания.
  bool enter = false;

  /// Текст уже вставляется: пометку менять поздно.
  bool delivering = false;

  /// Распознавание прервали крестиком.
  bool aborted = false;

  bool get markable => !delivering && !aborted;
}

/// Последнее ещё не доставленное задание — то, чью пометку переключает
/// «Отправить» в тот миг, когда записи нет. [jobs] идут по порядку очереди,
/// начиная с распознаваемого.
EnterMark? lastMarkable(Iterable<EnterMark> jobs) {
  EnterMark? last;
  for (final j in jobs) {
    if (j.markable) last = j;
  }
  return last;
}

/// Новое задание встаёт в очередь: у всех прежних, ещё не доставляемых,
/// пометка снимается — всегда, помечено новое или нет. Enter остаётся
/// только у последнего, иначе он упал бы в середину чужой серии вставок.
void clearEnterBefore(Iterable<EnterMark> earlier) {
  for (final j in earlier) {
    if (j.markable) j.enter = false;
  }
}
