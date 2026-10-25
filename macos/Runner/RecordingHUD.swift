import Cocoa
import SwiftUI

enum HUDState: String { case hidden, recording, transcribing, done, failed, copied, cancelled, silent }
enum IndicatorStyle: String, CaseIterable {
  case panel, status, timer, off
  var floating: Bool { self == .panel || self == .timer }
}

final class HUDModel: ObservableObject {
  @Published var state: HUDState = .hidden
  @Published var pending = 0
  @Published var processing = false
  @Published var editing = false
  @Published var scale: Double = 1
  @Published var mode: IndicatorStyle = .panel
  var queueCount: Int {
    let outstanding = max(0, pending) + (processing ? 1 : 0)
    if editing { return max(2, outstanding) }
    return max(0, outstanding - (state == .recording ? 0 : 1))
  }
  var size: NSSize { mode == .timer ? NSSize(width: 176, height: 44) : NSSize(width: queueCount > 0 ? 420 : 372, height: 52) }
  @Published var elapsed: TimeInterval = 0
  /// Микрофон уже отдаёт звук. Пока нет, панель говорит «включаю», а не «записываю».
  @Published var live = true
  @Published var levels: [Double] = Array(repeating: 0, count: 22)
  var labels: [String: String] = [:]
  var onMove: (CGSize, Bool) -> Void = { _, _ in }
  var onScale: (Double) -> Void = { _ in }
  var onMode: (Int) -> Void = { _ in }
  var onFinish: (Bool) -> Void = { _ in }
  var onReset: () -> Void = {}
  var onCancel: () -> Void = {}
  var onStop: () -> Void = {}
  var onAbort: () -> Void = {}
  var onClearQueue: () -> Void = {}
  var onRecord: () -> Void = {}
  func label(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }
  /// Говорит ли человек: уровень уже отсчитан от фона комнаты, ноль — тишина
  /// или дыхание. Хвост 0,4 с не даёт микрофону мигать между словами.
  var warming: Bool { !editing && state == .recording && !live }
  var voiceUntil = Date.distantPast
  var voice: Bool { Date() < voiceUntil }
  func push(level: Double) {
    levels.removeFirst(); levels.append(level)
    if level > 0.15 { voiceUntil = Date().addingTimeInterval(0.4) }
  }
}

