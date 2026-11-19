import Foundation

/// Изменилось ли поле после ⌘V. Снимок — текст поля или число символов.
enum PasteVerification {
  enum Verdict { case pasted, unchanged, unknown }

  static func verdict(before: String?, after: String?) -> Verdict {
    guard let before, let after else { return .unknown }
    return before == after ? .unchanged : .pasted
  }
}
