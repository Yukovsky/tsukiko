import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:tsukiko/core/indicator_mode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/features/dictation/hud_page.dart';
import 'package:tsukiko/platform/bridge.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:tsukiko/l10n/gen/app_localizations.dart';

/// Плавающая панель записи. Проверяется то, ради чего она есть: что она
/// говорит человеку в каждом состоянии и что нажатие кнопки доходит
/// до диктовки.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Finder icon(IconData value) => find.byWidgetPredicate(
    (widget) => widget is MacosIcon && widget.icon == value,
  );

  late List<MethodCall> calls;

  /// Отдаёт ли микрофон звук. Пока нет — панель говорит «включаю».
  var micLive = true;

  setUp(() {
    micLive = true;
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    NativeBridge.debugReset();
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        calls.add(call);
        // Уровень сигнала панель спрашивает сама, тридцать раз в секунду.
        if (call.method == 'level') return 0.5;
        if (call.method == 'micLive') return micLive;
        return null;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      null,
    );
  });

  /// Прислать панели состояние так же, как это делает родная сторона.
  Future<void> send(WidgetTester tester, HudState state) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tsukiko/dictation',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('hudState', state.name),
      ),
      (_) {},
    );
    await tester.pump();
    // Запись показывается, когда микрофон ожил, — это первый же опрос.
    if (state == HudState.recording) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
    }
  }

  Future<void> show(WidgetTester tester, {bool editor = false}) async {
    // Шире настоящих 372: в тестах Flutter рисует своим шрифтом, где
    // каждый знак — квадрат в кегль. «Остановить» выходит 120 точек
    // вместо примерно семидесяти, и панель переполняется от одного этого.
    // Проверяем поведение, а не раскладку.
    await tester.binding.setSurfaceSize(
      editor ? const Size(480, 228) : const Size(600, 52),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: editor
            ? HudEditorView(bridge: NativeBridge())
            : HudView(bridge: NativeBridge()),
      ),
    );
    await tester.pump();
  }

  Future<void> queue(
    WidgetTester tester, {
    required int pending,
    required bool processing,
  }) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tsukiko/dictation',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('hudQueue', {'pending': pending, 'processing': processing}),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets(
    'единственная расшифровка не показывает очередь и не меняет отступы',
    (tester) async {
      await show(tester);
      await send(tester, HudState.transcribing);
      final label = tester.getRect(find.text('Распознаю…'));
      final abort = tester.getRect(icon(CupertinoIcons.xmark));
      await queue(tester, pending: 0, processing: true);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      expect(tester.getRect(find.text('Распознаю…')), label);
      expect(tester.getRect(icon(CupertinoIcons.xmark)), abort);

      await queue(tester, pending: 1, processing: true);
      expect(find.text('1'), findsOneWidget);
      await queue(tester, pending: 0, processing: true);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      expect(tester.getRect(find.text('Распознаю…')), label);
      expect(tester.getRect(icon(CupertinoIcons.xmark)), abort);

      // Первая диктовка уже отправлена, но рабочий ещё не забрал её.
      await queue(tester, pending: 1, processing: false);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'вторая запись имеет очередь 1, третья — 2, текущая расшифровка исключена',
    (tester) async {
      await show(tester);
      await send(tester, HudState.recording);
      await queue(tester, pending: 0, processing: false);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);

      await queue(tester, pending: 0, processing: true);
      expect(find.text('1'), findsOneWidget);
      await queue(tester, pending: 1, processing: true);
      expect(find.text('2'), findsOneWidget);

      await send(tester, HudState.transcribing);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      await queue(tester, pending: 0, processing: true);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('подпись меню очереди совпадает с числом на индикаторе', (
    tester,
  ) async {
    await show(tester);
    final bridge = tester.widget<HudView>(find.byType(HudView)).bridge!;
    final l10n = AppLocalizations.of(tester.element(find.byType(HudView)));
    for (final example in [
      (HudState.transcribing, 0, 0),
      (HudState.recording, 0, 1),
      (HudState.recording, 1, 2),
      (HudState.transcribing, 1, 1),
    ]) {
      await bridge.hud(example.$1, pending: example.$2, processing: true);
      final payload = calls.last.arguments as Map;
      expect(
        (payload['labels'] as Map)['queueTitle'],
        l10n.hudQueueCount(example.$3),
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('очередь показывает число и независимые действия', (
    tester,
  ) async {
    await show(tester);
    await send(tester, HudState.transcribing);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tsukiko/dictation',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('hudQueue', {'pending': 9, 'processing': true}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.text('9'), findsOneWidget);
    expect(find.text('10'), findsNothing);
    await tester.tap(find.text('9'));
    await tester.pump();
    final menu = calls.where((c) => c.method == 'hudQueueMenu').last;
    expect((menu.arguments as Map)['record'], 'Записать следующую');
    expect((menu.arguments as Map)['abort'], 'Отменить текущую расшифровку');
    expect(
      (menu.arguments as Map)['clearQueue'],
      'Убрать ожидающие · сохранить записи',
    );
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> layout(WidgetTester tester, Map<String, dynamic> data) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'tsukiko/dictation',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('hudLayout', data),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('настройка положения сохраняется, отменяется и сбрасывается', (
    tester,
  ) async {
    await show(tester, editor: true);
    await tester.binding.setSurfaceSize(const Size(480, 228));
    await layout(tester, {'editing': true, 'scaleValue': 1.6});
    expect(find.text('Индикатор записи'), findsOneWidget);
    expect(find.text('160%'), findsOneWidget);
    expect(find.text('Остановить'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Сбросить'));
    expect(calls.last.method, 'resetHud');
    await tester.tap(find.text('Сохранить'));
    expect(calls.last.method, 'hudLayout');
    expect(calls.last.arguments, {'save': true});
    await tester.tap(find.text('Отменить'));
    expect(calls.last.arguments, {'save': false});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('положение настраивается с клавиатуры', (tester) async {
    await show(tester);
    await tester.binding.setSurfaceSize(const Size(960, 250));
    await layout(tester, {'editing': true, 'scaleValue': 1.0});
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(calls.last.arguments, {'nudgeX': 1.0, 'nudgeY': 0.0});
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(calls.last.arguments, {'save': false});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls.last.arguments, {'save': true});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('перетаскивание отправляет завершённый жест для сохранения', (
    tester,
  ) async {
    await show(tester);
    await send(tester, HudState.recording);
    final meter = find
        .byWidgetPredicate(
          (widget) =>
              widget is MouseRegion && widget.cursor == SystemMouseCursors.move,
        )
        .first;
    await tester.drag(meter, const Offset(40, -20));
    await tester.pump();
    final moves = calls.where((call) => call.method == 'hudLayout').toList();
    expect(moves, isNotEmpty);
    expect((moves.last.arguments as Map)['end'], isTrue);
    final count = calls.where((call) => call.method == 'hudLayout').length;
    await tester.tap(meter);
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'hudLayout').length,
      count,
      reason: 'a tap after dragging must not initiate native movement',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('в каждом состоянии панель говорит своё', (tester) async {
    await show(tester);

    await send(tester, HudState.recording);
    expect(find.text('Отменить'), findsOneWidget);
    expect(find.text('Остановить'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget, reason: 'время идёт с нуля');

    await send(tester, HudState.transcribing);
    expect(find.text('Распознаю…'), findsOneWidget);
    // Прервать долгий счёт можно только отсюда.
    expect(find.text('Отменить'), findsNothing);

    // Молча исчезнуть после неудачи — значит соврать, что всё в порядке.
    await send(tester, HudState.failed);
    expect(find.text('Не распознано · запись сохранена'), findsOneWidget);

    await send(tester, HudState.copied);
    expect(find.text('Не вставилось · текст в буфере, Ctrl+V'), findsOneWidget);

    await send(tester, HudState.cancelled);
    expect(find.text('Отменено · запись сохранена'), findsOneWidget);

    await send(tester, HudState.done);
    expect(find.text('Готово'), findsOneWidget);

    await send(tester, HudState.hidden);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('пока микрофон не ожил, панель не делает вид, что пишет', (
    tester,
  ) async {
    micLive = false;
    await show(tester);
    await send(tester, HudState.recording);
    expect(find.text('Включаю микрофон…'), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
    // Передумать можно и до того, как микрофон заработал.
    expect(find.text('Остановить'), findsOneWidget);
    expect(find.text('Отменить'), findsOneWidget);

    micLive = true;
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();
    expect(find.text('Включаю микрофон…'), findsNothing);
    expect(find.text('0:00'), findsOneWidget);

    await send(tester, HudState.hidden);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('нажатие доходит до диктовки, а уровень спрашивается сам', (
    tester,
  ) async {
    await show(tester);
    await send(tester, HudState.recording);

    // Полоски уровня должны шевелиться: молчащая панель неотличима
    // от сломанного микрофона.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();
    expect(calls.any((c) => c.method == 'level'), isTrue);

    await tester.tap(find.text('Остановить'));
    await tester.pump();
    expect(
      calls.where((c) => c.method == 'hudAction').map((c) => c.arguments),
      contains('stop'),
    );

    await tester.tap(find.text('Отменить'));
    await tester.pump();
    expect(
      calls.where((c) => c.method == 'hudAction').map((c) => c.arguments),
      contains('cancel'),
    );

    await send(tester, HudState.hidden);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'бейдж очереди стоит между таймером и кнопками и исчезает без очереди',
    (tester) async {
      await show(tester);
      await send(tester, HudState.recording);
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'tsukiko/dictation',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('hudQueue', {'pending': 0, 'processing': true}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(icon(CupertinoIcons.list_bullet), findsOneWidget);
      expect(
        tester.getRect(find.text('0:00')).right,
        lessThan(tester.getRect(find.text('1')).left),
      );
      expect(
        tester.getRect(find.text('1')).right,
        lessThan(tester.getRect(find.text('Отменить')).left),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'tsukiko/dictation',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('hudQueue', {'pending': 0, 'processing': false}),
        ),
        (_) {},
      );
      await tester.pump();
      expect(icon(CupertinoIcons.list_bullet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('можно перетащить за остановку и таймер без остановки записи', (
    tester,
  ) async {
    await show(tester);
    await send(tester, HudState.recording);
    for (final target in [find.text('Остановить'), find.text('0:00')]) {
      calls.clear();
      await tester.drag(target, const Offset(45, 0));
      await tester.pump();
      expect(calls.where((c) => c.method == 'hudAction'), isEmpty);
      expect(
        calls.where((c) => c.method == 'hudLayout').last.arguments,
        containsPair('end', true),
      );
    }
    await tester.tap(find.text('Остановить'));
    expect(calls.where((c) => c.method == 'hudAction').last.arguments, 'stop');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('четыре стиля листаются по кругу в обе стороны', (tester) async {
    await show(tester, editor: true);
    for (final mode in IndicatorMode.values) {
      await layout(tester, {
        'editing': true,
        'mode': mode.name,
        'scaleValue': 1.0,
      });
      expect(find.text('${mode.index + 1} / 4'), findsOneWidget);
      await tester.tap(icon(CupertinoIcons.chevron_right));
      expect(calls.last.arguments, {'mode': mode.cycle(1).name});
      await tester.tap(icon(CupertinoIcons.chevron_left));
      expect(calls.last.arguments, {'mode': mode.cycle(-1).name});
      expect(
        find.byType(CupertinoSlider),
        mode == IndicatorMode.panel || mode == IndicatorMode.timer
            ? findsOneWidget
            : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'таймер меняет действие после записи и не отменяет завершённую работу',
    (tester) async {
      await show(tester);
      await layout(tester, {'mode': 'timer', 'scaleValue': 1.0});
      await send(tester, HudState.recording);
      expect(icon(CupertinoIcons.mic_fill), findsOneWidget);
      await tester.tap(icon(CupertinoIcons.stop_fill));
      expect(calls.last.arguments, 'stop');
      await send(tester, HudState.transcribing);
      expect(icon(CupertinoIcons.mic_fill), findsNothing);
      await tester.tap(icon(CupertinoIcons.xmark));
      expect(calls.last.arguments, 'abort');
      await send(tester, HudState.done);
      expect(find.text('Готово'), findsOneWidget);
      expect(icon(CupertinoIcons.xmark), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'предпросмотр настоящего размера не запускает действий диктовки',
    (tester) async {
      await show(tester);
      await layout(tester, {
        'editing': true,
        'mode': 'panel',
        'scaleValue': 1.0,
      });
      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Индикатор записи'), findsNothing);
      await tester.tap(find.text('Остановить'));
      await tester.tap(find.text('Отменить'));
      expect(calls.where((c) => c.method == 'hudAction'), isEmpty);
      expect(tester.getSize(find.byType(HudView)).height, 52);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('подхватывает начальное состояние при открытии', (tester) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        calls.add(call);
        if (call.method == 'getHudState') return 'recording';
        if (call.method == 'level') return 0.5;
        return null;
      },
    );
    await show(tester);
    expect(find.text('Отменить'), findsOneWidget);
    expect(find.text('Остановить'), findsOneWidget);
  });
}
