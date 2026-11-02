import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';
// ignore: implementation_imports
import 'package:macos_ui/src/layout/wallpaper_tinting_settings/global_wallpaper_tinting_settings.dart';
import 'core/app_locale.dart';
import 'core/app_theme.dart';
import 'core/cat_look.dart';
import 'design/theme_fade.dart';
import 'core/logger.dart';
import 'core/settings.dart';
import 'l10n/gen/app_localizations.dart';
import 'legacy_migration.dart';
import 'features/dictation/hud_page.dart' show runHud;
import 'features/dictation/panel_page.dart' show runPanel;
import 'features/settings/settings_page.dart' show runSettings;
import 'features/queue/home_page.dart';
import 'platform/bridge.dart';
import 'platform/os.dart';

void _applyLoggingSetting() {
  if (Settings.load()['loggingEnabled'] == false) {
    Log.enabled = false;
  }
}

/// Точка входа второго движка Flutter — того, что рисует панель у строки
/// меню и ведёт диктовку. Она обязана лежать именно здесь: FlutterEngine
/// на macOS ищет точку входа только в корневой библиотеке приложения.
@pragma('vm:entry-point')
void panelMain() {
  _applyLoggingSetting();
  Log.info('App', 'Starting entrypoint: panelMain');
  runPanel();
}

/// Точка входа третьего движка — окна настроек. Оно открывается по ⌘,
/// и из поповера, а в режиме без значка в Dock только из поповера:
/// строки меню там нет вовсе.
@pragma('vm:entry-point')
void settingsMain() {
  _applyLoggingSetting();
  Log.info('App', 'Starting entrypoint: settingsMain');
  runSettings();
}

/// Точка входа движка плавающей панели записи. Только Windows: на macOS
/// эта панель написана на SwiftUI и остаётся там — почему, разобрано
/// в `docs/задача-панель-записи.md`.
@pragma('vm:entry-point')
void hudMain() {
  _applyLoggingSetting();
  Log.info('App', 'Starting entrypoint: hudMain');
  runHud();
}

@pragma('vm:entry-point')
void hudEditorMain() {
  runHud(editor: true);
}

/// Второй копии здесь не бывает: её ловит и завершает сторона macOS ещё
/// до запуска движка (AppDelegate.applicationWillFinishLaunching), подняв
/// окно уже работающей. Проверять это в Dart больше нечем и незачем.
Future<void> main(List<String> args) async {
  _applyLoggingSetting();
  Log.info(
    'App',
    'Starting Tsukiko $appVersion (${os.platformId}, ${Platform.operatingSystemVersion}), '
        'entrypoint: main, args: $args',
  );
  refreshLocale();
  refreshTheme();
  refreshCatLook();
  WidgetsFlutterBinding.ensureInitialized();
  // Заголовок окна рисует система — ей тоже надо сказать, какая тема
  // выбрана. Главный изолят узнаёт о смене из «reload», как и все.
  void syncTitleBar() =>
      unawaited(NativeBridge.setWindowTheme(themeModeId(appThemeMode.value)));
  appThemeMode.addListener(syncTitleBar);
  syncTitleBar();
  // Настоящий материал окна: содержимое во всю высоту, титульная полоса
  // прозрачная. Спрашиваем не «мы на macOS?», а «даёт ли система материал
  // окна»: настраивать здесь нечего ровно там, где материала нет, — а
  // плагин, который это делает, на такой системе и не поднимется.
  if (os.hasWindowMaterial) {
    await const MacosWindowUtilsConfig(
      toolbarStyle: NSWindowToolbarStyle.unified,
    ).apply();
  } else {
    GlobalWallpaperTintingSettings.disableWallpaperTinting();
  }
  // До первого findModels(): список моделей должен собираться уже
  // из своей папки. Когда переезжать нечего, это одна проверка папки.
  await migrateLegacyModels();
  runApp(
    TsukikoApp(
      initialFiles: args.where(
        (a) => FileSystemEntity.typeSync(a) != FileSystemEntityType.notFound,
      ),
    ),
  );
}

class TsukikoApp extends StatelessWidget {
  const TsukikoApp({super.key, this.initialFiles = const []});
  final Iterable<String> initialFiles;

  @override
  Widget build(BuildContext context) => ThemedApp(
    builder: (context) => MacosApp(
      locale: appLocale.value,
      title: appName,
      // Светлую и тёмную тему строит сам MacosApp — не передаём своих.
      // Готовый MacosThemeData.light() приходил без isMainWindow, и
      // macos_ui в светлой теме закрашивал включённую галку белым:
      // от неё оставалась пустая синяя рамка, «включено» не отличалось
      // от «выключено». Своя тема MacosApp берёт isMainWindow и цвет
      // акцента у системы (на Windows окно всегда «главное»).
      themeMode: appThemeMode.value,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: HomePage(initialFiles: initialFiles),
    ),
  );
}
