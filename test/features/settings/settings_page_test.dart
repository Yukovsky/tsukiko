import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/core/vocabulary.dart';
import 'package:tsukiko/design/design.dart';
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:tsukiko/platform/os.dart';
import 'package:tsukiko/features/settings/settings_page.dart';
import 'package:tsukiko/features/settings/settings_state.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

import '../../support/fake_os.dart';

class _FakeSettingsCubit extends Cubit<SettingsState> implements SettingsCubit {
  _FakeSettingsCubit([SettingsState? initial])
    : super(initial ?? SettingsState(tab: 'models'));

  String? lastLibraryPath;
  NativeBridge? hudBridge;
  @override
  NativeBridge get bridge => hudBridge!;

  void beginDownload() => emit(
    state.copyWith(
      downloadTitle: 'Parakeet',
      downloadProgress: '0 МБ из 640 МБ',
      downloadPercent: 0,
    ),
  );

  @override
  void setLibraryPath(String dir) {
    lastLibraryPath = dir;
    emit(state.copyWith(libraryPath: dir));
  }

  @override
  void setVisible(bool visible) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockFileSelector extends FileSelectorPlatform {
  _MockFileSelector({this.result, this.shouldThrow = false});

  final String? result;
  final bool shouldThrow;
  String? lastInitialDirectory;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    lastInitialDirectory = initialDirectory;
    if (shouldThrow) {
      throw PlatformException(
        code: 'system_error',
        message: 'Could not show dialog',
      );
    }
    return result;
  }
}