struct HUDView: View {
  @ObservedObject var model: HUDModel
  private var preview: Bool { model.editing && model.state != .recording }
  private var displayState: HUDState { model.editing ? .recording : model.state }
  private var count: Int { model.queueCount }
  private var time: String {
    let seconds = preview ? 3 : Int(model.elapsed)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
  private var levels: [Double] {
    preview ? (0..<22).map { Double(($0 * 7) % 13 + 2) / 16 } : model.levels
  }
  private func action(_ callback: () -> Void) { if !model.editing { callback() } }
  private var queue: some View {
    Menu {
      Text(model.label("queueTitle", "В очереди: \(model.pending)"))
      if model.state != .recording { Button(model.label("record", "Записать следующую"), action: model.onRecord) }
      if model.processing { Button(model.label("abort", "Отменить текущую расшифровку"), action: model.onAbort) }
      if model.pending > 0 { Button(model.label("clearQueue", "Убрать ожидающие · сохранить записи"), action: model.onClearQueue) }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "list.bullet").font(.system(size: 11, weight: .medium))
        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
      }
    }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 7).padding(.vertical, 5)
      .background(Capsule().fill(Color.accentColor.opacity(0.14))).disabled(model.editing)
      .help(model.label("queueTitle", "Очередь диктовок"))
      .accessibilityLabel(model.label("queueTitle", "Очередь диктовок"))
  }
  var body: some View {
    Group {
      if model.mode == .timer {
        HStack(spacing: 9) {
          if displayState == .recording || displayState == .transcribing {
            let recording = displayState == .recording
            // Слева и справа по одной ширине, чтобы время встало по центру.
            ZStack(alignment: .leading) {
              if recording {
                Image(systemName: model.warming ? "mic" : "mic.fill")
                  .foregroundColor(model.warming ? .secondary : model.voice || model.editing ? .red : .primary)
              } else { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14) }
            }.frame(width: recording && !model.warming ? 53 : 22, alignment: .leading)
            Text(model.warming ? "Включаю…" : recording ? time : "Распознаю…")
              .font(.system(size: 13, weight: .medium).monospacedDigit()).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: recording && !model.warming ? .center : .leading)
            if recording {
              Button { action(model.onCancel) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                  .frame(width: 22, height: 24).contentShape(Rectangle())
              }.buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Отменить запись").help("Отменить запись")
            }
            Button { action(recording ? model.onStop : model.onAbort) } label: {
              Image(systemName: recording ? "stop.fill" : "xmark").font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 24).contentShape(Rectangle())
            }.buttonStyle(PlainButtonStyle())
              .accessibilityLabel(recording ? "Остановить запись" : "Отменить расшифровку")
              .help(recording ? "Остановить запись" : "Отменить расшифровку")
          } else {
            Image(systemName: resultIcon).foregroundColor(displayState == .done ? .green : .secondary)
            Text(resultText).font(.system(size: 12)).lineLimit(1).help(resultText)
            Spacer(minLength: 0)
          }
        }.padding(.horizontal, 13)
      } else {
        HStack(spacing: 9) {
          if model.warming {
            Image(systemName: "mic").foregroundColor(.secondary)
            Text("Включаю микрофон…").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            HUDButton(title: "Отменить", filled: false) { action(model.onCancel) }
            HUDButton(title: "Остановить", filled: true) { action(model.onStop) }
          } else if displayState == .recording {
            Meter(levels: levels, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            Text(time).font(.system(size: 13, weight: .medium).monospacedDigit()).fixedSize()
            if count > 0 { queue }
            Spacer(minLength: 0)
            HUDButton(title: "Отменить", filled: false) { action(model.onCancel) }
            HUDButton(title: "Остановить", filled: true) { action(model.onStop) }
          } else if displayState == .transcribing {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 20)
            Text("Распознаю…").font(.system(size: 13, weight: .medium))
            if count > 0 { queue }
            Spacer(minLength: 0)
            Button { action(model.onAbort) } label: {
              Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 32)
            }.buttonStyle(PlainButtonStyle()).help("Отменить распознавание")
          } else {
            Image(systemName: resultIcon).foregroundColor(displayState == .done ? .green : .secondary)
            Text(resultText).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
          }
        }.padding(.horizontal, 16)
      }
    }
    .frame(width: model.size.width, height: model.size.height)
    .contentShape(Rectangle())
    .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
      .onChanged { model.onMove($0.translation, false) }
      .onEnded { model.onMove($0.translation, true) })
    .scaleEffect(model.scale)
    .frame(width: model.size.width * model.scale, height: model.size.height * model.scale)
  }
  private var resultIcon: String {
    switch displayState {
    case .done: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .copied: return "doc.on.clipboard"
    case .silent: return "mic.slash"
    default: return "xmark.circle.fill"
    }
  }
  private var resultText: String {
    switch displayState {
    case .done: return "Готово"
    case .failed: return "Не распознано · запись сохранена"
    case .copied: return "Не вставилось · текст в буфере, ⌘V"
    case .silent: return "Ничего не записалось"
    case .cancelled: return "Отменено · запись сохранена"
    default: return ""
    }
  }
}

private struct HUDButton: View {
  let title: String
  let filled: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) { Text(title).font(.system(size: 12)).fixedSize().padding(.horizontal, 10).padding(.vertical, 6) }
      .buttonStyle(HUDButtonStyle(filled: filled))
  }
}
private struct HUDButtonStyle: ButtonStyle {
  let filled: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundColor(filled ? .white : .primary)
      .background(RoundedRectangle(cornerRadius: 6).fill(filled ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.06)))
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}
private struct Meter: View {
  let levels: [Double]
  let reduceMotion: Bool
  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule().fill(Color.primary.opacity(0.55)).frame(width: 2.5, height: max(2.5, level * 24))
      }
    }.frame(width: 100, height: 26)
      .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 1), value: levels)
  }
}

