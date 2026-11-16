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

  static func confirmed(before: String?, after: String?, expected: String?) -> Bool {
    guard let before, let after, let expected else { return false }
    return before != after && after == expected
  }
}