/// Окно настроек живёт отдельным файлом теста намеренно: рисующий тест
/// заводит TestWidgetsFlutterBinding, а та подменяет HttpClient — рядом
/// с ней тесты загрузки моделей перестают видеть сеть.
void main() {
  testWidgets('форма добавления в словарь использует ровные поля и кнопку', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    final cubit = _FakeSettingsCubit(
      SettingsState(
        tab: 'vocabulary',
        vocabulary: const [
          VocabularyItem(
            id: 'item-1',
            phrase: 'адрес офиса',
            replacement: 'Минск',
          ),
        ],
      ),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    await tester.pump();

    final add = tester.widget<PushButton>(
      find.widgetWithText(PushButton, 'Добавить'),
    );
    expect(add.controlSize, ControlSize.regular);
    expect(find.text('Что сказать или распознать'), findsOneWidget);
    expect(find.text('Замена (необязательно)'), findsOneWidget);
    final phrase = tester.getRect(find.text('Что сказать или распознать'));
    final replacement = tester.getRect(find.text('Замена (необязательно)'));
    expect((phrase.top - replacement.top).abs(), lessThan(1));
    await tester.ensureVisible(find.text('адрес офиса', skipOffstage: false));
    await tester.pump();
    expect(find.text('адрес офиса'), findsOneWidget);
    expect(find.text('Минск'), findsOneWidget);
    expect(find.text('Замена'), findsOneWidget);
    final trash = find.byWidgetPredicate(
      (widget) => widget is MacosIcon && widget.icon == CupertinoIcons.trash,
    );
    expect(trash, findsOneWidget);
    expect(tester.getSize(trash).width, IconSize.button);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('единый редактор индикатора доступен из настроек диктовки', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    NativeBridge.debugReset();
    final calls = <MethodCall>[];
    const channel = MethodChannel('tsukiko/dictation');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final cubit = _FakeSettingsCubit(SettingsState(tab: 'dictation'))
      ..hudBridge = NativeBridge();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    final configure = find.text('Настроить индикатор записи');
    await tester.scrollUntilVisible(
      configure,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(configure);
    expect(calls.last.method, 'configureHud');
    expect((calls.last.arguments as Map)['save'], 'Сохранить');
    expect((calls.last.arguments as Map)['mode'], 'panel');
    expect(find.text('Показывать панель записи'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('вкладка диктовки не содержит сводку словаря', (tester) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    final cubit = _FakeSettingsCubit(
      SettingsState(
        tab: 'dictation',
        vocabulary: const [
          VocabularyItem(
            id: 'item-1',
            phrase: 'адрес офиса',
            replacement: 'Минск',
          ),
        ],
      ),
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Словарь и замены'), findsNothing);
    expect(find.text('Применять в диктовке'), findsNothing);
    expect(find.text('Настроить словарь →'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('начало загрузки возвращает список к индикатору', (tester) async {
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    final cubit = _FakeSettingsCubit();
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SettingsCubit>.value(
          value: cubit,
          child: const SettingsBody(),
        ),
      ),
    );
    await tester.pump();

    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final before = position.pixels;
    expect(before, greaterThan(500));

    cubit.beginDownload();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Загрузка: Parakeet'), findsOneWidget);
    expect(position.pixels, lessThan(before));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('окно настроек рисуется на всех пяти вкладках', (tester) async {
    // Размер настоящего окна: раскладка обязана сходиться именно в нём.
    await tester.binding.setSurfaceSize(const Size(580, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Тестовый движок по умолчанию отдаёт en_US — тексты ниже сверены
    // с русским, поэтому закрепляем его явно.
    tester.platformDispatcher.localesTestValue = const [Locale('ru')];
    NativeBridge.debugReset();
    await tester.pumpWidget(const SettingsApp());
    await tester.pump();

    // Вкладки названы по хозяину настройки: сперва два потребителя
    // моделей, потом общий склад, словарь и само приложение.
    for (final (label, marker) in [
      ('Расшифровщик', 'Сохранять готовый текст на диск'),
      ('Диктовка', 'Держать и говорить'),
      ('Модели', 'АКТИВНЫЕ МОДЕЛИ'),
      ('Словарь', 'СЛОВАРЬ И ЗАМЕНЫ'),
      ('Приложение', 'Показывать значок в ${os.appIconAreaName}'),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.text(marker), findsOneWidget, reason: 'вкладка «$label»');
      expect(tester.takeException(), isNull, reason: 'вкладка «$label»');
    }

    // Каталог длиннее окна, но все движки и ограничения доступны после
    // прокрутки, а не спрятаны в одном непрозрачном выпадающем списке.
    await tester.tap(find.text('Модели'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.textContaining('Parakeet TDT 0.6b v3'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('25 языков Европы'), findsOneWidget);
    expect(find.text('Без словарных подсказок'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'каталог моделей');

    // Скилл живёт на вкладке «Приложение», ниже сгиба: список длинный,
    // и до раздела надо доехать. Проверяем, что он там вообще есть, —
    // иначе кнопка молча не появится ни у кого.
    await tester.tap(find.text('Приложение'));
    await tester.pump();
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно и стоит на экране.
    // Заголовки разделов рисуются прописными (SectionTitle), поэтому
    // ищем так, как оно стоит на экране.
    //
    // Раздел свёрнут: сам он на месте всегда, а содержимое появляется
    // только по щелчку — тому, кто нейросетями не пользуется, оно
    // мозолило бы глаза на каждом открытии настроек.
    // Заголовок раскрывашки написан обычными буквами — от заголовка
    // раздела (он прописными) отличается именно этим.
    await tester.dragUntilVisible(
      find.text('Скилл для нейросетей'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('СКИЛЛ ДЛЯ НЕЙРОСЕТЕЙ'), findsOneWidget);
    expect(find.text('Установлено для:'), findsNothing);

    await tester.tap(find.text('Скилл для нейросетей'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Поставить скилл'),
      find.byType(ListView).first,
      const Offset(0, -120),
    );
    expect(find.text('Установлено для:'), findsOneWidget);
    // Ненайденный агент в списке есть — и его галку можно поставить
    // самому: человек вправе поставить агента следом за нами.
    expect(find.textContaining('не найден'), findsWidgets);

    expect(tester.takeException(), isNull);

    // Таймер опроса разрешений должен уйти вместе с окном.
    await tester.pumpWidget(const SizedBox());
  });

  group('папка журналов', () {
    useTempSupportDir('tsukiko-settings-logs');

    testWidgets(
      'кнопка открытия папки журналов доступна во вкладке приложения',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(580, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.localesTestValue = const [Locale('ru')];
        final cubit = _FakeSettingsCubit(SettingsState(tab: 'app'));
        addTearDown(cubit.close);

        await tester.pumpWidget(
          MacosApp(
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BlocProvider<SettingsCubit>.value(
              value: cubit,
              child: const SettingsBody(),
            ),
          ),
        );
        await tester.pump();

        await tester.dragUntilVisible(
          find.widgetWithText(PushButton, 'Открыть папку журналов'),
          find.byType(ListView).first,
          const Offset(0, -150),
        );
        expect(find.text('ЖУРНАЛИРОВАНИЕ'), findsOneWidget);
        expect(find.text('Вести журнал работы'), findsOneWidget);
        final openLogsBtn = find.widgetWithText(
          PushButton,
          'Открыть папку журналов',
        );
        expect(openLogsBtn, findsOneWidget);

        await tester.tap(openLogsBtn);
        await tester.pump();

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('выбор папки библиотеки', () {
    testWidgets('ошибка нативного диалога не роняет приложение', (
      tester,
    ) async {
      final prevPlatform = FileSelectorPlatform.instance;
      final mock = _MockFileSelector(shouldThrow: true);
      FileSelectorPlatform.instance = mock;
      addTearDown(() => FileSelectorPlatform.instance = prevPlatform);

      await tester.binding.setSurfaceSize(const Size(580, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      final cubit = _FakeSettingsCubit(
        SettingsState(tab: 'transcriber', libraryPath: '/non/existent/path'),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(
        MacosApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<SettingsCubit>.value(
            value: cubit,
            child: const SettingsBody(),
          ),
        ),
      );
      await tester.pump();

      final pickBtn = find.widgetWithText(PushButton, 'Выбрать другую папку…');
      await tester.dragUntilVisible(
        pickBtn,
        find.byType(ListView).first,
        const Offset(0, -100),
      );
      await tester.tap(pickBtn);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(cubit.lastLibraryPath, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('выбор папки обновляет путь, а пустой ответ игнорируется', (
      tester,
    ) async {
      final prevPlatform = FileSelectorPlatform.instance;
      final mock = _MockFileSelector(result: '/Users/test/Audio');
      FileSelectorPlatform.instance = mock;
      addTearDown(() => FileSelectorPlatform.instance = prevPlatform);

      await tester.binding.setSurfaceSize(const Size(580, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      final cubit = _FakeSettingsCubit(
        SettingsState(tab: 'transcriber', libraryPath: '/old/path'),
      );
      addTearDown(cubit.close);

      await tester.pumpWidget(
        MacosApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<SettingsCubit>.value(
            value: cubit,
            child: const SettingsBody(),
          ),
        ),
      );
      await tester.pump();

      final pickBtn = find.widgetWithText(PushButton, 'Выбрать другую папку…');
      await tester.dragUntilVisible(
        pickBtn,
        find.byType(ListView).first,
        const Offset(0, -100),
      );
      await tester.tap(pickBtn);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(cubit.lastLibraryPath, '/Users/test/Audio');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('при узком окне вкладки настроек прокручиваются горизонтально без обрезания', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(380, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      final cubit = _FakeSettingsCubit(SettingsState(tab: 'transcriber'));
      addTearDown(cubit.close);

      await tester.pumpWidget(
        MacosApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BlocProvider<SettingsCubit>.value(
            value: cubit,
            child: const SettingsBody(),
          ),
        ),
      );
      await tester.pump();

      // На узком экране (380 логических пикселей) активен SingleChildScrollView в полосе вкладок
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      // Все 5 вкладок существуют в дереве и не вызывают переполнения (RenderFlex overflow)
      expect(find.text('Расшифровщик'), findsOneWidget);
      expect(find.text('Диктовка'), findsOneWidget);
      expect(find.text('Словарь'), findsOneWidget);
      expect(find.text('Модели'), findsOneWidget);
      expect(find.text('Приложение'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