private struct HUDEditorView: View {
  @ObservedObject var model: HUDModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(model.label("title", "Индикатор записи")).font(.system(size: 14, weight: .semibold))
        Spacer()
        Text("\((IndicatorStyle.allCases.firstIndex(of: model.mode) ?? 0) + 1) / 4").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
      }
      HStack {
        Button { model.onMode(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 26) }.help(model.label("previous", "Предыдущий стиль")).accessibilityLabel(model.label("previous", "Предыдущий стиль"))
        Spacer()
        Text(model.label(model.mode.rawValue, ["panel": "Плашка записи", "status": "Строка меню / трей", "timer": "Плавающий таймер", "off": "Выключено"][model.mode.rawValue]!)).font(.system(size: 12, weight: .medium))
        Spacer()
        Button { model.onMode(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 26) }.help(model.label("next", "Следующий стиль")).accessibilityLabel(model.label("next", "Следующий стиль"))
      }.buttonStyle(PlainButtonStyle())
      if model.mode.floating {
        HStack {
          Text(model.label("scale", "Масштаб"))
          Slider(value: Binding(get: { model.scale }, set: model.onScale), in: 0.8...1.6, step: 0.1)
            .accessibilityLabel(model.label("scale", "Масштаб"))
          Text("\(Int((model.scale * 100).rounded()))%").monospacedDigit().frame(width: 38)
        }.font(.system(size: 11)).frame(height: 26)
      } else {
        Text(model.label(model.mode == .status ? "statusHint" : "offHint", "Положение значка задаёт система"))
          .font(.system(size: 11)).foregroundColor(.secondary).frame(height: 26)
      }
      Text(model.mode.floating ? model.label("preview", "Предпросмотр") + " · " + model.label("hint", "Переместите индикатор · центр экрана притягивает") : "")
        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
      HStack {
        Button(model.label("reset", "Сбросить"), action: model.onReset)
        Spacer()
        Button(model.label("cancel", "Отменить")) { model.onFinish(false) }
        Button(model.label("save", "Сохранить")) { model.onFinish(true) }
      }.font(.system(size: 11))
    }.padding(16).frame(width: 360, height: 228)
  }
}

private final class HUDPanel: NSPanel {
  var editingEnabled = false
  override var canBecomeKey: Bool { editingEnabled }
  override var canBecomeMain: Bool { false }
}

