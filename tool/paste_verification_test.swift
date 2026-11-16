import Foundation

@main
struct PasteVerificationTests {
  static func main() {
    func expected(_ before: String, _ location: Int, _ length: Int, _ text: String) -> String? {
      PasteVerification.expectedValue(
        before: before, selection: CFRange(location: location, length: length), text: text)
    }
    assert(expected("ab", 1, 0, "текст") == "aтекстb")
    assert(expected("hello world", 6, 5, "мир") == "hello мир")
    assert(expected("🐈abc", 2, 1, "🌙") == "🐈🌙bc")
    assert(expected("", 0, 0, "текст") == "текст")
    assert(expected("ab", -1, 0, "x") == nil)
    assert(expected("ab", 1, 2, "x") == nil)
    assert(expected("ab", Int.max, Int.max, "x") == nil)
    assert(PasteVerification.confirmed(before: "ab", after: "axb", expected: "axb"))
    assert(!PasteVerification.confirmed(before: "ab", after: "ab", expected: "axb"))
    assert(!PasteVerification.confirmed(before: "ab", after: "user edit", expected: "axb"))
    assert(!PasteVerification.confirmed(before: nil, after: "x", expected: "x"))
    assert(!PasteVerification.confirmed(before: "", after: nil, expected: "x"))
    assert(!PasteVerification.confirmed(before: "x", after: "x", expected: "x"))
    print("Paste verification checks passed")
  }
}
