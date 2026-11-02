import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/dictation/dictation_cubit.dart';
import 'package:tsukiko/features/dictation/dictation_state.dart';
import 'package:tsukiko/features/dictation/panel_page.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

class _FakeNative {
  final calls = <String>[];
  static const _channel = MethodChannel('tsukiko/dictation');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'permissions':
              return true;
            case 'level':
              return 0.2;
            case 'showMenu':
              throw MissingPluginException();
            default:
              return null;
          }
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

class _FakeServer extends WhisperServer {
  String? text = 'сказанное вслух';
  var shutdowns = 0;

  @override
  bool get up => false;

  @override
  Future<void> ensureUp(RunOptions o) async {}

  @override
  Future<String?> transcribe(String wav, {String lang = 'auto'}) async => text;

  @override
  Future<void> shutdown() async => shutdowns++;

  @override
  void hold() {}

  @override
  void release() {}

  @override
  Future<int> footprintMb() async => 0;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  useTempSupportDir('tsukiko-panel-page-test');

  late _FakeNative native;
  late _FakeServer server;
  late DictationCubit cubit;

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    server = _FakeServer();
    NativeBridge.debugReset();
    cubit = DictationCubit(NativeBridge(), server: server);
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    Locale locale = const Locale('ru'),
  }) async {
    await tester.binding.setSurfaceSize(const Size(380, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      BlocProvider<DictationCubit>.value(
        value: cubit,
        child: MacosApp(
          locale: locale,
          theme: MacosThemeData.light(),
          darkTheme: MacosThemeData.dark(),
          themeMode: ThemeMode.system,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PanelBody(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'меню поповера содержит пункты открытия папок записей, моделей и журналов на русском языке',
    (tester) async {
      await pumpPanel(tester, locale: const Locale('ru'));

      final openRecordings = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Открыть папку записей',
      );
      final openModels = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Открыть папку моделей',
      );
      final openLogs = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Открыть папку журналов',
      );

      expect(openRecordings, findsOneWidget);
      expect(openModels, findsOneWidget);
      expect(openLogs, findsOneWidget);

      // Проверяем, что нажатия срабатывают без ошибок
      await tester.tap(openRecordings);
      await tester.pump();

      await tester.tap(openModels);
      await tester.pump();

      await tester.tap(openLogs);
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('значки папок стоят над открытием, настройками и выходом', (
    tester,
  ) async {
    await pumpPanel(tester);
    final quit = find.text('Завершить tsukiko');
    final open = find.text('Открыть tsukiko…');
    final settings = find.text('Настройки диктовки…');
    final folders = find.byWidgetPredicate(
      (w) => w is MacosTooltip && w.message == 'Открыть папку записей',
    );
    expect(quit, findsOneWidget);
    expect(open, findsOneWidget);
    expect(settings, findsOneWidget);
    expect(tester.getTopLeft(folders).dy, lessThan(tester.getTopLeft(open).dy));
    expect(
      tester.getTopLeft(open).dy,
      lessThan(tester.getTopLeft(settings).dy),
    );
    expect(
      tester.getTopLeft(settings).dy,
      lessThan(tester.getTopLeft(quit).dy),
    );
  });

  testWidgets(
    'меню поповера содержит пункты открытия папок на английском языке',
    (tester) async {
      await pumpPanel(tester, locale: const Locale('en'));

      final openRecordings = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Open Recordings Folder',
      );
      final openModels = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Open Models Folder',
      );
      final openLogs = find.byWidgetPredicate(
        (w) => w is MacosTooltip && w.message == 'Open Logs Folder',
      );

      expect(openRecordings, findsOneWidget);
      expect(openModels, findsOneWidget);
      expect(openLogs, findsOneWidget);

      await tester.tap(openRecordings);
      await tester.pump();

      await tester.tap(openModels);
      await tester.pump();

      await tester.tap(openLogs);
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('управление моделью использует общие кнопки приложения', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.text('Загрузить другую…'), findsOneWidget);
    expect(
      find.widgetWithText(PushButton, 'Загрузить другую…'),
      findsOneWidget,
    );

    await tester.tap(find.text('Загрузить другую…'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  /// В тестах родной стороны нет: первое нажатие на выбор модели уходит
  /// в MissingPluginException, и панель переключается на запасной список.
  Future<void> toFallbackPicker(WidgetTester tester) async {
    if (find.byType(MacosPopupButton<String>).evaluate().isNotEmpty) return;
    final picker = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ModelPicker',
    );
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }

  testWidgets('общий селектор модели открывает меню по клику', (tester) async {
    const models = [
      '/path/to/ggml-large-v3-turbo.bin',
      '/path/to/ggml-base.bin',
    ];
    cubit.overrideState(
      cubit.state.copyWith(models: models, chosenModel: models.first),
    );

    await pumpPanel(tester);

    await toFallbackPicker(tester);
    expect(find.byType(MacosPopupButton<String>), findsOneWidget);
    await tester.tap(find.byType(MacosPopupButton<String>));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'длинное меню моделей помещается в узкое окно и закрывается Escape',
    (tester) async {
      final models = List.generate(20, (i) => '/path/ggml-model-$i.bin');
      cubit.overrideState(
        cubit.state.copyWith(models: models, chosenModel: models.first),
      );
      await pumpPanel(tester);
      await toFallbackPicker(tester);
      await tester.binding.setSurfaceSize(const Size(320, 420));
      await tester.pumpAndSettle();
      final selector = find.byType(MacosPopupButton<String>);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      final menu = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MacosPopupMenu<String>',
      );
      expect(menu, findsOneWidget);
      expect(tester.getTopLeft(menu).dy, greaterThanOrEqualTo(0));
      expect(tester.getBottomRight(menu).dy, lessThanOrEqualTo(420));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

extension on DictationCubit {
  void overrideState(DictationState s) {
    emit(s);
  }
}
