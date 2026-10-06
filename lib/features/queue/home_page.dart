import 'dart:async';
import 'dart:io' show Directory, File, Platform, stderr;
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart'
    show
        ImmediateMultiDragGestureRecognizer,
        MultiDragGestureRecognizer,
        kPrimaryButton;
import 'package:flutter/material.dart'
    show ReorderableListView, ReorderableDragStartListener, SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../dictation/dictation_repository.dart';
import '../../core/library.dart';
import '../../core/logger.dart';
import '../../core/models.dart';
import '../../core/recognition.dart';
import '../../core/text.dart';
import '../../core/transcript.dart';
import '../../core/vocabulary.dart';
import '../../design/design.dart';
import '../../design/mascot.dart';
import '../../design/toolbar.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'job.dart';
import 'library_sheet.dart';
import 'prompt_section.dart';
import 'queue_bloc.dart';
import 'queue_event.dart';
import '../../core/update.dart';
import 'menu_shortcuts.dart';
import 'queue_state.dart';
import 'widgets/chrome.dart';
import 'widgets/queue_row.dart';
import 'widgets/scope_banner.dart';
import 'widgets/segment_row.dart';
import 'windows_menu_sheet.dart';
import 'windows_pane_layout.dart';
import '../../core/labels.dart';

part 'home_menus.dart';