final class RecordingHUD {
  private var panel: HUDPanel?
  private var editor: HUDPanel?
  private var guides: NSPanel?
  private let model = HUDModel()
  private let defaults: UserDefaults
  private let placementKey = "dictationHUDPlacement"
  private var placement = HUDPlacement()
  private var savedPlacement = HUDPlacement()
  private var savedMode: IndicatorStyle = .panel
  private var ticker: Timer?
  private var startedAt: Date?
  private var hideAfterDone: Timer?
  private var showNumber = 0
  private var dragOrigin: NSPoint?
  private var dragPointer: NSPoint?
  private var layoutScreen: NSScreen?
  private var keyMonitor: Any?
  private weak var previousKeyWindow: NSWindow?
  private var editorCorner = 0
  var levelSource: () -> Double = { 0 }
  var liveSource: () -> Bool = { true }
  var onModeChanged: (String) -> Void = { _ in }
  var onStatusChanged: (Bool) -> Void = { _ in }
  var currentPlacement: HUDPlacement { placement }
  var currentMode: String { model.mode.rawValue }
  var isEditing: Bool { model.editing }
  var isVisible: Bool { panel?.isVisible == true }
  var previewFrame: NSRect { NSRect(origin: restingOrigin, size: size) }
  var editorFrame: NSRect? { editor?.frame }
  private var size: NSSize { NSSize(width: model.size.width * model.scale, height: model.size.height * model.scale) }
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  init(onCancel: @escaping () -> Void, onStop: @escaping () -> Void,
       onAbort: @escaping () -> Void, onClearQueue: @escaping () -> Void,
       onRecord: @escaping () -> Void, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    model.onCancel = onCancel; model.onStop = onStop; model.onAbort = onAbort
    model.onClearQueue = onClearQueue; model.onRecord = onRecord
    if let saved = defaults.dictionary(forKey: placementKey) {
      placement = HUDPlacement(x: saved["x"] as? Double, y: saved["y"] as? Double, scale: saved["scale"] as? Double ?? 1)
    }
    model.scale = placement.scale
    model.onMove = { [weak self] offset, ended in self?.move(offset, ended: ended) }
    model.onScale = { [weak self] value in self?.setScale(value) }
    model.onMode = { [weak self] delta in self?.cycleMode(delta) }
    model.onReset = { [weak self] in self?.resetPosition() }
    model.onFinish = { [weak self] save in self?.finishEditing(save: save) }
  }
  deinit {
    ticker?.invalidate(); hideAfterDone?.invalidate()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    panel?.orderOut(nil); editor?.orderOut(nil); guides?.orderOut(nil)
  }
  private func materialPanel<V: View>(size: NSSize, view: V) -> HUDPanel {
    let window = HUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    window.isFloatingPanel = true; window.level = .statusBar
    window.hidesOnDeactivate = false; window.isOpaque = false; window.backgroundColor = .clear
    window.hasShadow = true; window.becomesKeyOnlyIfNeeded = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
    effect.wantsLayer = true; effect.layer?.cornerRadius = 14; effect.layer?.masksToBounds = true
    effect.autoresizingMask = [.width, .height]
    let host = NSHostingView(rootView: view); host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
    effect.addSubview(host); window.contentView = effect
    return window
  }
  private func build() -> HUDPanel {
    if let panel { return panel }
    let window = materialPanel(size: size, view: HUDView(model: model))
    window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel = window; return window
  }
  private var currentScreen: NSScreen? {
    if let layoutScreen, NSScreen.screens.contains(layoutScreen) { return layoutScreen }
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
  }
  private var workArea: NSRect { currentScreen?.visibleFrame ?? .zero }
  private var restingOrigin: NSPoint { placement.origin(in: workArea, size: size) }
  private func persist() {
    var saved: [String: Double] = ["scale": placement.scale]
    if let x = placement.x, let y = placement.y { saved["x"] = x; saved["y"] = y }
    defaults.set(saved, forKey: placementKey)
  }
  private func resize() {
    build().setFrame(NSRect(origin: restingOrigin, size: size), display: true)
    positionEditor(animated: true)
  }
  private func captureCenter() {
    placement.capture(origin: restingOrigin, in: workArea, size: size)
  }
  private func move(_ offset: CGSize, ended: Bool) {
    guard model.mode.floating else { return }
    let window = build(), pointer = NSEvent.mouseLocation
    if dragOrigin == nil {
      dragOrigin = window.frame.origin
      dragPointer = NSPoint(x: pointer.x - offset.width * model.scale, y: pointer.y + offset.height * model.scale)
    }
    let origin = placement.snap(NSPoint(x: dragOrigin!.x + pointer.x - dragPointer!.x,
                                        y: dragOrigin!.y + pointer.y - dragPointer!.y), in: workArea, size: size)
    window.setFrameOrigin(origin); placement.capture(origin: origin, in: workArea, size: size)
    positionEditor(animated: true)
    if ended { dragOrigin = nil; dragPointer = nil; if !model.editing { persist() } }
  }
  func setScale(_ scale: Double) {
    captureCenter(); placement.scale = HUDPlacement.validScale(scale); model.scale = placement.scale
    resize(); if !model.editing { persist() }
  }
  func setMode(_ value: String, notify: Bool = false) {
    let next = IndicatorStyle(rawValue: value) ?? .panel
    if model.mode != next {
      if model.mode.floating { captureCenter() }
      dragOrigin = nil; dragPointer = nil
      model.mode = next
      refreshVisibility()
    }
    if notify { onModeChanged(next.rawValue) }
  }
  func cycleMode(_ delta: Int) {
    let modes = IndicatorStyle.allCases, index = modes.firstIndex(of: model.mode) ?? 0
    setMode(modes[(index + delta % modes.count + modes.count) % modes.count].rawValue, notify: true)
  }
  func resetPosition() { placement = HUDPlacement(); model.scale = placement.scale; resize(); if !model.editing { persist() } }
  func configure(labels: [String: String]) {
    guard !model.editing else { return }
    if let mode = labels["mode"] { setMode(mode) }
    model.labels.merge(labels) { _, new in new }
    savedPlacement = placement; savedMode = model.mode; layoutScreen = currentScreen
    captureCenter(); model.editing = true
    let overlay = NSPanel(contentRect: workArea, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    overlay.level = .floating; overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.ignoresMouseEvents = true
    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    overlay.contentView = NSHostingView(rootView: HUDGuides()); overlay.orderFrontRegardless(); guides = overlay
    let controls = materialPanel(size: NSSize(width: 360, height: 228), view: HUDEditorView(model: model))
    controls.editingEnabled = true; editor = controls; editorCorner = 0
    positionEditor(animated: false)
    previousKeyWindow = NSApp.keyWindow
    controls.makeKeyAndOrderFront(nil)
    refreshVisibility()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.model.editing else { return event }
      if event.keyCode == 53 { self.finishEditing(save: false); return nil }
      if event.keyCode == 36 { self.finishEditing(save: true); return nil }
      let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
      let delta: NSPoint
      switch event.keyCode {
      case 123: delta = NSPoint(x: -step, y: 0)
      case 124: delta = NSPoint(x: step, y: 0)
      case 125: delta = NSPoint(x: 0, y: -step)
      case 126: delta = NSPoint(x: 0, y: step)
      default: return event
      }
      if self.model.mode.floating {
        let origin = self.restingOrigin
        let moved = self.placement.clamp(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y), in: self.workArea, size: self.size)
        self.placement.capture(origin: moved, in: self.workArea, size: self.size); self.resize()
      }
      return nil
    }
  }
  func finishEditing(save: Bool) {
    guard model.editing else { return }
    if save { captureCenter() }
    model.editing = false
    if !save {
      placement = savedPlacement; model.scale = placement.scale; model.mode = savedMode
      onModeChanged(savedMode.rawValue)
    } else { persist() }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
    editor?.orderOut(nil); editor = nil; guides?.orderOut(nil); guides = nil
    previousKeyWindow?.makeKeyAndOrderFront(nil)
    refreshVisibility(); layoutScreen = nil
  }
  private func positionEditor(animated: Bool) {
    guard let editor, model.editing else { return }
    let selected = HUDLayoutControls.corner(in: workArea, size: editor.frame.size,
      avoiding: model.mode.floating ? previewFrame : .zero, current: editorCorner)
    let target = HUDLayoutControls.frame(in: workArea, size: editor.frame.size, corner: selected)
    let changed = selected != editorCorner || !animated
    editorCorner = selected
    guard changed else { return }
    if animated && !reduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.36; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        editor.animator().setFrameOrigin(target.origin)
      }
    } else { editor.setFrameOrigin(target.origin) }
  }
  func updateQueue(pending: Int, processing: Bool, labels: [String: String] = [:]) {
    let before = size, origin = restingOrigin
    model.labels.merge(labels) { _, new in new }; model.pending = max(0, pending); model.processing = processing
    preserveCenter(from: before, origin: origin)
    if size != before && panel != nil { resize() }
  }
  private func preserveCenter(from before: NSSize, origin: NSPoint) {
    if size != before {
      placement.capture(origin: origin, in: workArea, size: before)
      if let start = dragOrigin {
        dragOrigin = NSPoint(x: start.x + restingOrigin.x - origin.x, y: start.y + restingOrigin.y - origin.y)
      }
    }
  }
  func show() { setState(.recording) }
  func transcribing() { setState(.transcribing) }
  func finish() { linger(.done, seconds: 0.7) }
  func failed() { linger(.failed, seconds: 2.6) }
  func copied() { linger(.copied, seconds: 2.6) }
  func cancelled() { linger(.cancelled, seconds: 2.2) }
  func silent() { linger(.silent, seconds: 1.8) }
  func hide() { setState(.hidden) }
  private func setState(_ next: HUDState) {
    let before = size, origin = restingOrigin
    hideAfterDone?.invalidate(); hideAfterDone = nil
    if next != model.state {
      if next == .recording {
        startedAt = nil; model.live = false; model.elapsed = 0; model.levels = Array(repeating: 0, count: 22)
      } else { ticker?.invalidate(); ticker = nil }
      model.state = next
    }
    preserveCenter(from: before, origin: origin)
    if next == .recording && ticker == nil {
      let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
        guard let self else { return }
        if !self.model.live && self.liveSource() { self.model.live = true; self.startedAt = Date() }
        if self.model.live { self.model.push(level: self.levelSource()) }
        if let start = self.startedAt { self.model.elapsed = Date().timeIntervalSince(start) }
      }
      RunLoop.main.add(timer, forMode: .common); ticker = timer
    }
    refreshVisibility()
  }
  private func linger(_ state: HUDState, seconds: TimeInterval) {
    setState(state)
    hideAfterDone = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
  }
  private func refreshVisibility() {
    showNumber += 1
    onStatusChanged(model.mode == .status && (model.state == .recording || model.editing))
    guard model.mode.floating && (model.editing || model.state != .hidden) else {
      panel?.orderOut(nil); return
    }
    let window = build(), appearing = !window.isVisible
    resize(); window.orderFrontRegardless()
    if appearing {
      window.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = reduceMotion ? 0.12 : 0.22
        window.animator().alphaValue = 1
      }
    } else { window.alphaValue = 1 }
  }
}

