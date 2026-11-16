import Foundation

/// Проверяем появление текста, а не успешную отправку клавиши.
enum PasteVerification {
  static func expectedValue(before: String, selection: CFRange, text: String) -> String? {
    let value = before as NSString
    guard selection.location >= 0, selection.length >= 0,
      selection.location <= value.length,
      selection.length <= value.length - selection.location else { return nil }
    return value.replacingCharacters(
      in: NSRange(location: selection.location, length: selection.length), with: text)
  }

  /// Веб-редактор может отдавать завершающий перевод строки как часть абзаца,
  /// хотя его нет в буфере. Остальные пробелы и переводы строк сохраняем.
  private static func normalized(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\u{00a0}", with: " ")
    while value.hasSuffix("\n") { value.removeLast() }
    return value
  }

  static func sameContent(_ a: String, _ b: String) -> Bool {
    normalized(a) == normalized(b)
  }

  static func confirmed(before: String?, after: String?, expected: String?, text: String? = nil) -> Bool {
    guard let before, let after, !sameContent(before, after) else { return false }
    if let expected { return sameContent(after, expected) }
    // Contenteditable нередко не отдаёт AXSelectedTextRange. Для пустого поля,
    // вставки в начало и в конец всё равно можно проверить точное добавление.
    // Произвольное изменение поля подтверждением не считается.
    guard let text, !text.isEmpty else { return false }
    let old = normalized(before), inserted = normalized(text), current = normalized(after)
    return !inserted.isEmpty && (current == old + inserted || current == inserted + old)
  }
}
