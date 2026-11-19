import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/logger.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/whisper_server.dart';
import 'package:tsukiko/features/api/api_server.dart' show apiKeySetting;
import 'package:tsukiko/features/settings/settings_cubit.dart';
import 'package:tsukiko/features/settings/settings_state.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

/// Окно настроек. До выноса из виджета проверять было нечем: каждая галка
/// сидела в `setState` и не отделялась от раскладки.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNative native;
  late SettingsCubit cubit;

  // Настройки живут в папке приложения, и без подмены тест правил бы
  // настоящие настройки пользователя.
  useTempSupportDir('tsukiko-settings-app');

  setUp(() {
    // Строки из кубита идут через currentL10n(), который читает системный
    // локаль. Тестовый движок сбрасывает её перед каждым тестом на en_US —
    // здесь же тексты сверены с русским, поэтому закрепляем его явно.
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    native = _FakeNative()..install();
    NativeBridge.debugReset();
    cubit = SettingsCubit(NativeBridge());
  });

  tearDown(() async {
    await cubit.close();
    native.remove();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('в списке потоков всегда есть нынешнее значение', () {
    // Иначе выпадающий список macos_ui падает с «нет пункта с таким
    // значением», и окно настроек не открывается вовсе. Значение
    // выпадает из ряда запросто: настройки переехали с машины, где ядер
    // было больше, или их правили руками в файле.
    for (final current in [1, 2, 3, 4, 999]) {
      expect(
        threadChoices(current),
        contains(current),
        reason: 'потоков $current',
      );
    }
    // Ряд остаётся возрастающим и без повторов — это всё-таки список
    // на выбор, а не свалка.
    final list = threadChoices(6);
    expect(list, orderedEquals(list.toSet().toList()..sort()));
  });

  group('настройки диктовки', () {
    test(
      'постоянная отправка сохраняется и переживает перечитывание',
      () async {
        expect(DictationSettings.load().sendAfterInsert, isFalse);
        cubit.setSendAfterInsert(true);
        await settle();
        expect(cubit.state.sendAfterInsert, isTrue);
        expect(DictationSettings.load().sendAfterInsert, isTrue);
        expect(native.calls, contains('settingsChanged'));
        cubit.setSendAfterInsert(false);
        await settle();
        expect(cubit.state.sendAfterInsert, isFalse);
        expect(DictationSettings.load().sendAfterInsert, isFalse);
      },
    );

    test('правка уходит на диск и соседям — перечитать', () async {
      cubit.setThreads(8);
      await settle();

      expect(cubit.state.threads, 8);
      expect(DictationSettings.load().threads, 8, reason: 'на диске тоже');
      // Те же настройки читают панель и главное окно: без «reload»
      // половина правок доходила бы только до следующего запуска.
      expect(native.calls, contains('settingsChanged'));
    });

    test('подсказка и пунктуация ходят порознь', () async {
      cubit.setPrompt('Минина, Сытый двор');
      cubit.setPunctuate(false);
      await settle();

      expect(cubit.state.prompt, 'Минина, Сытый двор');
      expect(cubit.state.punctuate, isFalse);
      expect(DictationSettings.load().prompt, 'Минина, Сытый двор');
    });

    test('«та же, что у расшифровщика» — это пустая своя модель', () async {
      cubit.setDictationModel('/своя.bin');
      await settle();
      expect(cubit.state.dictationModel, '/своя.bin');

      cubit.setDictationModel('');
      await settle();
      expect(cubit.state.dictationModel, isEmpty);
    });

    test('выбор модели в панели диктовки обновляет окно настроек', () async {
      final changedElsewhere = DictationSettings.load()
        ..model = '/модели/large-v3-turbo.bin';
      changedElsewhere.save();

      await native.sendReload();
      await settle();

      expect(cubit.state.dictationModel, changedElsewhere.model);
      expect(cubit.state.dictationModelInUse, changedElsewhere.model);
    });

    test('одна клавиша сохраняется только после явного согласия', () async {
      final before = cubit.state.hold;
      var asked = '';
      final declined = cubit.reassign(
        'hold',
        confirmExclusive: (hotkey) async {
          asked = hotkey.label;
          return false;
        },
      );
      await settle();
      await native.sendCaptured(const Hotkey([], keys: ['y']));
      await declined;

      expect(asked, 'Y');
      expect(cubit.state.hold.sameAs(before), isTrue);

      final accepted = cubit.reassign(
        'hold',
        confirmExclusive: (_) async => true,
      );
      await settle();
      await native.sendCaptured(const Hotkey(['leftctrl']));
      await accepted;

      expect(cubit.state.hold.mods, ['leftctrl']);
    });

    test(
      'без универсального доступа назначение сразу объясняет причину',
      () async {
        if (!Platform.isMacOS) return;
        native.permitted = false;
        await cubit.reassign('hold');

        expect(native.calls, isNot(contains('capture')));
        expect(native.calls, contains('requestPermission'));
        expect(cubit.state.allowed, isFalse);
        expect(cubit.state.problem, contains('Универсальный доступ'));
      },
    );
  });

  group('модели', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tsukiko-set'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('модель расшифровщика выбирается из общего окна моделей', () async {
      final path = '${tmp.path}/ggml-small.bin';

      cubit.setQueueModel(path);
      await settle();

      expect(cubit.state.queueModel, path);
      expect(Settings.load()['model'], path);
      expect(native.calls, contains('settingsChanged'));
    });

    test('направление связи моделей меняется без цикла', () async {
      const path = '/модели/общая.bin';
      await cubit.setQueueModel(path);

      // Обе стороны сначала смотрят на расшифровщик. Переключение
      // материализует тот же путь у диктовки и разворачивает связь.
      await cubit.setQueueModel('');
      expect(cubit.state.transcriberUsesDictationModel, isTrue);
      expect(cubit.state.dictationModel, path);
      expect(cubit.state.queueModel, path);
      expect(Settings.load()[transcriberUsesDictationModelSetting], isTrue);

      // Теперь разворачиваем связь обратно. Конкретный путь остаётся
      // у расшифровщика, а пустая модель диктовки означает ссылку на него.
      await cubit.setDictationModel('');
      expect(cubit.state.transcriberUsesDictationModel, isFalse);
      expect(cubit.state.dictationModel, isEmpty);
      expect(cubit.state.queueModel, path);
      expect(Settings.load()[transcriberUsesDictationModelSetting], isFalse);
    });

    test('связанная модель расшифровщика следует за диктовкой', () async {
      await cubit.setQueueModel('/модели/первая.bin');
      await cubit.setQueueModel('');
      await cubit.setDictationModel('/модели/вторая.bin');

      expect(cubit.state.queueModel, '/модели/вторая.bin');
      expect(Settings.load()['model'], '/модели/вторая.bin');
      expect(Settings.load()[transcriberUsesDictationModelSetting], isTrue);
    });

    test('чужой .bin не становится моделью, а объясняет почему', () async {
      final fake = File('${tmp.path}/ggml-обманка.bin')
        ..writeAsBytesSync(List<int>.filled(64, 7));

      cubit.pickModel(fake.path);
      await settle();

      // whisper-cli на таком файле падает с руганью про тензоры —
      // человеку из неё не понять, что он выбрал не то.
      expect(cubit.state.problem, isNotNull);
      expect(cubit.state.models, isNot(contains(fake.path)));
      expect(cubit.state.dictationModel, isNot(fake.path));
    });

    test('исчезнувший файл тоже не молчит', () async {
      cubit.pickModel('${tmp.path}/такого-нет.bin');
      await settle();
      expect(cubit.state.problem, contains('больше нет на диске'));
    });

    test('удаление снимает выбор, если убрали выбранную', () async {
      final path = '${tmp.path}/ggml-условная.bin';
      File(path).writeAsBytesSync(List.filled(16, 1));
      cubit.setDictationModel(path);
      await settle();
      expect(cubit.state.dictationModel, path);

      await cubit.deleteModel(path);
      await settle();

      // Иначе диктовка осталась бы с путём, за которым ничего нет.
      expect(cubit.state.dictationModel, isEmpty);
      expect(native.calls, contains('trash'));
      // Список моделей стал другим — соседним окнам надо перечитать.
      expect(native.calls, contains('settingsChanged'));
    });

    test('система отказала — говорим об этом, а выбор не трогаем', () async {
      native.trashAllowed = false;
      final path = '${tmp.path}/ggml-условная.bin';
      File(path).writeAsBytesSync(List.filled(16, 1));
      cubit.setDictationModel(path);
      await settle();

      await cubit.deleteModel(path);
      expect(cubit.state.problem, contains('Корзину'));
      expect(cubit.state.dictationModel, path, reason: 'файл на месте');
    });
  });

  group('файлы расшифровок', () {
    test('команды общие, а выключатели у двух режимов независимы', () async {
      cubit.addTextCommand();
      cubit.updateTextCommand(
        0,
        const TextCommand('адрес офиса', 'Минск, Немига, 1'),
      );
      cubit.setDictationCommandsEnabled(false);
      cubit.setTranscriberCommandsEnabled(true);
      await settle();

      final saved = Settings.load();
      expect(
        textCommandsFromJson(saved[textCommandsSetting]).single.replacement,
        'Минск, Немига, 1',
      );
      expect(saved[dictationCommandsEnabledSetting], isFalse);
      expect(saved[transcriberCommandsEnabledSetting], isTrue);
      expect(cubit.state.dictationCommandsEnabled, isFalse);
      expect(cubit.state.transcriberCommandsEnabled, isTrue);
    });

    test('форматы кнопок пишутся в общий источник настроек', () async {
      cubit.setCopyFormat('md');
      cubit.setSaveFormat('srt');
      await settle();

      expect(cubit.state.copyFormat, 'md');
      expect(cubit.state.saveFormat, 'srt');
      expect(Settings.load()['copyFormat'], 'md');
      expect(Settings.load()['saveFormat'], 'srt');
      expect(native.calls, contains('settingsChanged'));
    });

    test('последний формат снять нельзя: сохранять было бы нечего', () async {
      cubit.toggleFormat('srt', true);
      await settle();
      expect(cubit.state.libraryFormats, containsAll(['txt', 'srt']));

      cubit.toggleFormat('srt', false);
      await settle();
      expect(cubit.state.libraryFormats, ['txt']);

      cubit.toggleFormat('txt', false);
      await settle();
      expect(cubit.state.libraryFormats, ['txt'], reason: 'один остаётся');
    });

    test('папка библиотеки пишется в общие настройки', () async {
      cubit.setLibraryPath('/куда-нибудь');
      await settle();
      expect(cubit.state.libraryPath, '/куда-нибудь');
      expect(Settings.load()['libraryPath'], '/куда-нибудь');
    });
  });

  group('приложение', () {
    test('значок приложения переключается и на лету, и в файле', () async {
      cubit.setDockIcon(false);
      await settle();

      expect(cubit.state.dockIcon, isFalse);
      expect(Settings.load()['dockIcon'], isFalse);
      // LSUIElement спрятал бы значок навсегда — переключает только Dart.
      expect(native.calls, contains('dockIcon'));
    });

    test('автозапуск показывает ответ системы, а не наше желание', () async {
      native.loginItemAllowed = false;

      await cubit.setLoginItem(true);
      // Система могла и отказать: галка обязана показывать её ответ.
      expect(cubit.state.loginItem, isFalse);

      native.loginItemAllowed = true;
      await cubit.setLoginItem(true);
      expect(cubit.state.loginItem, isTrue);
    });
  });

  group('местное API', () {
    test('включение рождает ключ, выключение его стирает', () async {
      cubit.setApiEnabled(true);
      await settle();
      final key = cubit.state.apiKey;
      expect(cubit.state.apiEnabled, isTrue);
      expect(key.length, greaterThan(20));
      expect(Settings.load()[apiKeySetting], key);

      // Отдельной кнопки «сменить ключ» нет: старый обязан переставать
      // работать сам, иначе утёкший ключ живёт вечно.
      cubit.setApiEnabled(false);
      await settle();
      expect(cubit.state.apiKey, isEmpty);
      expect(Settings.load()[apiKeySetting], '');

      cubit.setApiEnabled(true);
      await settle();
      expect(cubit.state.apiKey, isNot(key));
    });
  });

  group('чья модель', () {
    // Главная путаница приложения: модель у расшифровщика и у диктовки
    // выбирается порознь, а пустой выбор диктовки означает «та же, что
    // у расшифровщика». В списке моделей это должно быть написано.
    test('пустой выбор диктовки — это модель расшифровщика', () {
      final s = SettingsState(queueModel: '/большая.bin');
      expect(s.dictationModelInUse, '/большая.bin');
      expect(s.userOf('/большая.bin'), 'расшифровщик и диктовка');
    });

    test('свой выбор диктовки разводит их по разным файлам', () {
      final s = SettingsState(
        queueModel: '/большая.bin',
        dictationModel: '/мелкая.bin',
      );
      expect(s.userOf('/большая.bin'), 'расшифровщик');
      expect(s.userOf('/мелкая.bin'), 'диктовка');
      expect(s.userOf('/лишняя.bin'), isNull, reason: 'ею никто не работает');
    });
  });

  group('разрешения', () {
    test('одному «нет» не верим, третьему верим', () async {
      await settle();
      native.permitted = false;

      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'первому отказу не верим');
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue);
      await cubit.checkPermission();
      expect(cubit.state.allowed, isFalse, reason: 'третий — уже правда');

      native.permitted = true;
      await cubit.checkPermission();
      expect(cubit.state.allowed, isTrue, reason: 'любому «да» — сразу');
    });

    test('опрос идёт только пока окно на экране', () async {
      // Движок настроек переживает закрытие окна: без этого опрос тикал бы
      // до выхода из приложения.
      cubit.setVisible(true);
      await settle();
      final asked = native.calls.where((c) => c == 'permissions').length;

      cubit.setVisible(false);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        native.calls.where((c) => c == 'permissions').length,
        asked,
        reason: 'закрытое окно ни о чём не спрашивает',
      );
    });
  });

  group('журналирование', () {
    test(
      'по умолчанию включено, сохраняется и синхронизирует Log.enabled',
      () async {
        expect(cubit.state.loggingEnabled, isTrue);
        expect(Log.enabled, isTrue);

        cubit.setLoggingEnabled(false);
        await settle();

        expect(cubit.state.loggingEnabled, isFalse);
        expect(Log.enabled, isFalse);
        expect(Settings.load()['loggingEnabled'], isFalse);
        expect(native.calls, contains('settingsChanged'));

        cubit.setLoggingEnabled(true);
        await settle();

        expect(cubit.state.loggingEnabled, isTrue);
        expect(Log.enabled, isTrue);
        expect(Settings.load()['loggingEnabled'], isTrue);
      },
    );
  });
}

/// Подставная родная сторона.
class _FakeNative {
  static const _channel = MethodChannel('tsukiko/dictation');
  final calls = <String>[];

  bool permitted = true;
  bool loginItemAllowed = true;
  bool trashAllowed = true;

  Future<void> sendCaptured(Hotkey hotkey) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'tsukiko/dictation',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('captured', hotkey.toJson()),
          ),
          (_) {},
        );
  }

  Future<void> sendReload() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'tsukiko/dictation',
          const StandardMethodCodec().encodeMethodCall(MethodCall('reload')),
          (_) {},
        );
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'permissions' => permitted,
            'loginItem' => loginItemAllowed,
            'trash' => trashAllowed,
            'initialTab' => 'dictation',
            _ => null,
          };
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}