/// Keep the current corner until the preview approaches; avoid oscillation.
struct HUDLayoutControls {
  static func frame(in work: NSRect, size: NSSize, corner: Int) -> NSRect {
    let left = work.minX + 24, right = max(left, work.maxX - size.width - 24)
    let bottom = work.minY + 24, top = max(bottom, work.maxY - size.height - 24)
    return NSRect(x: corner % 2 == 0 ? left : right, y: corner < 2 ? top : bottom, width: size.width, height: size.height)
  }
  static func corner(in work: NSRect, size: NSSize, avoiding preview: NSRect, current: Int) -> Int {
    let obstacle = preview.insetBy(dx: -32, dy: -32)
    if preview.isEmpty || !frame(in: work, size: size, corner: current).intersects(obstacle) { return current }
    let choices = (0..<4).filter { !frame(in: work, size: size, corner: $0).intersects(obstacle) }
    return (choices.isEmpty ? Array(0..<4) : choices).max { a, b in
      let pa = frame(in: work, size: size, corner: a), pb = frame(in: work, size: size, corner: b)
      return hypot(pa.midX - preview.midX, pa.midY - preview.midY) < hypot(pb.midX - preview.midX, pb.midY - preview.midY)
    } ?? current
  }
}

/// Coordinates are fractions of the work area, measured from its top left.
struct HUDPlacement {
  var x: Double?
  var y: Double?
  var scale: Double
  init(x: Double? = nil, y: Double? = nil, scale: Double = 1) {
    self.x = x.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.y = y.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    self.scale = Self.validScale(scale)
  }
  static func validScale(_ scale: Double) -> Double {
    scale.isFinite ? min(1.6, max(0.8, scale)) : 1
  }
  func clamp(_ origin: NSPoint, in work: NSRect, size: NSSize) -> NSPoint {
    NSPoint(x: min(max(work.minX, work.maxX - size.width), max(work.minX, origin.x)),
            y: min(max(work.minY, work.maxY - size.height), max(work.minY, origin.y)))
  }
  func origin(in work: NSRect, size: NSSize) -> NSPoint {
    clamp(NSPoint(x: work.minX + (x ?? 0.5) * work.width - size.width / 2,
                  y: y.map { work.maxY - $0 * work.height - size.height / 2 }
                    ?? work.minY + 92), in: work, size: size)
  }
  func snap(_ origin: NSPoint, in work: NSRect, size: NSSize) -> NSPoint {
    var p = origin
    if abs(p.x + size.width / 2 - work.midX) <= 12 { p.x = work.midX - size.width / 2 }
    if abs(p.y + size.height / 2 - work.midY) <= 12 { p.y = work.midY - size.height / 2 }
    return clamp(p, in: work, size: size)
  }
  mutating func capture(origin: NSPoint, in work: NSRect, size: NSSize) {
    guard work.width > 0, work.height > 0 else { return }
    x = min(1, max(0, (origin.x + size.width / 2 - work.minX) / work.width))
    y = min(1, max(0, (work.maxY - origin.y - size.height / 2) / work.height))
  }
}

private struct HUDGuides: View {
  var body: some View {
    GeometryReader { area in
      ZStack {
        Color.blue.opacity(0.10)
        Rectangle().fill(Color.blue.opacity(0.65)).frame(width: 1)
        Rectangle().fill(Color.blue.opacity(0.65)).frame(height: 1)
      }.frame(width: area.size.width, height: area.size.height)
    }.accessibilityHidden(true)
  }
}
