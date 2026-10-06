import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/os_windows.dart';
import 'package:tsukiko/core/labels.dart';

void main() {
  final win = WindowsOs();

  group('WindowsOs пути и имена', () {
    test('разделители путей и имена папок', () {
      expect(win.join(r'C:\Users\test', 'Documents', 'tsukiko'),
          r'C:\Users\test\Documents\tsukiko');
      expect(win.basename(r'C:\Program Files\tsukiko\tsukiko.exe'),
          'tsukiko.exe');
      expect(win.basename(r'C:/Users/test/model.bin'), 'model.bin');
      expect(win.dirname(r'C:\Program Files\tsukiko\tsukiko.exe'),
          r'C:\Program Files\tsukiko');
    });

    test('системные подписи и элементы интерфейса', () {
      expect(win.fileManagerName, 'Проводник');
      expect(win.appIconAreaName, 'панель задач');
      expect(win.menuBarName, 'область уведомлений');
      expect(win.settingsShortcut, 'Ctrl+,');
      expect(win.accessibilityName, 'специальные возможности');
    });

    test('модификаторы клавиш и сочетания в Windows-стиле', () {
      expect(win.modifierLabel('ctrl'), 'Ctrl');
      expect(win.modifierLabel('cmd'), 'Win');
      expect(win.modifierLabel('opt'), 'Alt');
      expect(win.modifierLabel('alt'), 'Alt');
      expect(win.modifierLabel('shift'), 'Shift');
      expect(win.modifierLabel('fn'), 'Fn');

      // Порядок модификаторов на Windows: Ctrl + Alt + Shift + Win + Fn
      expect(win.shortcutLabel(['shift', 'ctrl'], ['Пробел']),
          'Ctrl + Shift + Пробел');
      expect(win.shortcutLabel(['cmd', 'ctrl', 'alt'], ['O']),
          'Ctrl + Alt + Win + O');
    });

    test('сочетания в меню пишутся словами, а ⌘ становится Ctrl', () {
      // В меню правого щелчка стояли макосные значки — «⇧⌘C» и «⌫», —
      // и на Windows они не говорят человеку ничего.
      expect(win.menuShortcut(const ['shift', 'cmd'], 'c'), 'Ctrl+Shift+C');
      expect(win.menuShortcut(const ['opt', 'cmd'], 'r'), 'Ctrl+Alt+R');
      expect(win.menuShortcut(const [], 'backspace'), 'Backspace');
      // ⌘ в пункте меню — это Ctrl, а не клавиша Windows: с ней
      // сочетание приложению попросту не досталось бы. Тот же обмен
      // делает menu_shortcuts.dart, когда развешивает их взаправду.
      expect(win.menuShortcut(const ['cmd'], 's'), 'Ctrl+S');
      expect(win.modifierLabel('cmd'), 'Win',
          reason: 'в назначенном сочетании cmd — это всё ещё клавиша Windows');
    });

    test('движок выбирается по тому, запустится ли Vulkan-сборка', () {
      // Ответ зависит от машины: есть загрузчик Vulkan — годится
      // Vulkan-сборка, нет — только процессорная. Проверяем правило,
      // а не ответ: на сборочной машине SDK стоит, на моей нет, и
      // закреплять один из двух исходов значило бы ломать тест
      // переездом на другую машину.
      final names = win.engineNames('tsukiko-recognizer');
      final vulkan = names.contains('tsukiko-recognizer-vulkan.exe');

      // Vulkan-сборка, если предлагается, идёт первой: она быстрее,
      // а без видеокарты сама же считает на процессоре.
      expect(names.first,
          vulkan ? 'tsukiko-recognizer-vulkan.exe' : 'tsukiko-recognizer-cpu.exe');
      // Процессорная есть всегда: её запускают там, где vulkan-1.dll нет
      // вовсе и Vulkan-сборку Windows убила бы на запуске.
      expect(names, contains('tsukiko-recognizer-cpu.exe'));
      // Имя без суффикса остаётся запасным: подхватится и собранное руками.
      expect(names, contains('tsukiko-recognizer.exe'));

      final nemo = win.engineNames('nemo-speech');
      expect(nemo, contains(r'nemo-cpu\bin\nemo-speech.exe'));
      expect(
        nemo.first,
        vulkan
            ? r'nemo-vulkan\bin\nemo-speech.exe'
            : r'nemo-cpu\bin\nemo-speech.exe',
      );
    });

    test('проводник зовётся так, чтобы кавычки Dart ничего не сломали', () {
      // Dart на Windows берёт в кавычки каждый довод, без исключений.
      // Проводник получает `"/select,C:\путь"` целиком закавыченным,
      // ключа не узнаёт и открывает «Документы» — отсюда и жалоба
      // «Показать запись не работает». Поэтому командную строку для него
      // собирает PowerShell, и своих кавычек в ней нет ни одной:
      // экранировать их Dart тоже не умеет.
      final cmd = WindowsOs.revealCommand;
      expect(cmd.last, contains('/select,'));
      expect(cmd.last, contains('[char]34'));
      expect(cmd.last, contains(r'$env:' + WindowsOs.revealPathVar));
      for (final arg in cmd) {
        expect(arg, isNot(contains('"')),
            reason: 'кавычка в доводе доедет до PowerShell сломанной');
      }
      // Путь идёт переменной окружения и в разбор PowerShell не попадает
      // вовсе — значит в нём могут быть и пробелы, и кавычки, и что угодно.
      expect(cmd.join(' '), isNot(contains(r'C:\')));
    });

    test('toWav бросает информативное исключение при ошибке подготовки звука', () async {
      expect(
        () => win.toWav(r'C:\nonexistent\audio.aac', r'C:\nonexistent\audio.wav'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Не удалось подготовить звук'),
        )),
      );
    });
  });
}
