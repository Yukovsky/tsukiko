import Cocoa
import FlutterMacOS

/// Поповер у строки меню: выезжает под значком, прячется при потере
/// фокуса. Внутри — второй движок Flutter, тот же, на котором работает
/// диктовка, поэтому панель показывает её состояние без всяких мостов
/// между изолятами.

// ── панель у строки меню ────────────────────────────────────────────────────

private final class TrayPanel: NSPanel {
  // Безрамочное окно по умолчанию не становится ключевым, и в нём
  // не работали бы ни щелчки, ни ввод.
  override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
  private var statusItem: NSStatusItem?
  private var panel: TrayPanel?
  private var controller: FlutterViewController?
  private var onShown: (() -> Void)?

  /// Панель уехала. Пока её нет на экране, считать уровень сигнала
  /// и спрашивать память сервера не для кого.
  private var onHidden: (() -> Void)?

  private var localClickMonitor: Any?
  private var outsideClickMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var spaceObserver: NSObjectProtocol?

  // Ширина поповера постоянна, высота — нет: её сообщает Flutter, померив
  // содержимое. Здесь только первое значение, до первого замера.
  private var size = NSSize(width: 320, height: 430)

  /// Высота содержимого из Flutter. Окно растёт вниз от значка: верхний
  /// край привязан к строке меню, и уезжать ему некуда.
  func setHeight(_ height: CGFloat) {
    guard let panel else { return }
    // Выше экрана окно не имеет смысла: не влезшее прокручивается внутри.
    let limit = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
    let wanted = max(120, min(height, limit - 24))
    guard abs(wanted - size.height) > 0.5 else { return }
    size.height = wanted

    guard panel.isVisible else { return }
    let frame = panel.frame
    let grown = NSRect(
      x: frame.minX, y: frame.maxY - wanted, width: size.width, height: wanted)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.setFrame(grown, display: true)
      return
    }
    // Предупреждение появилось или ушло — высота меняется движением,
    // а не подменой кадра.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.22
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
      panel.animator().setFrame(grown, display: true)
    }
  }

  /// Тот же канал жизненного цикла, что у окна настроек: движок здесь
  /// тоже свой, и после потери фокуса кадры для него не возобновляются.
  private var lifecycle: FlutterBasicMessageChannel?

  private func setLifecycle(_ state: String) {
    lifecycle?.sendMessage("AppLifecycleState.\(state)")
  }

  func build(
    engine: FlutterEngine, onShown: @escaping () -> Void,
    onHidden: @escaping () -> Void
  ) {
    self.onShown = onShown
    self.onHidden = onHidden
    lifecycle = FlutterBasicMessageChannel(
      name: "flutter/lifecycle",
      binaryMessenger: engine.binaryMessenger,
      codec: FlutterStringCodec.sharedInstance())

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Свой силуэт вместо системного символа. Картинка шаблонная: чёрный
    // и альфа, всё остальное система рисует сама — под светлую и тёмную
    // строку меню и под выделение.
    if let icon = NSImage(named: "MenuBarIcon") {
      icon.isTemplate = true
      icon.accessibilityDescription = "tsukiko"
      item.button?.image = icon
    } else {
      // Без картинки и без заголовка кнопка нулевой ширины, и значка
      // в строке меню просто не видно.
      item.button?.title = "тс"
    }
    item.button?.target = self
    item.button?.action = #selector(clicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item

    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

    let panel = TrayPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
    ]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovable = false
    panel.delegate = self
    panel.animationBehavior = .utilityWindow

    // Настоящий материал системы под содержимым: панель должна выглядеть
    // как поповер, а не как окно с закрашенным фоном. Материал тот же,
    // что у панели записи: две плавающие поверхности одного приложения,
    // и стекло у них обязано быть одним и тем же.
    let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true
    effect.autoresizingMask = [.width, .height]

    controller.view.frame = effect.bounds
    controller.view.autoresizingMask = [.width, .height]
    controller.backgroundColor = .clear
    effect.addSubview(controller.view)

    panel.contentView = effect
    self.panel = panel
    self.controller = controller
  }

  func setRecordingIndicator(_ active: Bool) {
    guard let button = statusItem?.button else { return }
    if active, let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Идёт запись") {
      let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.systemRed.setFill()
        rect.fill(using: .sourceAtop)
        return true
      }
      image.isTemplate = false
      button.image = image
      button.toolTip = "tsukiko — идёт запись"
    } else {
      let image = NSImage(named: "MenuBarIcon")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "tsukiko"
    }
    button.setAccessibilityLabel(active ? "tsukiko — идёт запись" : "tsukiko")
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    let rightClick = NSApp.currentEvent?.type == .rightMouseUp
    if rightClick {
      showMenu()
    } else if panel?.isVisible == true {
      hide()
    } else {
      show()
    }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "Открыть tsukiko", action: #selector(openMain), keyEquivalent: ""))
    menu.items.last?.target = self
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "Завершить tsukiko", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  @objc private func openMain() {
    hide()
    DictationBridge.showMainWindow()
  }

  func show() {
    guard let panel, let button = statusItem?.button,
      let buttonWindow = button.window
    else { return }

    let anchor = buttonWindow.convertToScreen(button.frame)
    let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
    var x = anchor.midX - size.width / 2
    if let visible = screen?.visibleFrame {
      x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
    }
    let y = anchor.minY - size.height - 6

    // Появление: панель выезжает из-под иконки на несколько точек и
    // проявляется — то же движение, что у системных поповеров.
    // Пока панель ни разу не показывали, слой Flutter не имеет поверхности
    // для рисования. Задаём размер до появления, иначе первый показ пустой.
    panel.setFrame(NSRect(x: x, y: y + 8, width: size.width, height: size.height), display: false)
    if let content = panel.contentView, let view = controller?.view {
      view.frame = content.bounds
      content.layoutSubtreeIfNeeded()
    }
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    installDismissMonitors()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      panel.animator().setFrame(
        NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
    setLifecycle("resumed")
    onShown?()
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    removeDismissMonitors()
    // Говорим сразу, а не в конце анимации: за эти 120 мс считать уже
    // нечего, а лишний кадр уровня стоит целого замера.
    onHidden?()
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.12
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        panel.orderOut(nil)
      })
  }

  private func installDismissMonitors() {
    removeDismissMonitors()
    guard let panel else { return }
    let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
      guard let self, let panel, panel.isVisible else { return event }
      if event.window !== panel, !self.mouseIsInside(panel) {
        if self.isClickOnStatusItem() {
          return event
        }
        self.hide()
      }
      return event
    }

    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self, weak panel] event in
      guard let self, let panel, panel.isVisible else { return }
      if event.windowNumber != panel.windowNumber, !self.mouseIsInside(panel) {
        if self.isClickOnStatusItem() {
          return
        }
        self.hide()
      }
    }

    // Если поповер открыли поверх другого окна (в том числе в полноэкранном
    // режиме), повторная активация этого приложения не должна закрывать панель.
    // Закрываем только при переключении на третье приложение или смене пространства.
    let hostApp = NSWorkspace.shared.frontmostApplication
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier,
        app.processIdentifier != hostApp?.processIdentifier
      else { return }
      self.hide()
    }

    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.hide()
    }
  }

  private func removeDismissMonitors() {
    if let monitor = localClickMonitor {
      NSEvent.removeMonitor(monitor)
      localClickMonitor = nil
    }
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
    if let observer = activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      activationObserver = nil
    }
    if let observer = spaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      spaceObserver = nil
    }
  }

  private func mouseIsInside(_ panel: NSPanel) -> Bool {
    panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
  }

  private func isClickOnStatusItem() -> Bool {
    guard let button = statusItem?.button, let window = button.window else { return false }
    return window.frame.contains(NSEvent.mouseLocation)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // Панель — nonactivating: приложение от неё «активным» не становится,
    // и Flutter считает вид невидимым, останавливая кадры. Внешне это
    // выглядит как замерший интерфейс: состояние меняется, а не рисуется.
    setLifecycle("resumed")
  }

  func windowDidResignKey(_ notification: Notification) {
    // Не гасим панель по resignKey: в полноэкранном режиме и при открытии
    // меню системный фокус прыгает между вспомогательными окнами, из-за чего
    // панель моментально схлопывалась. Закрытием управляют click-мониторы.
  }
}
