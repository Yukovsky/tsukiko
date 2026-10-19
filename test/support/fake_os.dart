import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os.dart';

/// Подменить папки приложения временными на время теста.
///
/// Настройки, модели и pid-файл живут в настоящей папке пользователя,
/// и тесты писали прямо туда. Это плохо дважды: у человека затирались
/// его собственные настройки, а два тестовых файла, работая
/// одновременно, снимали и возвращали один и тот же файл, стирая снимки
/// друг друга, — отчего проверки падали через раз.
///
/// Пути после подмены берутся у самой `os`: `os.home`, `os.supportDir`,
/// `os.modelsDir`.
void useTempSupportDir([String prefix = 'tsukiko-test']) {
  late Directory root;
  late Os real;

  setUp(() {
    real = os;
    root = Directory.systemTemp.createTempSync(prefix);
    os = _TempOs(real, root.path);
    Directory(os.modelsDir).createSync(recursive: true);
  });

  tearDown(() {
    os = real;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });
}

/// Выполнить один интеграционный участок со своей меткой процессов.
///
/// В отличие от [useTempSupportDir], это не хук на каждый тест файла, а
/// узкая область внутри одного теста. Нужна настоящему серверу: соседний
/// тест, запущенный Flutter параллельно, не должен принять его за сироту
/// установленного приложения и погасить посреди проверки.
Future<T> withTempSupportDir<T>(
    String prefix, Future<T> Function() body) async {
  final real = os;
  final root = Directory.systemTemp.createTempSync(prefix);
  os = _TempOs(real, root.path);
  Directory(os.modelsDir).createSync(recursive: true);
  try {
    return await body();
  } finally {
    os = real;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Всё как в настоящей системе, но папки — во временной.
class _TempOs implements Os {
  _TempOs(this._real, this._root);
  final Os _real;
  final String _root;

  @override
  String get platformId => _real.platformId;

  @override
  String get home => _root;

  @override
  String get supportDir => join(_root, 'Support');

  @override
  String get modelsDir => join(supportDir, 'models');

  @override
  String get defaultLibraryPath => join(_root, 'Documents', appName);

  @override
  String get documentsDir => join(_root, 'Documents');

  @override
  List<String> get sharedModelDirs => [
        join(_root, '.cache/whisper'),
        join(_root, '.cache/nemo-speech'),
      ];

  @override
  String join(String a, [String? b, String? c]) => _real.join(a, b, c);

  @override
  String basename(String p) => _real.basename(p);

  @override
  String dirname(String p) => _real.dirname(p);

  @override
  String? findExecutable(String name) => _real.findExecutable(name);

  @override
  String processPath(String path) => _real.processPath(path);

  /// Тест бежит не из .app: своего движка у него нет, и работать он
  /// будет на системном — как и приложение, у которого своего не нашлось.
  @override
  String get engineDir => join(_root, 'Helpers');

  @override
  List<String> engineNames(String base) => _real.engineNames(base);

  /// Тестам видеокарту не ищем: проба — это настоящий запуск движка.
  @override
  Future<Map<String, String>?> engineEnvironment() async => null;

  @override
  void bindToApp(int pid) {}

  @override
  bool get hasWindowMaterial => _real.hasWindowMaterial;

  @override
  bool get hasSystemMenuBar => _real.hasSystemMenuBar;

  @override
  bool get needsAccessibilityPermission => _real.needsAccessibilityPermission;

  @override
  Future<void> openUrl(String url) => _real.openUrl(url);

  @override
  ({List<String> mods, List<String> keys}) get defaultHold => _real.defaultHold;

  @override
  ({List<String> mods, List<String> keys}) get defaultToggle =>
      _real.defaultToggle;

  @override
  String get fileManagerName => _real.fileManagerName;

  @override
  String get appIconAreaName => _real.appIconAreaName;

  @override
  String get settingsShortcut => _real.settingsShortcut;

  @override
  String modifierLabel(String mod) => _real.modifierLabel(mod);

  @override
  String shortcutLabel(List<String> mods, [List<String> keys = const []]) =>
      _real.shortcutLabel(mods, keys);

  @override
  String menuShortcut(List<String> mods, [String key = '']) =>
      _real.menuShortcut(mods, key);

  @override
  Future<String> toWav(String src, String dst) => _real.toWav(src, dst);

  @override
  bool isAlive(int pid) => _real.isAlive(pid);

  @override
  void signal(int pid, {bool force = false}) =>
      _real.signal(pid, force: force);

  @override
  Future<List<ProcListing>> listProcesses() => _real.listProcesses();

  @override
  Future<int> footprintMb(int pid) => _real.footprintMb(pid);

  @override
  Future<bool> reveal(String path) async => false;

  @override
  void onTerminate(void Function() onSignal) {}
}

/// Подмена папок на весь запуск файла: ставится из flutter_test_config.dart.
///
/// Тест, не вызвавший [useTempSupportDir], иначе писал бы журнал, настройки
/// и историю в настоящую папку пользователя. Каждый тестовый файл идёт в
/// своём изоляте, так что временная папка у каждого своя.
void installTempOsForFile() {
  final root = Directory.systemTemp.createTempSync('tsukiko-test-file');
  os = _TempOs(os, root.path);
  Directory(os.modelsDir).createSync(recursive: true);
}