/// Главное окно: очередь, расшифровка и инспектор.
///
/// Состоянием владеет [QueueBloc]; здесь остаётся только то, что относится
/// к самому окну, — фокусы, прокрутка, перетаскивание и панель поиска.
/// Всё, что меняет очередь, уходит событием.
class HomePage extends StatelessWidget {
  const HomePage({super.key, this.initialFiles = const []});
  final Iterable<String> initialFiles;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => QueueBloc(NativeBridge())..add(FilesAdded(initialFiles)),
    child: const _HomeView(),
  );
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> with WidgetsBindingObserver {
  static const _windowsFileInput = MethodChannel('tsukiko/file_input');
  // Только про окно: очередь, настройки и распознавание живут в блоке.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _queueFocus = FocusNode(debugLabel: 'очередь');
  final _transcriptScroll = ScrollController();

  bool _dragging = false,
      _draggingQueue = false,
      _scrolled = false,
      _findOpen = false;
  String _query = '';

  QueueBloc get _bloc => context.read<QueueBloc>();
  AppLocalizations get l10n => AppLocalizations.of(context);
  void _send(QueueEvent e) => _bloc.add(e);
  void _sendAll() => _send(const AllSelected());
  void _sendDeselect() => _send(const SelectionCleared());
  void _sendRemove() => _send(const SelectedRemoved());
  void _sendClearFinished() => _send(const FinishedCleared());
  void _sendStart() => _send(const RunRequested());
  void _sendRetry() => _send(const RetryRequested());
  void _sendStop() => _send(const StopRequested());
  void _sendResetOverrides() => _send(const OverridesReset());
  void _sendMakeDefault() => _send(const LeadOptionsMadeDefault());
  void _sendDownload(ModelOffer m) => _send(ModelDownloadRequested(m));
  void _sendEnableVad() => _send(const VadRequested(true));

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _windowsFileInput.setMethodCallHandler((call) async {
        if (!mounted) return;
        if (call.method == 'fileDragEntered') {
          setState(() => _dragging = true);
        } else if (call.method == 'fileDragExited') {
          setState(() => _dragging = false);
        } else if (call.method == 'filesDropped') {
          setState(() => _dragging = false);
          final paths = (call.arguments as List).whereType<String>();
          if (paths.isNotEmpty) _send(FilesAdded(paths));
        }
      });
    }
    WidgetsBinding.instance.addObserver(this);
    _transcriptScroll.addListener(() {
      final scrolled =
          _transcriptScroll.hasClients && _transcriptScroll.offset > 6;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    });
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _query) setState(() => _query = _searchCtrl.text);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _send(WindowVisibilityChanged(state == AppLifecycleState.resumed));

  @override
  void dispose() {
    if (Platform.isWindows) _windowsFileInput.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _queueFocus.dispose();
    _transcriptScroll.dispose();
    super.dispose();
  }

  /// Догон хвоста уже назначен на ближайший кадр.
  ///
  /// Движок отдаёт фрагменты не по одному, а пачкой: он считает окно
  /// в тридцать секунд целиком и печатает всё, что в нём нашлось, разом.
  /// Пачка в полтора десятка строк заводила полтора десятка прокруток
  /// подряд, каждая на 380 мс, и они наезжали друг на друга — список
  /// дёргался, а окно перекладывалось столько же раз. Отсюда и рывки
  /// во время счёта: не память и не модель, а собственная анимация,
  /// запущенная пятнадцать раз вместо одного.
  bool _tailPending = false;

  /// Держимся хвоста, пока пользователь сам не отлистал вверх.
  void _followTail() {
    if (_tailPending || !_transcriptScroll.hasClients) return;
    final pos = _transcriptScroll.position;
    if (pos.maxScrollExtent - pos.pixels > 120) return;
    _tailPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tailPending = false;
      if (!_transcriptScroll.hasClients) return;
      _transcriptScroll.animateTo(
        _transcriptScroll.position.maxScrollExtent,
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
      );
    });
  }

  // ── диалоги и выбор файлов ────────────────────────────────────────────────
  //
  // Всё, для чего нужно окно: блок про окна не знает и спрашивать человека
  // не умеет — он кладёт вопрос в состояние, а показывает его отсюда.

  /// Контекст открытого окна вопроса. Нужен затем, что вопрос может
  /// отпасть сам: диктовка кончилась, расшифровка пошла дальше — а окно
  /// про вытеснение висит поверх идущей работы, пока его не закроют руками.
  BuildContext? _askCtx;

  void _showAsk(Ask ask) {
    showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => _askDialog(dialogContext, ask),
    ).whenComplete(() => _askCtx = null);
  }

  MacosAlertDialog _askDialog(BuildContext dialogContext, Ask ask) {
    _askCtx = dialogContext;
    return MacosAlertDialog(
      appIcon: MacosIcon(
        ask.confirm ? CupertinoIcons.waveform_circle : CupertinoIcons.waveform,
        size: IconSize.hero,
      ),
      title: Text(ask.title, style: Type.emptyTitle),
      message: Text(
        ask.message,
        textAlign: TextAlign.center,
        style: Type.control,
      ),
      primaryButton: PushButton(
        controlSize: ControlSize.large,
        onPressed: () {
          Navigator.pop(dialogContext);
          _send(ask.confirm ? const RunConfirmed(true) : const AskDismissed());
        },
        child: Text(ask.confirm ? l10n.buttonContinue : l10n.buttonUnderstood),
      ),
      secondaryButton: ask.confirm
          ? PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: () {
                Navigator.pop(dialogContext);
                _send(const RunConfirmed(false));
              },
              child: Text(l10n.buttonCancel),
            )
          : null,
    );
  }

  Future<void> _checkUpdates() async {
    _send(StatusReported(l10n.updateChecking));
    final update = await checkForUpdate(appVersion);
    if (!mounted) return;
    if (update == null) {
      _send(StatusReported(l10n.updateNone(appVersion)));
      return;
    }
    _send(StatusReported(l10n.updateFoundTitle(update.version)));
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(
          CupertinoIcons.arrow_down_circle,
          size: IconSize.hero,
        ),
        title: Text(
          l10n.updateFoundTitle(update.version),
          style: Type.emptyTitle,
        ),
        message: Text(
          update.notes.isEmpty ? l10n.updateFoundBody : update.notes,
          textAlign: TextAlign.center,
          style: Type.control,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            Navigator.pop(dialogContext);
            openReleasePage(update.url);
          },
          child: Text(l10n.buttonOpenReleasePage),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonLater),
        ),
      ),
    );
  }

  /// Список сочетаний — там, где строки меню нет.
  ///
  /// На macOS все сочетания видны в строке меню, и отдельный список был бы
  /// вторым местом правды. На Windows строки меню нет вовсе: сочетания
  /// работают (их развешивает `shortcutsFromMenus`), но узнать о них
  /// человеку неоткуда. Берём их из того же дерева меню, что и сами
  /// сочетания, — разойтись им негде.
  void _showShortcuts(QueueState s) {
    final commands = menuCommands(_menus(s));
    showMacosSheet<void>(
      context: context,
      builder: (sheetContext) => MacosSheet(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.section,
                Gap.section,
                Gap.section,
                Gap.control,
              ),
              child: Text(l10n.sheetShortcutsTitle, style: Type.emptyTitle),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.section),
                children: [
                  for (final section in _bySection(commands)) ...[
                    SectionTitle(section.key),
                    for (final c in section.value)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.hint),
                        child: Row(
                          children: [
                            Expanded(child: Text(c.label, style: Type.control)),
                            const SizedBox(width: Gap.item),
                            Text(
                              c.shortcut,
                              style: Type.timestamp.copyWith(
                                color: Surface.secondaryText(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Gap.edge),
              child: PushButton(
                controlSize: ControlSize.large,
                onPressed: () => Navigator.pop(sheetContext),
                child: Text(l10n.buttonClose),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// На Windows родная строка меню не рисуется. Показываем то же
  /// дерево внутри окна — вместе с доступностью и теми же сочетаниями.
  void _showWindowsMenu(QueueState s) => showMacosSheet<void>(
    context: context,
    builder: (_) => WindowsMenuSheet(sections: windowsMenuSections(_menus(s))),
  );

  /// Прошлые расшифровки — всё, что накопила библиотека.
  ///
  /// Лист, а не своё окно: разбор — в `library_sheet.dart`. Список читается
  /// с диска в тот момент, когда его открывают, поэтому блоку про него
  /// знать нечего — как и про список сочетаний.
  void _showLibrary(QueueState s) {
    showMacosSheet<void>(
      context: context,
      // Щелчок мимо листа закрывает его: временное окно, из которого
      // ничего не правят, не должно требовать прицельного попадания
      // в «Закрыть». Esc делает то же — это уже забота самого листа.
      barrierDismissible: true,
      builder: (_) => LibrarySheet(
        root: s.libraryPath,
        onOpenInQueue: (path) => _send(TranscriptOpened(path)),
        onOpenSource: (audio, transcript) =>
            _send(SourceOpened(audio, transcript)),
        onPointAtSource: (transcript) => _pointAtSource(s, transcript),
        onReveal: _revealSource,
        onTrash: _trashFiles,
        onStatus: (text) => _send(StatusReported(text)),
      ),
    );
  }

  /// Спросить, где теперь лежит запись, из которой вышла расшифровка.
  ///
  /// Приложение уже посмотрело два места, куда её могли переложить
  /// (`Sources.locate`), и обходить весь диск не станет: это минуты
  /// работы ради одной строки в окне. А человек знает, куда он её дел, —
  /// и указать проще, чем ждать.
  Future<String?> _pointAtSource(QueueState s, String transcript) async {
    try {
      final f = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: l10n.fileTypeAudioVideo,
            extensions: audioExt.map((e) => e.substring(1)).toList(),
          ),
        ],
      );
      if (f == null) return null;
      Sources.remember(s.libraryPath, [transcript], f.path);
      return f.path;
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to pick source file: $e', e, stack);
      return null;
    }
  }

  /// Убрать файлы в Корзину. Возвращает то, что убрать не вышло.
  ///
  /// В Корзину, а не `unlink`: расшифровка — сделанная человеком работа,
  /// и промах по кнопке не должен стоить её насовсем. Тем же способом
  /// панель диктовки убирает спасённые записи.
  Future<List<String>> _trashFiles(List<String> paths) async {
    final left = <String>[];
    for (final path in paths) {
      if (!await _bloc.bridge.trash(path)) left.add(path);
    }
    return left;
  }

  /// Команды по разделам, в том же порядке, в каком они стоят в меню.
  List<MapEntry<String, List<MenuCommand>>> _bySection(
    List<MenuCommand> commands,
  ) {
    final out = <String, List<MenuCommand>>{};
    for (final c in commands) {
      (out[c.menu] ??= []).add(c);
    }
    return out.entries.toList();
  }

  Future<void> _about() async {
    // Команда меню доступна и пока впереди отдельное окно настроек.
    // Сначала поднимаем главное окно, иначе диалог появлялся под ним.
    await _bloc.bridge.openMainWindow();
    if (!mounted) return;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(
            'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png',
            width: 64,
            height: 64,
            semanticLabel: appName,
            filterQuality: FilterQuality.high,
          ),
        ),
        title: const Text(appName, style: Type.emptyTitle),
        message: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.aboutBody,
              textAlign: TextAlign.center,
              style: Type.control,
            ),
            const SizedBox(height: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: () => os.openUrl('https://feyzart.com/'),
                child: Text(
                  'feyzart.com',
                  style: Type.control.copyWith(
                    color: MacosTheme.of(context).primaryColor,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonClose),
        ),
        // Своего самообновления нет намеренно — см. lib/core/update.dart.
        // Приложение только смотрит, не вышло ли новее, и отводит
        // на страницу выпуска.
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () {
            Navigator.pop(dialogContext);
            _checkUpdates();
          },
          child: Text(l10n.buttonCheckUpdates),
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    if (Platform.isWindows) {
      try {
        final paths = await _windowsFileInput.invokeListMethod<String>(
          'pickAudioFiles',
        );
        if (mounted && paths != null && paths.isNotEmpty) {
          _send(FilesAdded(paths));
        }
      } on PlatformException catch (error) {
        Log.error('Queue', 'Windows file dialog failed: $error', error);
      }
      return;
    }
    try {
      final files = await openFiles(
        acceptedTypeGroups: [
          XTypeGroup(
            label: l10n.fileTypeAudioVideo,
            extensions: audioExt.map((e) => e.substring(1)).toList(),
          ),
        ],
      );
      if (files.isNotEmpty) _send(FilesAdded(files.map((f) => f.path)));
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to pick audio files: $e', e, stack);
    }
  }

  Future<void> _openTranscript() async {
    try {
      final f = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: l10n.fileTypeTranscripts,
            extensions: transcriptExt.map((e) => e.substring(1)).toList(),
          ),
        ],
      );
      if (f != null && f.path.trim().isNotEmpty) {
        _send(TranscriptOpened(f.path.trim()));
      }
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to pick transcript file: $e', e, stack);
    }
  }

  /// Переложить готовую расшифровку в другой формат.
  ///
  /// На входе нужны метки времени: из обычного txt нельзя честно
  /// восстановить границы субтитров. Разобранные SRT, VTT, JSON и наш txt
  /// с метками имеют одну модель [Transcript], поэтому между ними нет
  /// цепочки потерь-парсеров: читаем один раз, пишем один раз.
  Future<void> _convertTranscript() async {
    try {
      final input = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: l10n.fileTypeTranscripts,
            extensions: transcriptExt.map((e) => e.substring(1)).toList(),
          ),
        ],
      );
      if (input == null) return;

      final read = readTranscript(
        input.path,
        await File(input.path).readAsString(),
      );
      final transcript = read.parsed;
      if (transcript == null) {
        return _showAsk(
          Ask(
            l10n.askConversionNeedsTimestampsTitle,
            l10n.askConversionNeedsTimestampsBody,
          ),
        );
      }

      final preferred = formatById(_bloc.state.saveFormat);
      final offered = [
        preferred,
        ...exportFormats.where((f) => f.id != preferred.id),
      ];
      final inputName = os.basename(input.path);
      final inputFormat = formatOfFile(inputName);
      final stem =
          inputFormat != null &&
              inputName.toLowerCase().endsWith(inputFormat.suffix.toLowerCase())
          ? inputName.substring(0, inputName.length - inputFormat.suffix.length)
          : _stem(inputName);
      final location = await getSaveLocation(
        suggestedName: preferred.fileName(stem),
        acceptedTypeGroups: [
          for (final format in offered)
            XTypeGroup(
              label: format.label,
              extensions: [format.ext.substring(1)],
            ),
        ],
      );
      if (location == null) return;
      final chosen = formatOfFile(location.path) ?? preferred;
      final output = location.path.toLowerCase().endsWith(chosen.ext)
          ? location.path
          : '${location.path}${chosen.ext}';
      await File(output).writeAsString(
        renderFor(chosen, transcript, name: os.basename(input.path)),
      );
      _send(SaveFormatChosen(chosen));
      _send(StatusReported(l10n.statusTranscriptConverted));
    } catch (error, stack) {
      Log.warn('Queue', 'Transcript conversion failed: $error', error, stack);
      stderr.writeln('tsukiko: расшифровка не преобразовалась — $error');
      _showAsk(
        Ask(l10n.askConversionFailedTitle, l10n.askConversionFailedBody),
      );
    }
  }

  /// Выбранный руками файл проверяем: «.bin» лежит на чём угодно, а
  /// whisper-cli на чужом файле падает с руганью про тензоры — человеку
  /// из неё не понять, что он выбрал не то.
  Future<void> _pickModel() async {
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'GGML / GGUF', extensions: ['bin', 'gguf']),
        ],
      );
      if (f == null) return;
      final problem = modelFileProblem(f.path);
      if (problem != null) {
        return _showAsk(Ask(l10n.askNotRecognitionModelTitle, problem));
      }
      _send(ModelChosen(f.path));
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to pick model file: $e', e, stack);
    }
  }

  Future<void> _saveAs(QueueState s, [ExportFormat? format]) async {
    final f = format ?? formatById(s.saveFormat);
    final jobs = s.readyTargets;
    // Сохранять нечего. Если при этом формат выбрали руками — запоминаем
    // его: это настройка, а не действие.
    if (jobs.isEmpty) {
      if (format != null) _send(SaveFormatChosen(format));
      return;
    }
    // Одна запись — обычный «Сохранить как…»; несколько — выбор папки,
    // потому что спрашивать имя шесть раз подряд невыносимо.
    if (jobs.length > 1) return _exportInto(jobs, [f]);

    final job = jobs.single;
    // Все форматы, а не один: и NSSavePanel, и диалог Windows рисуют список
    // типов файла сами, и выбор формата уместнее там, чем ещё одним нашим
    // окном поверх системного. Первым идёт тот, которым сохраняли в прошлый
    // раз, — он же и предложится.
    final offered = [f, ...exportFormats.where((g) => g.id != f.id)];
    try {
      final loc = await getSaveLocation(
        suggestedName: f.fileName(_stem(job.name)),
        acceptedTypeGroups: [
          for (final g in offered)
            XTypeGroup(label: g.label, extensions: [g.ext.substring(1)]),
        ],
      );
      if (loc == null) return;
      // Ничего не узнали — остаётся тот формат, с которым диалог открывали.
      final chosen = formatOfFile(loc.path) ?? f;
      // Диалог мог отдать путь без расширения — дописываем сами.
      final path = loc.path.toLowerCase().endsWith(chosen.ext)
          ? loc.path
          : '${loc.path}${chosen.ext}';
      _send(SaveRequested(job, path, chosen));
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to get save location: $e', e, stack);
    }
  }

  Future<void> _exportAll(QueueState s) async {
    final jobs = s.readyTargets.isNotEmpty
        ? s.readyTargets
        : s.jobs.where((j) => j.done).toList();
    if (jobs.isEmpty) return;
    await _exportInto(jobs, s.libraryFormats.map(formatById).toList());
  }

  Future<void> _exportInto(List<Job> jobs, List<ExportFormat> formats) async {
    if (formats.isEmpty) return;
    try {
      final dir = await getDirectoryPath(confirmButtonText: l10n.buttonExport);
      if (dir != null && dir.trim().isNotEmpty) {
        _send(ExportRequested(jobs, dir.trim(), formats));
      }
    } catch (e, stack) {
      Log.warn('Queue', 'Failed to pick export directory: $e', e, stack);
    }
  }

  String _stem(String name) {
    final i = name.lastIndexOf('.');
    return i <= 0 ? name : name.substring(0, i);
  }

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  void _copy([ExportFormat? format]) {
    final s = _bloc.state;
    _send(CopyRequested(format ?? formatById(s.copyFormat)));
  }

  /// Отдать текст ошибки движка в буфер обмена.
  ///
  /// Отдельно от [_copy]: тот копирует расшифровку в выбранном формате,
  /// а здесь нужно ровно то, что сказал движок, — чтобы человек мог
  /// переслать это как есть. Пока движок не поднимается, это
  /// единственное, по чему видно причину.
  void _copyError(Job job) {
    final text = job.error;
    if (text == null || text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _send(StatusReported(l10n.statusErrorCopied));
  }

  /// Из главного окна настройки открываются на вкладке расшифровщика:
  /// это его окно, и «Настройки…» отсюда — про него. На диктовку ведёт
  /// её собственная панель у строки меню.
  Future<void> _openSettings([String tab = 'transcriber']) =>
      _bloc.bridge.openSettings(tab);

  /// Показать исходную запись. Её могли убрать мимо приложения — тогда
  /// говорим об этом, а не открываем пустое место.
  ///
  /// Папку библиотеки при этом заводим, если её ещё нет: «открыть папку»
  /// в пустой библиотеке разумно понимать как «заведи и открой», а вот
  /// создавать пропавший файл значило бы показать подделку вместо него.
  Future<void> _revealSource(String path) async {
    final folder = Directory(path).existsSync() || !File(path).existsSync();
    if (await revealInFinder(path, createIfMissing: folder)) return;
    _send(StatusReported(l10n.statusSourceGone(os.basename(path))));
  }

  // ── как называется занятость ──────────────────────────────────────────────

  /// Модели нет вовсе. «Модель свободна» в этом случае — неправда: свободна
  /// не она, а место, где её нет. Человек читает это как «всё готово»
  /// и удивляется первой же неудаче.
  bool _noModel(QueueState s) => s.models.isEmpty && s.shown.model.isEmpty;

  /// Кто держит модель. Занять её могут только двое, и оба свои:
  /// расшифровщик и диктовка.
  String _modelUseLabel(QueueState s) => s.transcribing
      ? l10n.modelUseLabelTranscription
      : switch (s.dictation) {
          DictationStatus.busy => l10n.modelUseLabelDictation,
          DictationStatus.resting => l10n.modelUseLabelResting,
          DictationStatus.away =>
            _noModel(s) ? l10n.modelUseLabelNone : l10n.modelUseLabelFree,
        };

  String _modelUseDetail(QueueState s) => s.transcribing
      ? l10n.modelUseDetailTranscription
      : switch (s.dictation) {
          DictationStatus.busy => l10n.modelUseDetailDictation,
          DictationStatus.resting => l10n.modelUseDetailResting,
          DictationStatus.away =>
            _noModel(s) ? l10n.modelUseDetailNone : l10n.modelUseDetailFree,
        };

  static const _cmd = SingleActivator(LogicalKeyboardKey.keyO, meta: true);

  List<Object?>? _menuSignature;
  List<PlatformMenuItem> _menuCache = const [];

  /// Настроение кота выводится из того, что приложение делает прямо сейчас.
  Mood _mood(QueueState s, Job? job) => moodFor(
    dragging: _dragging || _draggingQueue,
    running: s.running,
    jobActive: job?.active ?? false,
    hasJobs: job != null,
    longWait: (job?.segments.isEmpty ?? true) && job?.raw == null,
  );

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QueueBloc, QueueState>(
      listenWhen: (was, now) =>
          was.ask != now.ask ||
          (was.lead?.live.length ?? 0) != (now.lead?.live.length ?? 0),
      listener: (context, s) {
        // Новый фрагмент — держимся хвоста, пока человек сам не отлистал.
        if ((s.lead?.live.length ?? 0) > 0) _followTail();
        final ask = s.ask;
        if (ask != null) {
          _showAsk(ask);
        } else if (_askCtx != null) {
          // Вопрос снят самим блоком — окно про него закрываем сами.
          Navigator.pop(_askCtx!);
        }
      },
      builder: (context, s) => _window(s),
    );
  }

  /// Строка меню — вещь macOS. Там она и рисуется, и раздаёт сочетания
  /// клавиш; на Windows `PlatformMenuBar` показывает только содержимое,
  /// и без этой обёртки не работало бы ни одно сочетание.
  Widget _window(QueueState s) {
    final menus = _menus(s);
    final window = PlatformMenuBar(menus: menus, child: _windowBody(s));
    if (os.hasSystemMenuBar) return window;
    return CallbackShortcuts(
      bindings: {
        ...shortcutsFromMenus(menus, swapMetaForControl: true),
        // F1 — привычная клавиша справки на Windows, и справка здесь
        // ровно одна: какие вообще есть сочетания.
        const SingleActivator(LogicalKeyboardKey.f1): () => _showShortcuts(s),
      },
      child: window,
    );
  }

  /// На macOS колонки рисует [MacosWindow] поверх системного материала.
  /// На Windows та же пакетная раскладка вырезает прозрачную дыру и
  /// требует полноэкранного saveLayer, поэтому там — обычные непрозрачные
  /// колонки без дорогостоящего промежуточного буфера.
  Widget _windowBody(QueueState s) {
    if (os.hasWindowMaterial) return _macosWindow(s);
    return WindowsPaneLayout(
      leftBuilder: (context, controller) => _queue(s, controller),
      leftBottom: _queueButtons(s),
      center: _contentScaffold(s),
      rightBuilder: (context, controller) => _inspector(s, controller),
      rightTop: InspectorHeader(
        onOpenSettings: () => _openSettings('transcriber'),
        onOpenRecordings: () =>
            revealInFinder(s.libraryPath, createIfMissing: true),
        onOpenModels: () => revealInFinder(os.modelsDir, createIfMissing: true),
      ),
    );
  }

  Widget _macosWindow(QueueState s) => Builder(
    builder: (context) => MacosWindow(
      disableWallpaperTinting: !os.hasWindowMaterial,
      sidebar: Sidebar(
        minWidth: 248,
        startWidth: 276,
        // Там, где материала окна нет, боковая колонка остаётся
        // прозрачной — то есть чёрной. Красим сами.
        decoration: Surface.sidebarDecoration(context),
        builder: (context, controller) => _queue(s, controller),
        bottom: _queueButtons(s),
      ),
      endSidebar: Sidebar(
        minWidth: 290,
        startWidth: 312,
        maxWidth: 380,
        shownByDefault: true,
        decoration: Surface.sidebarDecoration(context),
        topOffset: 0,
        builder: (context, controller) => Column(
          children: [
            InspectorHeader(
              onOpenSettings: () => _openSettings('transcriber'),
              onOpenRecordings: () =>
                  revealInFinder(s.libraryPath, createIfMissing: true),
              onOpenModels: () =>
                  revealInFinder(os.modelsDir, createIfMissing: true),
            ),
            Expanded(child: _inspector(s, controller)),
          ],
        ),
      ),
      child: _contentScaffold(s),
    ),
  );

  Widget _contentScaffold(QueueState s) => MacosScaffold(
    backgroundColor: MacosTheme.of(context).canvasColor,
    toolBar: _toolbar(s),
    children: [
      ContentArea(
        builder: (context, _) => Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  if (_findOpen) _findBar(s),
                  Expanded(child: _transcriptArea(s)),
                ],
              ),
            ),
            Positioned(left: 0, right: 0, bottom: 0, child: _statusBar(s)),
          ],
        ),
      ),
    ],
  );

  /// Значок панели инструментов, окрашенный по доступности.
  ///
  /// macos_ui красит их одинаково и на доступной кнопке, и на серой:
  /// половинная прозрачность в обоих случаях. То есть по виду кнопки
  /// нельзя было понять, нажмётся она или нет — человек жал «Сохранить»
  /// на пустой очереди и не понимал, отчего ничего не происходит.
  /// Свой цвет у `MacosIcon` главнее того, что даёт тема, поэтому
  /// хватает одной строки на кнопку.
  MacosIcon _toolIcon(IconData icon, {required bool on}) =>
      MacosIcon(icon, color: Surface.toolbarIcon(context, enabled: on));

  AppToolBar _toolbar(QueueState s) {
    final ready = s.readyTargets.isNotEmpty;
    final copyFormat = formatById(s.copyFormat);
    final saveFormat = formatById(s.saveFormat);
    final canConvert =
        s.lead?.transcript?.segments.isNotEmpty == true ||
        s.lead?.isDone == true;

    return AppToolBar(
      title: const ToolbarTitle(),
      // Полное имя записи уже есть в очереди. Здесь остаётся только
      // название приложения и ровно столько места, сколько оно занимает.
      titleWidth: 72,
      enableBlur: os.hasWindowMaterial,
      // Кромка появляется только когда под панель что-то уехало.
      dividerColor: _scrolled
          ? Surface.hairline(context)
          : MacosColors.transparent,
      actions: [
        ToolBarIconButton(
          label: l10n.buttonAdd,
          icon: _toolIcon(CupertinoIcons.add, on: true),
          showLabel: false,
          tooltipMessage: l10n.tooltipAddAudioShortcut,
          onPressed: _pickFiles,
        ),
        if (!os.hasSystemMenuBar)
          ToolBarIconButton(
            label: l10n.sheetApplicationMenuTitle,
            icon: _toolIcon(CupertinoIcons.line_horizontal_3, on: true),
            showLabel: false,
            tooltipMessage: l10n.tooltipApplicationMenu,
            onPressed: () => _showWindowsMenu(s),
          ),
        // Рядом с «Добавить», и это одно и то же действие с двух сторон:
        // взять в работу новую запись или вернуться к разобранной.
        ToolBarIconButton(
          label: l10n.sheetLibraryTitle,
          icon: _toolIcon(CupertinoIcons.clock, on: true),
          showLabel: false,
          tooltipMessage: l10n.tooltipPastTranscripts(
            os.menuShortcut(const ['cmd'], 'l'),
          ),
          onPressed: () => _showLibrary(s),
        ),
        ToolBarIconButton(
          label: s.running ? l10n.menuStop : l10n.buttonRecognize,
          icon: _toolIcon(
            s.running
                ? CupertinoIcons.stop_fill
                : s.dictation == DictationStatus.busy
                ? CupertinoIcons.pause_circle
                : CupertinoIcons.play_fill,
            on: s.running || s.hasPending,
          ),
          showLabel: false,
          tooltipMessage: s.running
              ? (s.waitingForModel
                    ? l10n.tooltipWaitingForDictation
                    : l10n.tooltipStopShortcut)
              : s.dictation == DictationStatus.busy
              ? l10n.tooltipDictationBusyWillStart
              : l10n.tooltipRunQueueShortcut,
          onPressed: s.running ? _sendStop : (s.hasPending ? _sendStart : null),
        ),
        // Пауза отдельной кнопкой, а не вместо остановки: это разные
        // вещи. Остановленное начинают заново, приостановленное —
        // досчитывают с той же секунды.
        ToolBarIconButton(
          label: s.hasPaused && !s.running
              ? l10n.buttonResume
              : l10n.buttonPause,
          icon: _toolIcon(
            s.hasPaused && !s.running
                ? CupertinoIcons.play_circle
                : CupertinoIcons.pause_fill,
            on: s.running || s.hasPaused,
          ),
          showLabel: false,
          tooltipMessage: s.hasPaused && !s.running
              ? l10n.tooltipResume
              : l10n.tooltipPauseShortcut,
          onPressed: s.running
              ? () => _send(const PauseRequested())
              : s.hasPaused
              ? () => _send(const ResumeRequested())
              : null,
        ),
        ToolBarIconButton(
          label: _recognizeLabel(s.targets, many: s.targets.length > 1),
          icon: _toolIcon(
            CupertinoIcons.arrow_counterclockwise,
            on: !s.running && s.targets.any((j) => !j.imported),
          ),
          showLabel: false,
          tooltipMessage: l10n.tooltipRetryShortcut,
          onPressed: s.running || !s.targets.any((j) => !j.imported)
              ? null
              : _sendRetry,
        ),
        // Кнопка повторяет прошлый выбор, стрелка рядом даёт его сменить.
        ToolBarIconButton(
          label: l10n.buttonCopyToolbar,
          icon: _toolIcon(CupertinoIcons.doc_on_clipboard, on: ready),
          showLabel: false,
          tooltipMessage: l10n.tooltipCopyFormat(
            copyFormat.label.toLowerCase(),
          ),
          onPressed: ready ? () => _copy() : null,
        ),
        // Список открыт всегда, даже когда копировать нечего: формат —
        // это настройка, её выбирают заранее. Серым он был ровно до
        // первой готовой расшифровки, то есть до того мгновения, когда
        // выбирать уже поздно.
        //
        // Тот же список, что у сохранения. Раньше здесь стояло четыре
        // формата из шести, и разница вылезала боком: в панели
        // переполнения «Формат сохранения» показывал все, а рядом
        // лежащее «Копировать» — не все, и понять, отчего их то шесть,
        // то четыре, было нельзя. Markdown и JSON копируются ровно так
        // же, как сохраняются, — прятать их было не за что.
        AppToolBarPullDownButton(
          label: l10n.labelCopyFormat,
          icon: CupertinoIcons.doc_on_clipboard,
          tooltipMessage: l10n.tooltipChooseCopyFormat,
          items: [
            for (final f in exportFormats)
              _formatItem(f, s.copyFormat, () => _copy(f)),
          ],
        ),
        ToolBarIconButton(
          label: l10n.buttonSaveToolbar,
          icon: _toolIcon(CupertinoIcons.arrow_down_doc, on: ready),
          showLabel: false,
          tooltipMessage: l10n.tooltipSaveFormat(
            saveFormat.label.toLowerCase(),
          ),
          onPressed: ready ? () => _saveAs(s) : null,
        ),
        AppToolBarPullDownButton(
          label: l10n.labelSaveFormat,
          icon: CupertinoIcons.arrow_down_doc,
          tooltipMessage: l10n.tooltipChooseSaveFormat,
          items: [
            for (final f in exportFormats)
              _formatItem(f, s.saveFormat, () => _saveAs(s, f)),
            // А вот выгрузка в папку — действие, и без готовых
            // расшифровок ей делать нечего.
            if (ready) ...[
              const MacosPulldownMenuDivider(),
              MacosPulldownMenuItem(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: IconSize.button + Gap.inner),
                    Text(l10n.menuExportToFolder),
                  ],
                ),
                label: l10n.labelExportToFolder,
                onTap: () => _exportAll(s),
              ),
            ],
          ],
        ),
        ToolBarIconButton(
          label: l10n.buttonFind,
          icon: _toolIcon(CupertinoIcons.search, on: s.lead != null),
          showLabel: false,
          tooltipMessage: l10n.tooltipFindShortcut,
          onPressed: s.lead == null ? null : _openFind,
        ),
        // На macOS преобразование живёт в системном меню «Файл».
        // На Windows системной строки меню нет, поэтому даём тому же
        // действию свою кнопку; в тесном окне она остаётся под многоточием.
        if (!os.hasSystemMenuBar)
          ToolBarIconButton(
            label: l10n.menuConvertTranscript,
            icon: _toolIcon(CupertinoIcons.arrow_2_squarepath, on: canConvert),
            showLabel: false,
            tooltipMessage: l10n.menuConvertTranscript,
            onPressed: canConvert ? _convertTranscript : null,
          ),
        // Последним — и это не случайность. Панель инструментов прячет
        // лишнее с конца: чем шире боковая колонка, тем меньше её остаётся,
        // и первыми уходят те, кто стоит правее. Раньше кнопка сочетаний
        // стояла второй, а копирование — в середине, и стоило растянуть
        // очередь, как из панели пропадало именно копирование расшифровки —
        // то, ради чего в неё и смотрят. Порядок здесь и есть порядок
        // важности: добавить, распознать, приостановить, повторить,
        // скопировать, сохранить, найти — и только потом справка о
        // клавишах, до которой есть F1.
        if (!os.hasSystemMenuBar)
          ToolBarIconButton(
            label: l10n.sheetShortcutsTitle,
            icon: _toolIcon(CupertinoIcons.keyboard, on: true),
            showLabel: false,
            tooltipMessage: '${l10n.sheetShortcutsTitle} · F1',
            onPressed: () => _showShortcuts(s),
          ),
      ],
    );
  }

  /// Панель поиска приходит сверху и уходит по Esc — как в Safari и Xcode,
  /// а не занимает место в панели инструментов всё время.
  Widget _findBar(QueueState s) => Container(
    height: 40,
    padding: const EdgeInsets.fromLTRB(Gap.item, 0, Gap.inner, 0),
    decoration: BoxDecoration(
      color: Surface.chrome(context),
      border: Border(bottom: BorderSide(color: Surface.hairline(context))),
    ),
    child: Row(
      children: [
        Expanded(
          child: Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _closeFind();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: MacosSearchField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              placeholder: l10n.placeholderFindInTranscript,
              placeholderStyle: Surface.placeholder(context),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
        const SizedBox(width: Gap.control),
        Text(
          _findSummary(s),
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
        ),
        const SizedBox(width: Gap.inner),
        MacosIconButton(
          icon: const MacosIcon(CupertinoIcons.xmark, size: IconSize.button),
          onPressed: _closeFind,
        ),
      ],
    ),
  );

  String _findSummary(QueueState s) {
    final job = s.lead;
    if (job == null || _query.trim().isEmpty) return l10n.hintEscToClose;
    final hits = _visibleSegments(job).length;
    return hits == 0
        ? l10n.nothingFound
        : l10n.statusFoundSegments(segmentsLabel(hits));
  }

  void _openFind() {
    setState(() => _findOpen = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  void _closeFind() {
    setState(() {
      _findOpen = false;
      _query = '';
      _searchCtrl.clear();
    });
    _queueFocus.requestFocus();
  }

  /// Галочкой отмечен формат, который повторяет кнопка.
  MacosPulldownMenuItem _formatItem(
    ExportFormat f,
    String current,
    VoidCallback tap,
  ) => MacosPulldownMenuItem(
    // Обычное меню рисует галочку в title ниже, а меню многоточия
    // выбрасывает title и оставляет только label. Значит выбранность
    // обязана жить и в строке — иначе именно в тесном окне, где всё
    // ушло под многоточие, нынешний формат узнать было невозможно.
    label: f.label,
    onTap: tap,
    title: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Колонка под галку — одной ширины у всех строк, иначе
        // подписи разъезжаются. Сама галка была вдвое мельче
        // системной и стояла вплотную к тексту.
        SizedBox(
          width: IconSize.button + Gap.inner,
          child: f.id == current
              ? const MacosIcon(
                  CupertinoIcons.checkmark_alt,
                  size: IconSize.button,
                )
              : null,
        ),
        Text(f.label),
      ],
    ),
  );

  // ── очередь ───────────────────────────────────────────────────────────────

  /// Колонка очереди принимает файлы наравне с окном расшифровки.
  ///
  /// Не принимала — и это сбивало: под списком написано «перетащите сюда
  /// аудио», а брошенное мимо середины окна пропадало. Место, которое
  /// зовёт бросить файл, обязано его брать.
  Widget _queue(QueueState s, ScrollController controller) => DropTarget(
    onDragEntered: (_) => setState(() => _draggingQueue = true),
    onDragExited: (_) => setState(() => _draggingQueue = false),
    onDragDone: (details) {
      setState(() => _draggingQueue = false);
      _send(FilesAdded(details.files.map((f) => f.path)));
    },
    child: Stack(
      children: [
        Positioned.fill(
          child: AnimatedOpacity(
            duration: Motion.dur(context, Motion.toss),
            curve: Motion.curve(context, Motion.tossCurve),
            opacity: _draggingQueue ? 0.0 : 1.0,
            child: _queueList(s, controller),
          ),
        ),
        Positioned.fill(
          child: DropVeil(
            active: _draggingQueue,
            compact: true,
            title: l10n.dropVeilHint,
          ),
        ),
      ],
    ),
  );

  Widget _queueList(QueueState s, ScrollController controller) {
    if (s.jobs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.edge),
          child: Text(
            l10n.emptyQueueHint(l10n.buttonAdd),
            textAlign: TextAlign.center,
            style: Type.caption.copyWith(
              color: Surface.secondaryText(context),
              height: 1.5,
            ),
          ),
        ),
      );
    }
    // Клавиши работают, когда список в фокусе, — как в любом списке macOS.
    return Focus(
      focusNode: _queueFocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final shift = HardwareKeyboard.instance.isShiftPressed;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowDown:
            _send(SelectionStepped(1, extend: shift));
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            _send(SelectionStepped(-1, extend: shift));
            return KeyEventResult.handled;
          case LogicalKeyboardKey.backspace:
          case LogicalKeyboardKey.delete:
            _sendRemove();
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // Порядок очереди — дело хозяйское: срочное поднимают наверх
      // перетаскиванием, как в любом списке macOS. Свои «ручки» Flutter
      // не рисуем: тянется вся строка, а простой щелчок так и остаётся
      // выделением — тащить начинают только когда повели курсор.
      child: ReorderableListView.builder(
        scrollController: controller,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.all(Gap.inner),
        onReorderItem: (from, to) => _send(JobsReordered(from, to)),
        itemCount: s.jobs.length,
        itemBuilder: (context, i) {
          final job = s.jobs[i];
          return _QueueDragListener(
            key: ValueKey(job.path),
            index: i,
            child: ContextMenuRegion(
              // Правый щелчок по невыделенной записи сначала выделяет её —
              // как в Finder. Это действие жеста, а не построения меню:
              // раньше выделение менялось внутри actions(), то есть setState
              // случался посреди сборки списка пунктов.
              onOpen: () {
                if (!s.selected.contains(job)) _send(JobSelected(job));
              },
              actions: () => _rowActions(s, job),
              child: QueueRow(
                job: job,
                selected: s.selected.contains(job),
                lead: identical(job, s.lead),
                customised: job.overrides != null,
                onTap: () {
                  _queueFocus.requestFocus();
                  final keys = HardwareKeyboard.instance;
                  if (keys.isMetaPressed) {
                    _send(JobToggled(job));
                  } else if (keys.isShiftPressed) {
                    _send(SelectionExtended(job));
                  } else {
                    _send(JobSelected(job));
                  }
                },
              ),
            ),
          );
        },
      ),
    );
  }

  /// Пункты меню правого щелчка. Считает по нынешнему выделению и ничего
  /// не меняет: выделить запись под курсором — дело жеста (onOpen).
  ///
  /// Выделение, которое ставит жест, доедет только следующим состоянием:
  /// оно уходит событием в блок, а пункты собираются здесь и сейчас. Значит
  /// считать по одному лишь `s.selected` нельзя — по первому щелчку в
  /// нетронутой очереди там пусто, и «Распознать заново» с «Копировать»
  /// вышли бы серыми. Поэтому целью считаем то же, что посчитает блок:
  /// выделенное, а если запись под курсором в него не входит — саму её.
  List<MenuAction> _rowActions(QueueState s, Job job) {
    final targets = s.selected.contains(job) ? s.targets : [job];
    final many = targets.length > 1;
    final ready = targets.any((j) => j.done);
    final canRetry = targets.any((j) => !j.imported);
    return [
      MenuAction(
        l10n.menuCopyFormat(formatById(s.copyFormat).label.toLowerCase()),
        onSelected: ready ? () => _copy() : null,
        shortcut: os.menuShortcut(const ['shift', 'cmd'], 'c'),
      ),
      MenuAction(
        l10n.menuSaveAs,
        onSelected: ready ? () => _saveAs(s) : null,
        shortcut: os.menuShortcut(const ['cmd'], 's'),
      ),
      // Только у той записи, что не задалась: у остальных пункт был бы
      // всегда серым и только мешал.
      if (job.error != null) ...[
        const MenuAction.separator(),
        MenuAction(l10n.menuCopyErrorText, onSelected: () => _copyError(job)),
        MenuAction(l10n.menuOpenLogsFolder, onSelected: () => Log.openLogsFolder()),
      ],
      const MenuAction.separator(),
      // «Заново» — только про то, что уже считали. Нераспознанную запись
      // распознают в первый раз, и слово «заново» в этом случае просто
      // неправда: человек читает его как «сбросить и посчитать снова»
      // и не понимает, что сбрасывать.
      MenuAction(
        _recognizeLabel(targets, many: many),
        onSelected: s.running || !canRetry ? null : _sendRetry,
        shortcut: os.menuShortcut(const ['opt', 'cmd'], 'r'),
      ),
      MenuAction(
        l10n.buttonShowInFileManager(os.fileManagerName),
        onSelected: () => _revealSource(job.path),
        shortcut: os.menuShortcut(const ['cmd'], 'r'),
      ),
      const MenuAction.separator(),
      if (job.overrides != null)
        MenuAction(
          l10n.menuRestoreDefaultSettings,
          onSelected: _sendResetOverrides,
        ),
      MenuAction(
        many ? l10n.menuRemoveSelected : l10n.menuRemoveFromQueue,
        onSelected: targets.any((j) => j.active) ? null : _sendRemove,
        shortcut: os.menuShortcut(const [], 'backspace'),
      ),
    ];
  }

  /// Как назвать повторное распознавание для этих записей.
  String _recognizeLabel(List<Job> targets, {required bool many}) {
    final again = targets.isNotEmpty && targets.every((j) => j.done);
    if (many) {
      return again ? l10n.menuRetrySelected : l10n.menuRecognizeSelected;
    }
    return again ? l10n.menuRetryRecognition : l10n.menuRecognize;
  }

  Widget _queueButtons(QueueState s) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Gap.control,
      Gap.inner,
      Gap.control,
      Gap.control,
    ),
    child: Row(
      children: [
        Expanded(
          child: PushButton(
            controlSize: ControlSize.regular,
            onPressed: _pickFiles,
            child: Text(l10n.buttonAdd),
          ),
        ),
        const SizedBox(width: Gap.control),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: s.targets.isEmpty || s.targets.any((j) => j.active)
              ? null
              : _sendRemove,
          child: Text(l10n.buttonRemove),
        ),
      ],
    ),
  );

  // ── расшифровка ───────────────────────────────────────────────────────────

  /// Отфильтрованная расшифровка и то, для чего она посчитана.
  ///
  /// Считать заново на каждый кадр нельзя: во время распознавания окно
  /// перерисовывается десятки раз в секунду, а на длинной записи это
  /// `toLowerCase` по каждому фрагменту. Ответ меняется, только когда
  /// меняется запрос или сама расшифровка, — по ним и сверяемся.
  List<Segment>? _filtered;
  ({Job? job, String query, int count})? _filterFor;

  List<Segment> _visibleSegments(Job job) {
    final all = job.segments;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;

    final key = (job: job, query: q, count: all.length);
    final cached = _filtered;
    if (cached != null && _filterFor == key) return cached;

    final hits = all.where((s) => s.text.toLowerCase().contains(q)).toList();
    _filterFor = key;
    return _filtered = hits;
  }

  Widget _transcriptArea(QueueState s) {
    final job = s.lead;

    Widget content;
    if (job == null && s.models.isEmpty) {
      // Пустее пустого: распознавать нечем. Пока модели нет, разговор про
      // перетаскивание файлов бессмыслен.
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: l10n.titleNeedRecognitionModel,
          subtitle: l10n.subtitleNeedRecognitionModel,
          action: _modelDownload(),
        ),
      );
    } else if (job == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: l10n.titleDropAudioHere,
          subtitle: l10n.subtitleDropAudioHere,
        ),
      );
    } else if (job.segments.isEmpty && job.raw == null) {
      content = Center(
        child: MascotPlaceholder(
          mood: _mood(s, job),
          title: job.active ? l10n.titleListening : l10n.titleReadyToRecognize,
          subtitle: job.active
              ? l10n.subtitleListening
              : l10n.subtitleReadyToRecognize,
        ),
      );
    } else if (job.transcript == null && job.raw != null) {
      content = SingleChildScrollView(
        controller: _transcriptScroll,
        // Левый край тот же, что у списка фрагментов ниже: поле самого
        // списка плюс поле его строки. Это одна и та же панель в двух
        // видах, и текст в ней обязан начинаться в одном месте.
        //
        // Снизу вчетверо больше — там висит полоса состояния, и последняя
        // строка не должна уезжать под неё.
        padding: const EdgeInsets.fromLTRB(
          Gap.edge + Gap.inner,
          Gap.edge,
          Gap.edge + Gap.inner,
          Gap.item * 4,
        ),
        child: SelectableText(job.raw!, style: Type.body),
      );
    } else {
      final segments = _visibleSegments(job);
      if (segments.isEmpty) {
        content = Center(
          child: EmptyNotice(
            icon: CupertinoIcons.search,
            title: l10n.nothingFound,
            subtitle: l10n.subtitleQueryNotFound(_query),
          ),
        );
      } else {
        content = ListView.builder(
          controller: _transcriptScroll,
          padding: const EdgeInsets.fromLTRB(
            Gap.edge,
            Gap.edge,
            Gap.edge,
            Gap.item * 4,
          ),
          itemCount: segments.length,
          // Ключом служит сам сегмент: время начала у двух соседних
          // фрагментов совпадает (VAD режет по паузам и выдаёт их
          // с одной меткой), и Flutter падал на одинаковых ключах.
          itemBuilder: (context, i) => SegmentRow(
            key: ObjectKey(segments[i]),
            segment: segments[i],
            showTimestamp: s.timestamps,
            highlight: _query.trim(),
            onCopied: () => _send(StatusReported(l10n.statusSegmentCopied)),
            onReplacementUndo: (index) =>
                _send(CommandReplacementUndone(job, segments[i], index)),
          ),
        );
      }
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _send(FilesAdded(details.files.map((f) => f.path)));
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              duration: Motion.dur(context, Motion.toss),
              curve: Motion.curve(context, Motion.tossCurve),
              opacity: _dragging ? 0.0 : 1.0,
              child: content,
            ),
          ),
          Positioned.fill(
            child: DropVeil(
              active: _dragging,
              title: l10n.dropVeilHint,
              subtitle: l10n.subtitleDropAudioHere,
            ),
          ),
        ],
      ),
    );
  }

  /// Правая половина строки состояния: чем эта расшифровка вообще является.
  String? _stats(QueueState s) {
    final job = s.lead;
    if (job == null || !job.done) return null;
    final segs = job.segments;
    if (segs.isEmpty) return null;
    final words = wordCount(segs.map((s) => s.text).join(' '));
    final parts = [
      if (job.transcript != null) segmentsLabel(segs.length),
      wordsLabel(words),
      humanDuration(segs.last.to),
      if (job.took != null)
        l10n.statsTook(humanDuration(job.took!.inMilliseconds)),
    ];
    return parts.join(' · ');
  }

  Widget _statusBar(QueueState s) {
    final job = s.lead;
    final busy = s.running && (job?.active ?? false);
    final eta = busy ? job!.eta : null;
    final stats = busy ? null : _stats(s);

    final bar = Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: Gap.item),
      decoration: BoxDecoration(
        color: Surface.chrome(context),
        border: Border(top: BorderSide(color: Surface.hairline(context))),
      ),
      child: Row(
        children: [
          if (busy) ...[
            SizedBox(
              width: IconSize.button,
              height: IconSize.button,
              child: ProgressCircle(value: (job!.progress * 100).clamp(0, 100)),
            ),
            const SizedBox(width: Gap.inner),
          ],
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.dur(context, Motion.quick),
              child: Text(
                s.status,
                key: ValueKey(s.status),
                style: Type.caption.copyWith(
                  color: Surface.secondaryText(context),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Длинный ход загрузки обрезается, но не склеивается со
          // статистикой вроде «141 МБ33 фрагмента».
          const SizedBox(width: Gap.item),
          if (eta != null && eta.inSeconds > 3)
            Padding(
              padding: const EdgeInsets.only(right: Gap.item),
              child: Text(
                l10n.statusRemainingTime(humanDuration(eta.inMilliseconds)),
                style: Type.caption.copyWith(
                  color: Surface.secondaryText(context),
                ),
              ),
            ),
          if (stats != null)
            Padding(
              padding: const EdgeInsets.only(right: Gap.item),
              child: Text(
                stats,
                style: Type.caption.copyWith(
                  color: Surface.secondaryText(context),
                ),
              ),
            ),
          ModelChip(
            label: _modelUseLabel(s),
            detail: _modelUseDetail(s),
            busy: s.transcribing || s.dictation == DictationStatus.busy,
            resting: s.dictation == DictationStatus.resting,
            waiting: s.waitingForModel,
          ),
        ],
      ),
    );
    if (!os.hasWindowMaterial) return bar;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: bar,
      ),
    );
  }

  // ── инспектор ─────────────────────────────────────────────────────────────

  /// Кнопка с пустого экрана: сами модели живут на своей вкладке
  /// в настройках, там же их и качают.
  Widget _modelDownload() => PushButton(
    controlSize: ControlSize.large,
    onPressed: () => _openSettings('models'),
    child: Text(l10n.buttonDownloadModelEllipsis),
  );

  /// В инспекторе — только то, что осмысленно менять от записи к записи:
  /// чем, на каком языке и как разбирать именно эту запись. Всё, что для
  /// всех записей одно (куда сохранять текст, метки времени, ожидание
  /// занятой модели), живёт на вкладке «Расшифровщик» в окне настроек,
  /// а диктовка — на своей. Инспектор целиком принадлежит расшифровщику,
  /// и ни одна настройка диктовки сюда не попадает.
  Widget _inspector(QueueState s, ScrollController controller) {
    final o = s.shown;
    final own = s.lead?.overrides;
    final selectedEngine = engineForModel(o.model);
    final selectedEngineName = engineTechnicalName(selectedEngine);
    return ListView(
      controller: controller,
      // Сверху отступа нет: колонка и так начинается под панелью
      // инструментов, отодвинутая на её высоту. Свои восемь точек
      // поверх этого читались лишней пустотой над первой же строкой.
      padding: const EdgeInsets.fromLTRB(
        Gap.edgeNarrow,
        0,
        Gap.edgeNarrow,
        Gap.section,
      ),
      children: [
        ScopeBanner(
          selection: s.selected.length,
          name: s.lead?.name,
          changed: own == null ? const [] : own.diffAgainst(s.defaults),
          onReset: own == null ? null : _sendResetOverrides,
          onMakeDefault: own == null ? null : _sendMakeDefault,
        ),
        // Беда важнее настроек: она стоит первой, до модели и языка.
        // Здесь же единственное место, где длинную ошибку видно целиком —
        // в подпись под именем записи влезает только начало.
        if (s.lead?.error case final err?) ...[
          SectionTitle(l10n.sectionEngineError),
          EngineErrorBox(text: err),
          const SizedBox(height: Gap.inner),
          Wrap(
            spacing: Gap.control,
            runSpacing: Gap.tight,
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: () => _copyError(s.lead!),
                child: Text(l10n.menuCopyErrorText),
              ),
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: () => Log.openLogsFolder(),
                child: Text(l10n.menuOpenLogsFolder),
              ),
            ],
          ),
          Hint(l10n.hintEngineError),
        ],
        SectionTitle(l10n.sectionTranscriptionModel),
        ModelField(
          installed: s.models,
          value: o.model,
          onChosen: (v) => _send(OptionsEdited((x) => x.copyWith(model: v))),
          onDownload: _sendDownload,
        ),
        if (s.downloadProgress != null) ...[
          const SizedBox(height: Gap.inner),
          ModelDownload(
            title: s.download?.title ?? l10n.genericModelTitle,
            progress: s.downloadProgress!,
            percent: s.downloadPercent,
            onCancel: () => _send(const DownloadCancelled()),
          ),
        ],
        const SizedBox(height: Gap.inner),
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: _pickModel,
          child: Text(l10n.buttonPickModelFile),
        ),
        Hint(l10n.hintDictationSharesModel),
        SectionTitle(l10n.sectionSpeechLanguage),
        MacosPopupButton<String>(
          value: o.lang,
          items: [
            for (final l in languages)
              MacosPopupMenuItem(value: l, child: Text(languageName(l))),
          ],
          onChanged: (v) =>
              _send(OptionsEdited((x) => x.copyWith(lang: v ?? 'auto'))),
        ),
        Hint(l10n.hintMixedLanguageManual),
        SectionTitle(l10n.sectionPunctuation),
        Check(
          l10n.checkPunctuate,
          o.punctuate,
          (v) => _send(OptionsEdited((x) => x.copyWith(punctuate: v))),
        ),
        Hint(l10n.hintPunctuateOff, under: true),
        SectionTitle(l10n.sectionSegmentSplit),
        MacosPopupButton<int>(
          value: o.maxLen,
          items: [
            MacosPopupMenuItem(
              value: 0,
              child: Text(l10n.optionModelDiscretion),
            ),
            MacosPopupMenuItem(
              value: 32,
              child: Text(l10n.optionUpToChars(32)),
            ),
            MacosPopupMenuItem(
              value: 42,
              child: Text(l10n.optionUpTo42Subtitles),
            ),
            MacosPopupMenuItem(
              value: 64,
              child: Text(l10n.optionUpToChars(64)),
            ),
            MacosPopupMenuItem(
              value: 100,
              child: Text(l10n.optionUpToChars(100)),
            ),
          ],
          onChanged: (v) =>
              _send(OptionsEdited((x) => x.copyWith(maxLen: v ?? 0))),
        ),
        const SizedBox(height: Gap.item),
        Check(l10n.checkSplitByPauses, o.vad, (v) {
          if (v && o.vadModel.isEmpty) {
            _sendEnableVad();
          } else {
            _send(OptionsEdited((x) => x.copyWith(vad: v)));
          }
        }),
        if (o.vad)
          Padding(
            padding: const EdgeInsets.only(top: Gap.hint),
            child: Text(
              o.vadModel.isEmpty
                  ? l10n.hintNeedVadFile
                  : os.basename(o.vadModel),
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
        SectionTitle(l10n.fieldSpeed),
        MacosPopupButton<int>(
          value: o.threads,
          items: [
            for (var t = 2; t <= Platform.numberOfProcessors; t += 2)
              MacosPopupMenuItem(value: t, child: Text(l10n.threadsCount(t))),
          ],
          onChanged: (v) =>
              _send(OptionsEdited((x) => x.copyWith(threads: v ?? o.threads))),
        ),
        Hint(l10n.hintThreads),
        ModelPromptSection(
          prompt: promptWithVocabulary('', s.vocabulary),
          vocabularyCount: s.vocabulary.length,
          onOpenVocabularySettings: () => _openSettings('vocabulary'),
          onAddPromptWord: (word) =>
              _send(VocabularyReplacementAdded(phrase: word)),
          onAddReplacement:
              ({
                required String phrase,
                required String replacement,
                bool removeFromPrompt = false,
              }) => _send(
                VocabularyReplacementAdded(
                  phrase: phrase,
                  replacement: replacement,
                  removeFromPrompt: removeFromPrompt,
                ),
              ),
        ),

        // Остальное — куда сохранять текст, диктовка, склад моделей,
        // поведение приложения — живёт в своём окне. Дорога туда теперь
        // закреплена в правом верхнем углу шапки панели: до неё не нужно
        // прокручивать весь инспектор.
        const SizedBox(height: Gap.section),
        Text(
          // Чей движок работает — видно сразу. На системном мы за поведение
          // не отвечаем: в старых сборках нет и половины наших флагов.
          findRecognitionEngine(selectedEngine) == null
              ? l10n.statusRecognizerNotFound(selectedEngineName)
              : recognitionEngineIsOurs(selectedEngine)
              ? l10n.statusRecognizerOurs(selectedEngineName)
              : l10n.statusRecognizerSystem(selectedEngineName),
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
        ),
      ],
    );
  }
}

/// Перетаскивание строки очереди — только левой кнопкой.
///
/// `ReorderableDragStartListener` из Flutter начинает перетаскивание с
/// любой кнопки мыши: он вешает `Listener.onPointerDown` и отдаёт событие
/// распознавателю без разбора. Правый щелчок по строке от этого попадал
/// сразу в двоих — в наше меню и в перетаскивание, — и стоило курсору
/// сдвинуться на пиксель, как перетаскивание объявляло себя победителем,
/// а меню не появлялось вовсе. Пиксель этот на трекпаде неизбежен: щелчок
/// двумя пальцами почти всегда чуть ведёт указатель, поэтому на трекпаде
/// контекстное меню очереди не открывалось почти никогда, а на мыши
/// открывалось всегда — и выглядело это как «пункты меню не работают».
///
/// Лечится в одном месте: распознаватель перетаскивания берёт только
/// первичную кнопку. Правому щелчку тогда никто не мешает.
class _QueueDragListener extends ReorderableDragStartListener {
  const _QueueDragListener({
    super.key,
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      ImmediateMultiDragGestureRecognizer(
        debugOwner: this,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
      );
}

// ── элементы ────────────────────────────────────────────────────────────────
