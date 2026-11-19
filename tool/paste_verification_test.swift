import Foundation

@main
struct PasteVerificationTests {
  static func main() {
    // Пустое поле Codex отдаёт подсказку как значение: важно лишь, что поле изменилось.
    assert(PasteVerification.verdict(before: "Ask Codex anything", after: "привет") == .pasted)
    assert(PasteVerification.verdict(before: "#0", after: "#6") == .pasted)
    assert(PasteVerification.verdict(before: "ab", after: "ab") == .unchanged)
    assert(PasteVerification.verdict(before: nil, after: "x") == .unknown)
    assert(PasteVerification.verdict(before: "x", after: nil) == .unknown)
    print("Paste verification checks passed")
  }
}
