import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import macos_window_utils

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    DictationBridge.applySavedTheme()
    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    // Без этой строки окно не показывается вовсе: MacosWindowUtilsConfig
    // из Dart ожидает, что окном управляет плагин.
    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: macOSWindowUtilsViewController.flutterViewController)
    FileDropView.install(on: macOSWindowUtilsViewController.flutterViewController)

    // Инспектор тоже говорит с прослойкой — например, чтобы убрать значок
    // из Dock. Своего движка у него нет общего с панелью, поэтому канал
    // вешаем и сюда.
    DictationBridge.shared.attach(
      messenger: macOSWindowUtilsViewController.flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    self.title = "tsukiko"

    // Окно можно закрыть и открыть заново из строки меню — значит его
    // нельзя освобождать при закрытии.
    self.isReleasedWhenClosed = false

    // Три панели (очередь · текст · настройки) в 800×600 не помещаются.
    self.minSize = NSSize(width: 900, height: 560)
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.center()

    // Переопределения жизненного цикла в наследнике FlutterAppDelegate
    // до нас не доходят, поэтому подписываемся на уведомление сами.
    // Раньше запуска приложения нельзя: значок в строке меню, созданный
    // до него, система не рисует.
    //
    // Уведомление могло уже пройти: awakeFromNib окна и запуск приложения
    // идут в порядке, который нам не принадлежит, а опоздавший наблюдатель
    // не срабатывает никогда. На практике уведомление стабильно проигрывает
    // гонку — наблюдатель регистрируется позже, чем оно уже прошло, — так
    // что весь запуск держится на резервном вызове следующим витком цикла
    // событий: он наступает после запуска в любом случае, а launchOnce
    // срабатывает только один раз, откуда бы его ни позвали.
    var ranOnce = false
    let launchOnce: () -> Void = { [weak self] in
      guard !ranOnce else { return }
      // Вторая копия уже уходит (AppDelegate.applicationWillFinishLaunching),
      // но её очередь событий успевает провернуться до конца. Ни перехват
      // клавиш ставить, ни движок панели поднимать ей нельзя: панель на
      // старте подметает «осиротевшие» whisper-server — и погасила бы
      // сервер живой первой копии.
      guard AppDelegate.running == nil else { return }
      ranOnce = true
      DictationBridge.shared.start()
      DictationBridge.retireStaleMainAppRegistration()

      // Автозапуск нужен ради диктовки, а не ради расшифровщика: при входе
      // в систему поднимаем только строку меню. Окно никуда не делось —
      // оно откроется по значку в Dock или из поповера.
      if AppDelegate.launchedAtLogin {
        self?.orderOut(nil)
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { _ in launchOnce() }
    DispatchQueue.main.async { launchOnce() }
  }
}

/// Приём файлов перетаскиванием. Тот же канал и те же вызовы, что у
/// FileDropTarget в Windows-раннере.
///
/// Раньше это делал desktop_drop, а он узнаёт, что тащат, только при
/// броске: «Отпустите, чтобы добавить в очередь» выходило и над JPEG.
/// Здесь тип проверяется при наведении, по расширениям, которые присылает
/// очередь: неподходящий файл получает курсор-запрет и честную подпись.
final class FileDropView: NSView {
  private let channel: FlutterMethodChannel
  private var extensions: Set<String> = []
  private var supported = false

  static func install(on controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "tsukiko/file_input", binaryMessenger: controller.engine.binaryMessenger)
    let view = FileDropView(channel: channel, frame: controller.view.bounds)
    view.autoresizingMask = [.width, .height]
    view.registerForDraggedTypes(
      [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    controller.view.addSubview(view)
    channel.setMethodCallHandler { [weak view] call, result in
      guard call.method == "setDropExtensions", let list = call.arguments as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      view?.extensions = Set(list.map { $0.lowercased() })
      result(nil)
    }
  }

  private init(channel: FlutterMethodChannel, frame: NSRect) {
    self.channel = channel
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func takes(_ ext: String) -> Bool {
    extensions.isEmpty || extensions.contains("." + ext.lowercased())
  }

  private func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
  }

  private func promises(_ pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
    pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
      as? [NSFilePromiseReceiver] ?? []
  }

  /// Папку берём целиком: очередь сама выберет из неё звук.
  private func accepts(_ pasteboard: NSPasteboard) -> Bool {
    let urls = fileURLs(pasteboard)
    if !urls.isEmpty {
      return urls.contains { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
          || takes(url.pathExtension)
      }
    }
    // Обещанные файлы (Почта, Фото, браузеры) ещё не лежат на диске — есть
    // только тип. Отказываем, лишь когда тип известен и точно не наш.
    return promises(pasteboard).contains { receiver in
      receiver.fileTypes.contains { id in
        guard let type = UTType(id) else { return true }
        if type.conforms(to: .audiovisualContent) { return true }
        if let ext = type.preferredFilenameExtension, takes(ext) { return true }
        return type == .data || type == .item || type == .content
      }
    }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    supported = accepts(sender.draggingPasteboard)
    channel.invokeMethod("fileDragEntered", arguments: supported)
    return supported ? .copy : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    supported ? .copy : []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    supported = false
    channel.invokeMethod("fileDragExited", arguments: nil)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { supported }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    supported = false
    channel.invokeMethod("fileDragExited", arguments: nil)
    let pasteboard = sender.draggingPasteboard
    let urls = fileURLs(pasteboard)
    if !urls.isEmpty {
      channel.invokeMethod("filesDropped", arguments: urls.map(\.path))
      return true
    }
    let receivers = promises(pasteboard)
    guard !receivers.isEmpty else { return false }
    // Своя папка на каждый бросок: одноимённые файлы не затрут друг друга.
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("Drops/\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let queue = OperationQueue()
    let lock = NSLock()
    var paths: [String] = []
    // Обработчик зовётся по разу на каждый обещанный файл, а не на receiver.
    var left = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
    for receiver in receivers {
      receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) {
        [channel] url, error in
        lock.lock()
        if error == nil { paths.append(url.path) }
        left -= 1
        let done = left == 0 ? paths : nil
        lock.unlock()
        if let done {
          DispatchQueue.main.async { channel.invokeMethod("filesDropped", arguments: done) }
        }
      }
    }
    return true
  }
}
