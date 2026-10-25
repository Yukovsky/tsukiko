import Cocoa

@main
struct HUDPlacementTests {
  static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
  static func main() {
    let model = HUDModel()
    model.state = .transcribing; model.processing = true
    assert(model.queueCount == 0 && model.size.width == 372)
    model.pending = 1
    assert(model.queueCount == 1 && model.size.width == 420)
    model.state = .recording
    assert(model.queueCount == 2)
    model.pending = 0
    assert(model.queueCount == 1)
    model.processing = false
    assert(model.queueCount == 0 && model.size.width == 372)
    model.pending = 1; model.state = .transcribing
    assert(model.queueCount == 0)
    model.pending = 9; model.processing = true
    assert(model.queueCount == 9)
    var layout = HUDPlacement()
    let work = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
    let size = NSSize(width: 372, height: 52)
    var point = layout.origin(in: work, size: size)
    assert(near(point.x, -1146) && near(point.y, -108))
    point = layout.snap(NSPoint(x: -1140, y: 309), in: work, size: size)
    assert(near(point.x, -1146) && near(point.y, 314))
    point = layout.snap(NSPoint(x: -1120, y: 285), in: work, size: size)
    assert(near(point.x, -1120) && near(point.y, 285))
    point = layout.clamp(NSPoint(x: -5000, y: 5000), in: work, size: size)
    assert(near(point.x, -1920) && near(point.y, 828))
    point = layout.clamp(NSPoint(x: 9999, y: 9999),
                         in: NSRect(x: 20, y: 30, width: 100, height: 20), size: size)
    assert(near(point.x, 20) && near(point.y, 30))
    layout.capture(origin: NSPoint(x: -1146, y: 314), in: work, size: size)
    assert(near(layout.x!, 0.5) && near(layout.y!, 0.5))
    point = layout.origin(in: NSRect(x: 100, y: 50, width: 2560, height: 1440),
                          size: NSSize(width: 744, height: 104))
    assert(near(point.x + 372, 1380) && near(point.y + 52, 770))
    assert(near(HUDPlacement.validScale(0.1), 0.8))
    assert(near(HUDPlacement.validScale(20), 1.6))
    assert(near(HUDPlacement.validScale(.nan), 1))
    assert(near(HUDPlacement.validScale(.infinity), 1))
    assert(HUDPlacement(x: .nan, y: .infinity).x == nil)
    assert(HUDPlacement(x: .nan, y: .infinity).y == nil)
    for i in 0...100 {
      let p = layout.clamp(NSPoint(x: work.minX + Double(i) * 19.2,
                                   y: work.minY + Double(i) * 10.8), in: work, size: size)
      layout.capture(origin: p, in: work, size: size)
      let restored = layout.origin(in: work, size: size)
      assert(near(restored.x, p.x) && near(restored.y, p.y))
    }
    let controls = NSSize(width: 360, height: 228)
    for corner in 0..<4 {
      let collision = HUDLayoutControls.frame(in: work, size: controls, corner: corner)
      let next = HUDLayoutControls.corner(in: work, size: controls, avoiding: collision, current: corner)
      assert(next != corner)
      assert(!HUDLayoutControls.frame(in: work, size: controls, corner: next).intersects(collision.insetBy(dx: -32, dy: -32)))
      assert(HUDLayoutControls.corner(in: work, size: controls, avoiding: collision, current: next) == next)
    }
    assert(HUDLayoutControls.corner(in: work, size: controls, avoiding: .zero, current: 2) == 2)
    let before = layout
    var draft = layout
    draft.capture(origin: NSPoint(x: -1500, y: 500), in: work, size: size)
    draft.scale = 1.4
    draft = before
    assert(draft.x == before.x && draft.y == before.y && draft.scale == before.scale)
    draft = HUDPlacement()
    assert(draft.x == nil && draft.y == nil && draft.scale == 1)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let suite = "tsukiko-hud-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func makeHUD() -> RecordingHUD {
      RecordingHUD(onCancel: {}, onStop: {}, onAbort: {}, onClearQueue: {}, onRecord: {}, defaults: defaults)
    }
    let hud = makeHUD()
    assert(hud.previewFrame.width == 372)
    let idleCenter = NSPoint(x: hud.previewFrame.midX, y: hud.previewFrame.midY)
    hud.updateQueue(pending: 9, processing: true)
    assert(hud.previewFrame.width == 420)
    assert(near(hud.previewFrame.midX, idleCenter.x) && near(hud.previewFrame.midY, idleCenter.y))
    hud.updateQueue(pending: 0, processing: false)
    assert(hud.previewFrame.width == 372)
    hud.updateQueue(pending: 0, processing: true)
    assert(hud.previewFrame.width == 372)
    hud.transcribing()
    let singleCenter = NSPoint(x: hud.previewFrame.midX, y: hud.previewFrame.midY)
    hud.show() // A second recording has one dictation ahead of it.
    assert(hud.previewFrame.width == 420)
    assert(near(hud.previewFrame.midX, singleCenter.x) && near(hud.previewFrame.midY, singleCenter.y))
    hud.transcribing()
    assert(hud.previewFrame.width == 372)
    assert(near(hud.previewFrame.midX, singleCenter.x) && near(hud.previewFrame.midY, singleCenter.y))
    hud.updateQueue(pending: 1, processing: true)
    assert(hud.previewFrame.width == 420)
    hud.updateQueue(pending: 0, processing: true)
    assert(hud.previewFrame.width == 372)
    assert(near(hud.previewFrame.midX, singleCenter.x) && near(hud.previewFrame.midY, singleCenter.y))
    hud.updateQueue(pending: 0, processing: false)
    hud.hide()
    hud.configure(labels: [:])
    assert(hud.isEditing && hud.isVisible && hud.previewFrame.width == 420)
    hud.setScale(1.4)
    hud.finishEditing(save: false)
    assert(!hud.isEditing && !hud.isVisible && hud.currentPlacement.scale == 1)
    assert(defaults.dictionary(forKey: "dictationHUDPlacement") == nil)
    hud.configure(labels: [:])
    hud.setScale(1.3)
    if let path = ProcessInfo.processInfo.environment["TSUKIKO_HUD_PREVIEW"],
       let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 && $0.frame.height < 100 })?.contentView {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
      }
    }
    if let path = ProcessInfo.processInfo.environment["TSUKIKO_HUD_SNAPSHOT"], let view = NSApp.keyWindow?.contentView {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
      }
    }
    hud.finishEditing(save: true)
    assert(makeHUD().currentPlacement.scale == 1.3)
    hud.resetPosition()
    assert(makeHUD().currentPlacement.scale == 1)
    hud.configure(labels: [:])
    hud.show() // A recording arriving during editing must stay visible after Save.
    hud.finishEditing(save: true)
    assert(hud.isVisible)
    hud.hide()
    hud.show()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    assert(hud.previewFrame.width == 372)
    assert(hud.isVisible, "A stale hide animation must not hide the next recording")
    var statusActive = false
    var changedMode = ""
    hud.onStatusChanged = { statusActive = $0 }
    hud.onModeChanged = { changedMode = $0 }
    let center = NSPoint(x: hud.previewFrame.midX, y: hud.previewFrame.midY)
    hud.setMode("timer")
    assert(hud.isVisible && hud.previewFrame.size == NSSize(width: 176, height: 44))
    assert(near(hud.previewFrame.midX, center.x) && near(hud.previewFrame.midY, center.y))
    hud.setMode("status")
    assert(!hud.isVisible && statusActive)
    hud.setMode("off")
    assert(!hud.isVisible && !statusActive)
    hud.setMode("panel")
    assert(hud.isVisible && !statusActive)
    if let path = ProcessInfo.processInfo.environment["TSUKIKO_HUD_EMPTY"],
       let view = NSApp.windows.first(where: { $0.isVisible && near($0.frame.width, 372) })?.contentView {
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
      }
    }
    hud.configure(labels: [:])
    let original = hud.currentPlacement
    hud.cycleMode(-1); assert(hud.currentMode == "off")
    hud.cycleMode(1); assert(hud.currentMode == "panel")
    hud.cycleMode(1); assert(hud.currentMode == "status" && statusActive)
    hud.cycleMode(1); assert(hud.currentMode == "timer")
    hud.setScale(1.6)
    assert(hud.editorFrame?.size == controls, "Scaling preview must never scale the controls")
    hud.finishEditing(save: false)
    assert(hud.currentMode == "panel" && changedMode == "panel" && hud.isVisible)
    assert(hud.currentPlacement.x == original.x && hud.currentPlacement.y == original.y && hud.currentPlacement.scale == original.scale)
    hud.transcribing(); hud.setMode("status")
    assert(!statusActive && !hud.isVisible)
    hud.configure(labels: [:])
    assert(statusActive, "Status mode previews its real menu bar icon")
    hud.hide() // Actual work finishes while editor preview stays open.
    hud.setMode("timer")
    assert(hud.isVisible)
    hud.finishEditing(save: true)
    assert(!hud.isVisible && !statusActive, "Closing editor must never resurrect finished work")
    hud.show(); assert(hud.isVisible)
    hud.hide()
    print("macOS HUD geometry: all checks passed")
  }
}
