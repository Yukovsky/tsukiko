import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/app_locale.dart';
import '../../core/library.dart';
import '../../core/logger.dart';
import '../../core/models.dart';
import '../../core/recognition.dart';
import '../../core/skill_install.dart';
import '../../core/transcript.dart';
import '../../core/whisper_server.dart' show Hotkey, PhraseCompletionMode;
import '../../design/design.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/bridge.dart';
import '../../platform/os.dart';
import 'settings_cubit.dart';
import 'widgets/model_row.dart';
import 'widgets/vocabulary_item_row.dart';
import 'widgets/voice_calibration_dialog.dart';
import 'settings_state.dart';
import '../../core/labels.dart';

/// Окно настроек: своё окно с вкладками, как у всех приложений системы.
///
/// Живёт на третьем движке Flutter — том, что создаётся при первом
/// открытии окна. Иначе никак: движок отдаёт один вид одному окну,
/// а главное окно и панель у строки меню свои виды уже заняли. Настройки —
/// не главное окно расшифровщика: диктовка настраивается и тогда, когда
/// очереди нет вовсе, а без значка приложения главного окна может не быть
/// на экране.
///
/// Состоянием владеет [SettingsCubit]; здесь только то, что рисуется.
void runSettings() {
  Log.info(
    'App',
    'runSettings started on ${os.platformId} (${Platform.operatingSystemVersion}), Tsukiko $appVersion',
  );
  refreshLocale();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SettingsApp());
}

/// Вкладки названы по потребителю, а не по виду настройки.
List<({String id, String label, IconData icon})> _settingsTabs(
  AppLocalizations l10n,
) => [
  (
    id: 'transcriber',
    label: l10n.settingsTabTranscription,
    icon: CupertinoIcons.doc_text,
  ),
  (id: 'dictation', label: l10n.settingsTabDictation, icon: CupertinoIcons.mic),
  (
    id: 'vocabulary',
    label: l10n.settingsTabVocabulary,
    icon: CupertinoIcons.book,
  ),
  (id: 'models', label: l10n.settingsTabModels, icon: CupertinoIcons.cube_box),
  (id: 'app', label: l10n.settingsTabApp, icon: CupertinoIcons.gear),
];

class SettingsApp extends StatelessWidget {
  const SettingsApp({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SettingsCubit(NativeBridge()),
    child: ValueListenableBuilder<Locale?>(
      valueListenable: appLocale,
      builder: (context, locale, _) => MacosApp(
        locale: locale,
        // Локализованный заголовок окна недоступен здесь: builder ниже
        // ещё не построен, а MacosApp.title читается до первого кадра.
        // Заголовок панели инструментов настоящий, локализованный —
        // системная рамка окна этот берёт только для VoiceOver и Dock.
        title: currentL10n().settingsWindowTitle,
        theme: MacosThemeData.light(),
        darkTheme: MacosThemeData.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsBody(),
      ),
    ),
  );
}

class SettingsBody extends StatefulWidget {
  const SettingsBody({super.key});

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody>
    with WidgetsBindingObserver {
  /// Поле ввода подсказки для совместимости.
  final _promptCtrl = TextEditingController();
  final _wakeWordCtrl = TextEditingController();
  final _closeWordCtrl = TextEditingController();
  final _modelsScroll = ScrollController();
  String _promptShown = '';
  String _wakeWordShown = '';
  String _closeWordShown = '';

  final _vocabSearchCtrl = TextEditingController();
  final _newPhraseCtrl = TextEditingController();
  final _newReplacementCtrl = TextEditingController();
  final _newPhraseFocus = FocusNode();
  int _vocabFilter = 0; // 0: All, 1: Hints, 2: Replacements
  String _vocabQuery = '';
  bool _showDeletedNotice = false;
  Timer? _deletedNoticeTimer;

  /// Ключ API только что скопировали. Живёт до следующей перерисовки
  /// настроек и в кубите ему делать нечего: это не настройка, а ответ
  /// на нажатие кнопки.
  bool _keyCopied = false;
  bool _diagnosticRecording = false;
  bool _diagnosticBusy = false;
  String? _diagnosticPath;
  String? _diagnosticError;
  Timer? _diagnosticStatusTimer;

  SettingsCubit get _cubit => context.read<SettingsCubit>();
  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Первое состояние приходит мимо listener'а: BlocConsumer зовёт его
    // только на переменах. Без этой строки поле подсказки в только что
    // открытом окне стояло пустым, хотя подсказка была на месте.
    _syncPromptField(_cubit.state.prompt);
    _syncWakeWordField(_cubit.state.wakeWord);
    _syncCloseWordField(_cubit.state.closeWord);
    // Первый вопрос о разрешении задаём сразу: окно только что открыли.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncVisibility();
      unawaited(_refreshDiagnostics());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisibility();

  void _syncVisibility() => _cubit.setVisible(
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _promptCtrl.dispose();
    _wakeWordCtrl.dispose();
    _closeWordCtrl.dispose();
    _modelsScroll.dispose();
    _vocabSearchCtrl.dispose();
    _newPhraseCtrl.dispose();
    _newReplacementCtrl.dispose();
    _newPhraseFocus.dispose();
    _deletedNoticeTimer?.cancel();
    _diagnosticStatusTimer?.cancel();
    super.dispose();
  }

  void _triggerDeletedNotice() {
    _deletedNoticeTimer?.cancel();
    setState(() => _showDeletedNotice = true);
    _deletedNoticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showDeletedNotice = false);
    });
  }

  Future<void> _refreshDiagnostics() async {
    try {
      final result = await _cubit.bridge.wakeDiagnostics('status');
      if (!mounted) return;
      setState(() {
        _diagnosticRecording = result['recording'] == true;
        _diagnosticPath = result['path'] as String?;
      });
      _syncDiagnosticTimer();
    } catch (_) {}
  }

  void _syncDiagnosticTimer() {
    _diagnosticStatusTimer?.cancel();
    if (_diagnosticRecording) {
      _diagnosticStatusTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_refreshDiagnostics()),
      );
    }
  }

  Future<void> _toggleDiagnostics(bool enabled) async {
    if (_diagnosticBusy) return;
    if (enabled && !_cubit.state.wakeWordEnabled) {
      setState(() => _diagnosticError = l10n.wakeDiagnosticsEnableWakeFirst);
      return;
    }
    setState(() {
      _diagnosticBusy = true;
      _diagnosticError = null;
    });
    try {
      final result = await _cubit.bridge.wakeDiagnostics(
        enabled ? 'start' : 'stop',
      );
      if (!mounted) return;
      setState(() {
        _diagnosticRecording = result['recording'] == true;
        _diagnosticPath = result['path'] as String?;
        _diagnosticError = switch (result['error']) {
          'profile' => l10n.wakeDiagnosticsRecalibrateFirst,
          'wake_disabled' => l10n.wakeDiagnosticsEnableWakeFirst,
          null => null,
          _ => l10n.wakeDiagnosticsStartFailed,
        };
      });
      _syncDiagnosticTimer();
    } catch (_) {
      if (mounted) {
        setState(() => _diagnosticError = l10n.wakeDiagnosticsStartFailed);
      }
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _markDiagnostics(String word) async {
    try {
      await _cubit.bridge.wakeDiagnostics('mark', word);
    } catch (_) {
      if (mounted) {
        setState(() => _diagnosticError = l10n.wakeDiagnosticsMarkFailed);
      }
    }
  }

  /// Поле подсказки следует за настройкой, но не мешает набору.
  void _syncPromptField(String text) {
    if (text == _promptShown) return;
    _promptShown = text;
    if (_promptCtrl.text == text) return;
    _promptCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _syncWakeWordField(String text) {
    if (text == _wakeWordShown) return;
    _wakeWordShown = text;
    if (_wakeWordCtrl.text == text) return;
    _wakeWordCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _syncCloseWordField(String text) {
    if (text == _closeWordShown) return;
    _closeWordShown = text;
    if (_closeWordCtrl.text == text) return;
    _closeWordCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Каталог моделей длиннее окна, а ход загрузки стоит над ним. После
  /// нажатия «Скачать» возле нижней модели кнопки блокировались на месте,
  /// и начавшаяся выше загрузка оставалась за краем экрана. Дожидаемся,
  /// пока список переложится, и мягко возвращаем его к верхнему блоку,
  /// где индикатор уже виден. Искать сам виджет по ключу нельзя: ленивый
  /// список не строит его, пока пользователь далеко внизу. [Motion]
  /// учитывает системное «уменьшение движения».
  void _revealModelDownload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_modelsScroll.hasClients) return;
      _modelsScroll.animateTo(
        _modelsScroll.position.minScrollExtent,
        duration: Motion.dur(context, Motion.settle),
        curve: Motion.curve(context, Motion.settleCurve),
      );
    });
  }

  Future<void> _pickModel() async {
    try {
      final f = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'GGML / GGUF', extensions: ['bin', 'gguf']),
        ],
      );
      if (f != null && f.path.trim().isNotEmpty) {
        _cubit.pickModel(f.path.trim());
      }
    } catch (e, stack) {
      Log.warn('Settings', 'Failed to pick model file: $e', e, stack);
    }
  }

  Future<void> _pickLibrary(SettingsState s) async {
    try {
      final initial = Directory(s.libraryPath).existsSync()
          ? s.libraryPath
          : (Directory(os.documentsDir).existsSync() ? os.documentsDir : null);
      final dir = await getDirectoryPath(
        confirmButtonText: l10n.buttonChoose,
        initialDirectory: initial,
      );
      if (dir != null && dir.trim().isNotEmpty) {
        _cubit.setLibraryPath(dir.trim());
      }
    } catch (e, stack) {
      Log.warn('Settings', 'Failed to pick library directory: $e', e, stack);
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<SettingsCubit, SettingsState>(
        listenWhen: (was, now) =>
            was.prompt != now.prompt ||
            was.wakeWord != now.wakeWord ||
            was.closeWord != now.closeWord ||
            (!was.downloading && now.downloading),
        listener: (context, s) {
          _syncPromptField(s.prompt);
          _syncWakeWordField(s.wakeWord);
          _syncCloseWordField(s.closeWord);
          if (s.downloading) _revealModelDownload();
        },
        builder: (context, s) => Container(
          color: MacosTheme.of(context).canvasColor,
          child: Column(
            children: [
              _tabs(context, s),
              Expanded(
                child: ListView(
                  controller: s.tab == 'models' ? _modelsScroll : null,
                  // У каждой вкладки своё место прокрутки. Без ключа Flutter
                  // переносил позицию из длинного каталога моделей в другую
                  // вкладку, и она открывалась посередине или в пустоте.
                  key: ValueKey(s.tab),
                  // Поля слева и справа одинаковые и одни на все вкладки.
                  padding: const EdgeInsets.fromLTRB(
                    Gap.edge,
                    Gap.inner,
                    Gap.edge,
                    Gap.section,
                  ),
                  children: [
                    // Жалоба стоит над вкладкой, а не внутри неё: назначить
                    // занятое сочетание можно на «Диктовке», выбрать не тот
                    // файл — там же, а показывалось это всё на «Моделях»,
                    // то есть не показывалось никому.
                    if (s.problem != null) _problem(s.problem!),
                    ...switch (s.tab) {
                      'dictation' => _dictationTab(s),
                      'vocabulary' => _vocabularyTab(s),
                      'models' => _modelsTab(s),
                      'app' => _appTab(s),
                      _ => _transcriberTab(s),
                    },
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// Что пошло не так с последним действием: занятое сочетание, чужой
  /// файл вместо модели, отказ Корзины.
  Widget _problem(String text) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.inner),
    child: Text(
      text,
      style: Type.caption.copyWith(
        color: MacosColors.systemOrangeColor,
        height: 1.4,
      ),
    ),
  );

  // ── вкладки ───────────────────────────────────────────────────────────────

  /// Вкладки стоят в полосе на месте панели инструментов. Полоса высокая
  /// и вкладки в ней по центру: слева живут кнопки окна, и наезжать на них
  /// нельзя.
  Widget _tabs(BuildContext context, SettingsState s) => Container(
    height: 58,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Surface.hairline(context))),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in _settingsTabs(l10n))
              _TabButton(
                label: t.label,
                icon: t.icon,
                selected: s.tab == t.id,
                onTap: () => _cubit.setTab(t.id),
              ),
          ],
        );
        // Если окно достаточно широкое (стандартный размер 580/680),
        // центрируем вкладки без дополнительного Scrollable.
        // При сильном сужении окна даём горизонтальную прокрутку,
        // чтобы ни одна вкладка не обрезалась и не терялась.
        if (constraints.maxWidth >= 530) {
          return row;
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.inner),
          child: row,
        );
      },
    ),
  );

  // ── диктовка ──────────────────────────────────────────────────────────────

  List<Widget> _dictationTab(SettingsState s) => [
    SectionTitle(l10n.sectionHotkeys),
    HotkeyRow(
      label: l10n.hotkeyHold,
      keys: s.hold.label,
      onTap: () => _reassignHotkey('hold'),
    ),
    HotkeyRow(
      label: l10n.hotkeyToggle,
      keys: s.toggle.label,
      onTap: () => _reassignHotkey('toggle'),
    ),
    // Третье действие — и единственное, которое можно не назначать
    // вовсе. «Остановить» и «передумал» это разные намерения, а у
    // клавиш второго не было: бросить начатое можно было только мышью,
    // по крестику на плавающей панели, которую человек мог и выключить.
    HotkeyRow(
      label: l10n.hotkeyCancel,
      keys: s.cancel.label,
      onTap: () => _reassignHotkey('cancel'),
      // Снимать нечего — и крестика нет: пустая строка не должна
      // выбиваться из столбика ради кнопки, которой не на что нажать.
      onClear: s.cancel.empty ? null : _cubit.clearCancelHotkey,
    ),
    // Пара, где одно сочетание входит в другое, ведёт себя непонятно,
    // а не ломается: запись начинается по дороге ко второму. Молчать
    // об этом нельзя — человеку неоткуда догадаться.
    if (s.shadowingHotkey case final early?)
      _problem(
        l10n.hotkeyShadowProblem(
          early.label,
          (s.shadowedHotkey ?? early).label,
        ),
      ),
    Hint(l10n.hintHotkeyCancel),
    Hint(l10n.hintHotkeyCapture),
    SectionTitle(l10n.sectionDictationRecognition),
    Hint(l10n.hintDictationOwnSettings),
    const SizedBox(height: Gap.item),
    _Field(
      l10n.fieldDictationModel,
      ModelField(
        installed: s.usable,
        value: s.dictationModel,
        fallback: l10n.fallbackSameAsTranscription,
        onChosen: (v) => _cubit.setDictationModel(v),
        onDownload: _cubit.downloadForDictation,
        downloadEnabled: !s.downloading,
      ),
    ),
    Hint(l10n.hintDictationModelFallback),
    const SizedBox(height: Gap.inner),
    // Кнопка стоит здесь, а не на вкладке «Модели»: она не пополняет
    // список, а выбирает модель диктовки — раньше из общего склада
    // это делалось молча, и понять, кому достался файл, было нельзя.
    PushButton(
      controlSize: ControlSize.regular,
      secondary: true,
      onPressed: _pickModel,
      child: Text(l10n.buttonPickModelFile),
    ),
    const SizedBox(height: Gap.item),
    _Field(
      l10n.fieldSpeed,
      MacosPopupButton<int>(
        value: s.threads,
        items: [
          for (final t in threadChoices(s.threads))
            MacosPopupMenuItem(value: t, child: Text(l10n.threadsCount(t))),
        ],
        onChanged: (v) => _cubit.setThreads(v ?? s.threads),
      ),
    ),
    Hint(l10n.hintThreads),
    const SizedBox(height: Gap.item),
    Check(l10n.checkPunctuate, s.punctuate, _cubit.setPunctuate),
    SectionTitle(l10n.sectionModelInMemory),
    _Field(
      l10n.fieldKeepModel,
      MacosPopupButton<int>(
        value: s.idleSeconds,
        items: [
          MacosPopupMenuItem(value: 30, child: Text(l10n.duration30s)),
          MacosPopupMenuItem(value: 60, child: Text(l10n.duration1m)),
          MacosPopupMenuItem(value: 180, child: Text(l10n.duration3m)),
          MacosPopupMenuItem(value: 600, child: Text(l10n.duration10m)),
          MacosPopupMenuItem(value: 3600, child: Text(l10n.duration1h)),
        ],
        onChanged: (v) => _cubit.setIdleSeconds(v ?? 180),
      ),
    ),
    // Размер берём у той модели, которая выбрана, а не пишем числом
    // в тексте: раньше здесь стояло «полтора гигабайта» — верно ровно
    // для Large v3 Turbo и неправда для всех остальных.
    Hint('${l10n.hintMemoryCostPrefix} ${_memoryCost(s)}'),
    SectionTitle(l10n.sectionAfterDictation),
    Check(l10n.checkInsertText, s.insert, _cubit.setInsert),
    Hint(l10n.hintInsertOff, under: true),
    const SizedBox(height: Gap.item),
    SectionTitle(l10n.indicatorTitle),
    Hint(l10n.indicatorEditorHint),
    const SizedBox(height: Gap.inner),
    PushButton(
      controlSize: ControlSize.regular,
      secondary: true,
      onPressed: () => _cubit.bridge.configureHud({
        'title': l10n.indicatorTitle,
        'hint': l10n.hudLayoutHint,
        'drag': l10n.hudDrag,
        'scale': l10n.hudScale,
        'reset': l10n.hudReset,
        'cancel': l10n.hudCancel,
        'save': l10n.hudSave,
        'mode': s.indicatorMode.name,
        'panel': l10n.indicatorPanel,
        'status': l10n.indicatorStatus,
        'timer': l10n.indicatorTimer,
        'off': l10n.indicatorOff,
        'statusHint': l10n.indicatorStatusHint,
        'offHint': l10n.indicatorOffHint,
        'preview': l10n.indicatorPreview,
        'previous': l10n.indicatorPrevious,
        'next': l10n.indicatorNext,
      }),
      child: Text(l10n.indicatorOpenEditor),
    ),
    SectionTitle(l10n.sectionWakeWord),
    Hint(l10n.hintWakeWordSection),
    const SizedBox(height: Gap.inner),
    Check(l10n.checkWakeWordEnabled, s.wakeWordEnabled, (enabled) async {
      if (enabled && !s.wakeProfileExists) {
        final ok = await _openWakeCalibration(s.wakeWord);
        if (ok != true) return;
      }
      _cubit.setWakeWordEnabled(enabled);
    }),
    if (s.wakeWordEnabled) ...[
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldWakeWord,
        AppTextField(
          controller: _wakeWordCtrl,
          placeholder: l10n.placeholderWakeWord,
          onChanged: _cubit.setWakeWord,
        ),
      ),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldCloseWord,
        AppTextField(
          controller: _closeWordCtrl,
          placeholder: l10n.placeholderCloseWord,
          onChanged: _cubit.setCloseWord,
        ),
      ),
      Hint(l10n.hintCloseWord, under: true),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldCompletionMode,
        MacosPopupButton<PhraseCompletionMode>(
          value: s.completionMode,
          items: [
            MacosPopupMenuItem(
              value: PhraseCompletionMode.hybrid,
              child: Text(l10n.completionModeHybrid),
            ),
            MacosPopupMenuItem(
              value: PhraseCompletionMode.closeWordOnly,
              child: Text(l10n.completionModeCloseWordOnly),
            ),
            MacosPopupMenuItem(
              value: PhraseCompletionMode.silenceOnly,
              child: Text(l10n.completionModeSilenceOnly),
            ),
          ],
          onChanged: (mode) {
            if (mode != null) _cubit.setCompletionMode(mode);
          },
        ),
      ),
      const SizedBox(height: Gap.item),
      SectionTitle(l10n.sectionVoiceCalibration),
      Hint(l10n.hintVoiceCalibration),
      const SizedBox(height: Gap.inner),
      _buildCalibrationCard(
        context: context,
        title: l10n.calibrationWakeSectionTitle,
        word: s.wakeWord,
        isCalibrated: s.wakeProfileExists,
        isWordEmpty: false,
        onCalibrate: () => _openWakeCalibration(s.wakeWord),
        onDelete: () => _cubit.deleteWakeProfile(),
        l10n: l10n,
      ),
      const SizedBox(height: Gap.inner),
      _buildCalibrationCard(
        context: context,
        title: l10n.calibrationCloseSectionTitle,
        word: s.closeWord,
        isCalibrated: s.closeProfileExists,
        isWordEmpty: s.closeWord.trim().isEmpty,
        onCalibrate: () => _openCloseCalibration(s.closeWord),
        onDelete: () => _cubit.deleteCloseProfile(),
        l10n: l10n,
      ),
    ],
    SectionTitle(l10n.wakeDiagnosticsTitle),
    Check(l10n.wakeDiagnosticsRecord, _diagnosticRecording, _toggleDiagnostics),
    Hint(l10n.wakeDiagnosticsHint, under: true),
    if (_diagnosticRecording) ...[
      const SizedBox(height: Gap.item),
      Row(
        children: [
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => _markDiagnostics('wake'),
            child: Text(l10n.wakeDiagnosticsMarkWake),
          ),
          const SizedBox(width: Gap.control),
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => _markDiagnostics('close'),
            child: Text(l10n.wakeDiagnosticsMarkClose),
          ),
          const SizedBox(width: Gap.control),
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => _markDiagnostics('other'),
            child: Text(l10n.wakeDiagnosticsMarkOther),
          ),
        ],
      ),
      Hint(l10n.wakeDiagnosticsMarkHint, under: true),
    ],
    if (_diagnosticError != null)
      Text(
        _diagnosticError!,
        style: Type.caption.copyWith(color: const Color(0xFFFF3B30)),
      ),
    if (_diagnosticPath != null) ...[
      const SizedBox(height: Gap.item),
      Row(
        children: [
          Expanded(
            child: Text(
              _diagnosticPath!.replaceFirst(home, '~'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
          PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => Process.run('open', [_diagnosticPath!]),
            child: Text(l10n.wakeDiagnosticsOpenFolder),
          ),
        ],
      ),
    ],
  ];

  Widget _buildCalibrationCard({
    required BuildContext context,
    required String title,
    required String word,
    required bool isCalibrated,
    required bool isWordEmpty,
    required VoidCallback onCalibrate,
    required VoidCallback? onDelete,
    required AppLocalizations l10n,
  }) {
    final isDark = MacosTheme.brightnessOf(context) == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF9F9FB);
    final borderColor = isDark
        ? const Color(0xFF333333)
        : const Color(0xFFE5E5EA);
    final statusColor = isWordEmpty
        ? const Color(0xFF8E8E93)
        : (isCalibrated ? const Color(0xFF34C759) : const Color(0xFFFF9500));
    final statusIcon = isWordEmpty
        ? CupertinoIcons.minus_circle
        : (isCalibrated
              ? CupertinoIcons.checkmark_seal_fill
              : CupertinoIcons.exclamationmark_circle);
    final statusText = isWordEmpty
        ? l10n.voiceProfileCloseEmpty
        : (isCalibrated
              ? l10n.voiceProfileStatusCalibrated(4)
              : l10n.voiceProfileStatusNotCalibrated);

    return Container(
      padding: const EdgeInsets.all(Gap.item),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              MacosIcon(statusIcon, color: statusColor, size: 20),
              const SizedBox(width: Gap.item),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: Type.control.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (word.isNotEmpty) ...[
                          const SizedBox(width: Gap.hint),
                          Text(
                            '«$word»',
                            style: Type.control.copyWith(
                              color: MacosTheme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      style: Type.caption.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.item),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: isWordEmpty ? null : onCalibrate,
                child: Text(
                  isCalibrated
                      ? l10n.buttonRecalibrateVoice
                      : l10n.buttonCalibrateVoice,
                ),
              ),
              if (isCalibrated && onDelete != null) ...[
                const SizedBox(width: Gap.inner),
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: onDelete,
                  child: Text(l10n.buttonDeleteVoiceProfile),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<bool?> _openWakeCalibration(String wakeWord) async {
    await _cubit.bridge.setCalibrationActive(true);
    try {
      if (!mounted) return null;
      final result = await VoiceCalibrationSheet.showWake(
        context,
        wakeWord: wakeWord.isNotEmpty ? wakeWord : 'Джеф',
        bridge: _cubit.bridge,
        onProfileCreated: _cubit.refreshSpeakerProfile,
      );
      if (result == true) {
        _cubit.refreshSpeakerProfile();
      }
      return result;
    } finally {
      await _cubit.bridge.setCalibrationActive(false);
    }
  }

  Future<bool?> _openCloseCalibration(String closeWord) async {
    await _cubit.bridge.setCalibrationActive(true);
    try {
      if (!mounted) return null;
      final result = await VoiceCalibrationSheet.showClose(
        context,
        closeWord: closeWord,
        bridge: _cubit.bridge,
        onProfileCreated: _cubit.refreshSpeakerProfile,
      );
      if (result == true) {
        _cubit.refreshSpeakerProfile();
      }
      return result;
    } finally {
      await _cubit.bridge.setCalibrationActive(false);
    }
  }

  Future<void> _reassignHotkey(String id) =>
      _cubit.reassign(id, confirmExclusive: _confirmExclusiveHotkey);

  Future<bool> _confirmExclusiveHotkey(Hotkey hotkey) async {
    if (!mounted) return false;
    var accepted = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.keyboard, size: IconSize.hero),
        title: Text(
          l10n.singleHotkeyTitle(hotkey.label),
          style: Type.emptyTitle,
        ),
        message: Text(
          l10n.singleHotkeyBody,
          textAlign: TextAlign.center,
          style: Type.control,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            accepted = true;
            Navigator.pop(dialogContext);
          },
          child: Text(l10n.buttonAssign),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonCancel),
        ),
      ),
    );
    return accepted;
  }

  // ── словарь ───────────────────────────────────────────────────────────────

  bool get _isDuplicatePhrase {
    final phrase = _newPhraseCtrl.text.trim().toLowerCase();
    if (phrase.isEmpty) return false;
    return _cubit.state.vocabulary.any(
      (i) => i.phrase.trim().toLowerCase() == phrase,
    );
  }

  void _addVocabularyEntry() {
    final phrase = _newPhraseCtrl.text.trim();
    if (phrase.isEmpty) return;
    _cubit.addVocabularyItem(phrase, _newReplacementCtrl.text.trim());
    _newPhraseCtrl.clear();
    _newReplacementCtrl.clear();
    _newPhraseFocus.requestFocus();
    setState(() {});
  }

  Widget _quickAddBar(SettingsState s) {
    final phraseNonEmpty = _newPhraseCtrl.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(Gap.inner),
      decoration: BoxDecoration(
        color: Surface.hover(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Surface.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter):
                  _addVocabularyEntry,
            },
            child: Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _newPhraseCtrl,
                    placeholder: l10n.placeholderVocabularyPhrase,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.inner),
                  child: MacosIcon(
                    CupertinoIcons.arrow_right,
                    size: 11,
                    color: Surface.secondaryText(
                      context,
                    ).withValues(alpha: 0.5),
                  ),
                ),
                Expanded(
                  child: AppTextField(
                    controller: _newReplacementCtrl,
                    placeholder: l10n.placeholderVocabularyReplacement,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: Gap.control),
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: !phraseNonEmpty,
                  onPressed: phraseNonEmpty ? _addVocabularyEntry : null,
                  child: Text(l10n.buttonAddVocabulary),
                ),
              ],
            ),
          ),
          if (_isDuplicatePhrase) ...[
            const SizedBox(height: Gap.hint),
            Row(
              children: [
                const MacosIcon(
                  CupertinoIcons.exclamationmark_triangle_fill,
                  size: IconSize.inline,
                  color: MacosColors.systemOrangeColor,
                ),
                const SizedBox(width: Gap.hint),
                Expanded(
                  child: Text(
                    l10n.warningDuplicatePhrase,
                    style: Type.caption.copyWith(
                      color: MacosColors.systemOrangeColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Gap.hint),
          Hint(l10n.hintVocabularyReplacementOptional),
        ],
      ),
    );
  }

  Widget _emptyVocabularyState(SettingsState s) => Container(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: Gap.edge),
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MacosIcon(
          CupertinoIcons.book,
          size: IconSize.hero,
          color: Surface.secondaryText(context),
        ),
        const SizedBox(height: Gap.item),
        Text(
          l10n.emptyVocabularyTitle,
          style: Type.emptyTitle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Gap.hint),
        Text(
          l10n.emptyVocabularySubtitle,
          style: Type.caption.copyWith(color: Surface.secondaryText(context)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Gap.section),
        Wrap(
          spacing: Gap.inner,
          runSpacing: Gap.inner,
          alignment: WrapAlignment.center,
          children: [
            _SuggestionChip(
              label: '+ юскейс → Use Case',
              onTap: () {
                _cubit.addVocabularyItem('юскейс', 'Use Case');
              },
            ),
            _SuggestionChip(
              label: '+ супервиспер → SuperWhisper',
              onTap: () {
                _cubit.addVocabularyItem('супервиспер', 'SuperWhisper');
              },
            ),
            _SuggestionChip(
              label: '+ TypeScript',
              onTap: () {
                _cubit.addVocabularyItem('TypeScript');
              },
            ),
          ],
        ),
      ],
    ),
  );

  List<Widget> _vocabularyTab(SettingsState s) {
    final query = _vocabQuery.toLowerCase();
    final allItems = s.vocabulary;
    final filtered = allItems.where((item) {
      if (_vocabFilter == 1 && !item.isHintOnly) return false;
      if (_vocabFilter == 2 && !item.isReplacement) return false;
      if (query.isNotEmpty) {
        final inPhrase = item.phrase.toLowerCase().contains(query);
        final inRep = item.replacement.toLowerCase().contains(query);
        if (!inPhrase && !inRep) return false;
      }
      return true;
    }).toList();

    return [
      // 1. Область действия (Apple Inset Grouped Settings Box)
      SectionTitle(l10n.sectionVocabularyAndReplacements),
      Container(
        decoration: BoxDecoration(
          color: Surface.hover(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Surface.hairline(context)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.inner,
          vertical: Gap.tight,
        ),
        child: Column(
          children: [
            Check(
              l10n.checkVocabularyDictation,
              s.vocabularyDictationEnabled,
              _cubit.setVocabularyDictationEnabled,
            ),
            Container(
              height: 1,
              margin: const EdgeInsets.only(left: 28),
              color: Surface.hairline(context),
            ),
            Check(
              l10n.checkVocabularyTranscriber,
              s.vocabularyTranscriberEnabled,
              _cubit.setVocabularyTranscriberEnabled,
            ),
          ],
        ),
      ),
      Hint(l10n.hintVocabularyScope),

      // 2. Добавить в словарь
      SectionTitle(l10n.sectionAddVocabulary),
      _quickAddBar(s),

      // 3. Записи словаря
      SectionTitle('${l10n.sectionVocabularyItems} (${s.vocabulary.length})'),

      if (_showDeletedNotice && _cubit.lastDeletedItem != null) ...[
        Container(
          margin: const EdgeInsets.only(bottom: Gap.inner),
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.inner,
            vertical: Gap.hint,
          ),
          decoration: BoxDecoration(
            color: Surface.pressed(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Surface.hairline(context)),
          ),
          child: Row(
            children: [
              MacosIcon(
                CupertinoIcons.arrow_uturn_left,
                size: IconSize.inline,
                color: Surface.secondaryText(context),
              ),
              const SizedBox(width: Gap.inner),
              Expanded(
                child: Text(
                  l10n.statusVocabularyItemDeleted,
                  style: Type.control,
                ),
              ),
              PushButton(
                controlSize: ControlSize.small,
                secondary: true,
                onPressed: () {
                  _deletedNoticeTimer?.cancel();
                  _cubit.undoDeleteVocabularyItem();
                  setState(() => _showDeletedNotice = false);
                },
                child: Text(l10n.buttonUndo),
              ),
            ],
          ),
        ),
      ],

      // Панель поиска, фильтров и массовых действий
      Row(
        children: [
          Expanded(
            child: MacosSearchField(
              controller: _vocabSearchCtrl,
              placeholder: l10n.placeholderSearchVocabulary,
              placeholderStyle: Surface.placeholder(context),
              onChanged: (v) => setState(() => _vocabQuery = v.trim()),
            ),
          ),
          const SizedBox(width: Gap.control),
          _VocabularyFilterBar(
            selectedFilter: _vocabFilter,
            totalCount: s.vocabulary.length,
            hintsCount: s.vocabulary.where((i) => i.isHintOnly).length,
            replacementsCount: s.vocabulary
                .where((i) => i.isReplacement)
                .length,
            allLabel: l10n.filterAll,
            hintsLabel: l10n.filterHints,
            replacementsLabel: l10n.filterReplacements,
            onSelected: (idx) => setState(() => _vocabFilter = idx),
          ),
          if (s.vocabulary.isNotEmpty) ...[
            const SizedBox(width: Gap.inner),
            MacosTooltip(
              message: l10n.menuVocabularyActions,
              child: MacosPulldownButton(
                icon: CupertinoIcons.ellipsis_circle,
                items: [
                  MacosPulldownMenuItem(
                    title: Text(l10n.actionEnableAllVocabulary),
                    label: l10n.actionEnableAllVocabulary,
                    onTap: () => _cubit.setAllVocabularyEnabled(true),
                  ),
                  MacosPulldownMenuItem(
                    title: Text(l10n.actionDisableAllVocabulary),
                    label: l10n.actionDisableAllVocabulary,
                    onTap: () => _cubit.setAllVocabularyEnabled(false),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: Gap.item),

      // Список в объединённой карточке Inset Grouped Table
      if (s.vocabulary.isEmpty)
        _emptyVocabularyState(s)
      else if (filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.section),
          child: Center(
            child: Text(
              l10n.skillNotFound('—'),
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
        )
      else
        Container(
          decoration: BoxDecoration(
            color: Surface.hover(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Surface.hairline(context)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < filtered.length; i++) ...[
                if (i > 0)
                  Container(
                    height: 1,
                    margin: const EdgeInsets.only(left: 44),
                    color: Surface.hairline(context),
                  ),
                VocabularyItemRow(
                  key: ValueKey(filtered[i].id),
                  item: filtered[i],
                  onToggle: (enabled) {
                    final idx = s.vocabulary.indexOf(filtered[i]);
                    if (idx != -1) _cubit.toggleVocabularyItem(idx, enabled);
                  },
                  onUpdate: (updated) {
                    final idx = s.vocabulary.indexOf(filtered[i]);
                    if (idx != -1) _cubit.updateVocabularyItem(idx, updated);
                  },
                  onDelete: () {
                    final idx = s.vocabulary.indexOf(filtered[i]);
                    if (idx != -1) {
                      _cubit.removeVocabularyItem(idx);
                      _triggerDeletedNotice();
                    }
                  },
                ),
              ],
            ],
          ),
        ),
    ];
  }

  // ── модели ────────────────────────────────────────────────────────────────

  List<Widget> _modelsTab(SettingsState s) {
    return [
      SectionTitle(l10n.sectionActiveModels),
      Hint(l10n.hintModelsOwnership),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldTranscriptionModel,
        ModelField(
          installed: s.usable,
          value: s.transcriberModelSelection,
          fallback: l10n.fallbackSameAsDictation,
          onChosen: _cubit.setQueueModel,
          onDownload: _cubit.downloadForTranscription,
          downloadEnabled: !s.downloading,
        ),
      ),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldDictationModel,
        ModelField(
          installed: s.usable,
          value: s.dictationModel,
          fallback: l10n.fallbackSameAsTranscription,
          onChosen: _cubit.setDictationModel,
          onDownload: _cubit.downloadForDictation,
          downloadEnabled: !s.downloading,
        ),
      ),
      SectionTitle(l10n.sectionModelCatalog),
      Hint(l10n.hintModelCatalog),
      if (s.downloading) ...[
        const SizedBox(height: Gap.item),
        ModelDownload(
          title: s.downloadTitle ?? l10n.genericModelTitle,
          progress: s.downloadProgress!,
          percent: s.downloadPercent,
          onCancel: _cubit.cancelDownload,
        ),
      ],
      for (final engine in RecognitionEngine.values) ...[
        _modelEngineHeading(engine),
        for (final m in modelCatalog.where((m) => m.engine == engine))
          _modelOfferRow(m, installed: haveModel(s.usable, m)),
      ],
      SectionTitle(l10n.sectionInstalled),
      if (s.models.isEmpty)
        Hint(l10n.hintNoModels)
      else
        for (final m in s.models)
          ModelRow(
            name: modelLabel(m.path, [for (final x in s.models) x.path]),
            path: m.path.replaceFirst(home, '~'),
            size: m.sizeLabel,
            problem: m.problem,
            usedBy: s.userOf(m.path),
            onReveal: () => _cubit.revealModel(m.path),
            onDelete: () => _confirmDelete(s, m),
          ),
      // Модель тишины лежит в той же папке, и не сказать о ней — значит
      // оставить человека с файлом, которого нет ни в одном списке.
      if (s.vad != null) ...[
        SectionTitle(l10n.sectionAuxiliary),
        ModelRow(
          name: l10n.vadModelName,
          path: s.vad!.path.replaceFirst(home, '~'),
          size: s.vad!.sizeLabel,
          problem: s.vad!.problem,
          usedBy: null,
          onReveal: () => _cubit.revealModel(s.vad!.path),
          onDelete: () => _confirmDelete(s, s.vad!),
        ),
        Hint(l10n.hintVad),
      ],
      const SizedBox(height: Gap.section),
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.modelsFolderLabel(os.modelsDir.replaceFirst(home, '~')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(
                color: Surface.secondaryText(context),
              ),
            ),
          ),
          const SizedBox(width: Gap.inner),
          PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: _cubit.revealModelsFolder,
            child: Text(l10n.buttonShowInFileManager(os.fileManagerName)),
          ),
        ],
      ),
    ];
  }

  /// Каталог делится по исполняющему движку: размер модели не объясняет,
  /// почему один файл `.bin`, другой `.gguf` и какие функции у них разные.
  Widget _modelEngineHeading(RecognitionEngine engine) => Padding(
    padding: const EdgeInsets.only(top: Gap.item, bottom: Gap.hint),
    child: Text(
      engineTechnicalName(engine).toUpperCase(),
      style: Type.sectionHeader.copyWith(color: Surface.secondaryText(context)),
    ),
  );

  Widget _modelOfferRow(ModelOffer model, {required bool installed}) {
    final muted = Surface.secondaryText(context);
    final capabilities = <({String label, bool warning})>[
      (
        label: switch (model.languages) {
          ModelLanguageScope.multilingual => l10n.modelCapabilityMultilingual,
          ModelLanguageScope.fortyPlus => l10n.modelCapabilityLanguages40Plus,
          ModelLanguageScope.european25 => l10n.modelCapabilityEuropean25,
        },
        warning: false,
      ),
      (
        label: switch (model.focus) {
          ModelFocus.compact => l10n.modelCapabilityCompact,
          ModelFocus.balanced => l10n.modelCapabilityBalanced,
          ModelFocus.fast => l10n.modelCapabilityFast,
          ModelFocus.accurate => l10n.modelCapabilityAccurate,
          ModelFocus.live => l10n.modelCapabilityLive,
        },
        warning: false,
      ),
      (
        label: model.supportsPrompt
            ? l10n.modelCapabilityPrompt
            : l10n.modelCapabilityNoPrompt,
        warning: !model.supportsPrompt,
      ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Gap.control),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Surface.hairline(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${model.title} · ${model.size}', style: Type.fileName),
                const SizedBox(height: Gap.hint),
                Text(
                  model.about,
                  style: Type.caption.copyWith(color: muted, height: 1.35),
                ),
                const SizedBox(height: Gap.inner),
                Wrap(
                  spacing: Gap.hint,
                  runSpacing: Gap.hint,
                  children: [
                    for (final capability in capabilities)
                      _modelCapability(
                        capability.label,
                        warning: capability.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.item),
          if (installed)
            Padding(
              padding: const EdgeInsets.only(top: Gap.hint),
              child: Row(
                children: [
                  const MacosIcon(
                    CupertinoIcons.check_mark_circled_solid,
                    size: IconSize.inline,
                    color: MacosColors.systemGreenColor,
                  ),
                  const SizedBox(width: Gap.hint),
                  Text(l10n.modelAlreadyInstalled, style: Type.caption),
                ],
              ),
            )
          else
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _cubit.state.downloading
                  ? null
                  : () => _cubit.download(model),
              child: Text(l10n.buttonDownload),
            ),
        ],
      ),
    );
  }

  Widget _modelCapability(String label, {required bool warning}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: warning
          ? MacosColors.systemOrangeColor.withValues(alpha: 0.11)
          : Surface.hover(context),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: Type.caption.copyWith(
        fontSize: 10.5,
        color: warning
            ? MacosColors.systemOrangeColor
            : Surface.secondaryText(context),
      ),
    ),
  );

  /// Сколько памяти держит модель, которой работает диктовка. Пока она
  /// не выбрана или файла нет, числа не выдумываем.
  String _memoryCost(SettingsState s) {
    // Именно «в деле», а не «выбрана»: при пустом выборе диктовка держит
    // в памяти модель расшифровщика, и её размер здесь и надо назвать.
    final chosen = s.dictationModelInUse;
    if (chosen.isEmpty) {
      return l10n.memoryCostUnknown;
    }
    final size = s.models
        .where((m) => m.path == chosen)
        .map((m) => m.sizeLabel)
        .firstWhere((label) => label.isNotEmpty, orElse: () => '');
    return size.isEmpty ? l10n.memoryCostGeneric : l10n.memoryCostSized(size);
  }

  /// Удаление спрашивают, а не делают молча: полтора гигабайта, стёртые
  /// по промаху, качать заново. Файл при этом уходит в Корзину, поэтому
  /// вопрос один и без запугивания.
  Future<void> _confirmDelete(SettingsState s, InstalledModel m) async {
    final usedBy = s.userOf(m.path);
    final where = m.ours
        ? l10n.deleteModelToTrash
        : l10n.deleteModelSharedFolder(appName);
    var yes = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.trash, size: IconSize.hero),
        title: Text(l10n.deleteModelTitle(m.name), style: Type.emptyTitle),
        message: Text(
          [
            where,
            if (usedBy != null) l10n.deleteModelUsedBy(usedBy),
            if (m.sizeLabel.isNotEmpty) l10n.deleteModelFrees(m.sizeLabel),
          ].join('\n'),
          textAlign: TextAlign.center,
          style: Type.control,
        ),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            yes = true;
            Navigator.pop(dialogContext);
          },
          child: Text(l10n.buttonRemove),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.buttonCancel),
        ),
      ),
    );
    if (yes) await _cubit.deleteModel(m.path);
  }

  // ── расшифровщик ──────────────────────────────────────────────────────────

  /// Вкладка отвечает на один вопрос: что расшифровщик делает с текстом,
  /// когда запись распознана. Поэтому каждая галка говорит и что делает,
  /// и что будет, если её выключить, — иначе выключать её страшно.
  ///
  /// Как именно распознавать, здесь не спрашивают: модель, язык, пунктуация,
  /// разбивка, скорость и подсказка меняются от записи к записи, и место
  /// им в инспекторе главного окна, рядом с самой очередью. Первый же
  /// раздел говорит об этом прямо — раньше человек искал их тут и не
  /// находил.
  List<Widget> _transcriberTab(SettingsState s) => [
    SectionTitle(l10n.sectionHowToRecognize),
    Hint(l10n.hintPerRecordingSettings),
    SectionTitle(l10n.sectionAutoSave),
    Check(l10n.checkSaveToDisk, s.toLibrary, _cubit.setToLibrary),
    Hint(l10n.hintSaveToDisk(appName), under: true),
    SectionTitle(l10n.sectionWhereToSave),
    LibraryPath(
      path: s.libraryPath,
      onReveal: () => _cubit.revealLibrary(s.libraryPath),
      onChange: () => _pickLibrary(s),
      hint: l10n.libraryHint(
        appName,
        monthFolder(DateTime.now()),
        os.fileManagerName,
      ),
    ),
    if (s.toLibrary) ...[
      SectionTitle(l10n.sectionAutoSaveFormats),
      for (final f in exportFormats)
        // suffix у «текста с таймкодами» начинается с пробела: он
        // дописывается к имени файла. В подписи этот пробел — дыра.
        Check(
          '${f.label} · ${f.suffix.trim()}',
          s.libraryFormats.contains(f.id),
          (v) => _cubit.toggleFormat(f.id, v),
        ),
      Hint(
        s.libraryFormats.length > 1
            ? l10n.hintFormatsMulti
            : l10n.hintFormatsSingle,
        under: true,
      ),
    ],
    SectionTitle(l10n.labelCopyFormat),
    MacosPopupButton<String>(
      value: s.copyFormat,
      items: [
        for (final f in exportFormats)
          MacosPopupMenuItem(value: f.id, child: Text(f.label)),
      ],
      onChanged: (value) {
        if (value != null) _cubit.setCopyFormat(value);
      },
    ),
    Hint(l10n.hintCopyFormatSynced),
    SectionTitle(l10n.labelSaveFormat),
    MacosPopupButton<String>(
      value: s.saveFormat,
      items: [
        for (final f in exportFormats)
          MacosPopupMenuItem(value: f.id, child: Text(f.label)),
      ],
      onChanged: (value) {
        if (value != null) _cubit.setSaveFormat(value);
      },
    ),
    Hint(l10n.hintSaveFormatSynced),
    SectionTitle(l10n.sectionCopyBesideSource),
    Check(
      l10n.checkSaveBesideSource,
      s.saveNextToSource,
      _cubit.setSaveNextToSource,
    ),
    Hint(l10n.hintSaveBesideSource, under: true),
    // Метки времени переехали сюда из «Общих»: они рисуются в окне
    // расшифровщика и больше нигде — в диктовке текста с таймкодами
    // нет вовсе.
    SectionTitle(l10n.sectionInTranscriberWindow),
    Check(l10n.checkShowTimestamps, s.timestamps, _cubit.setTimestamps),
    Hint(l10n.hintShowTimestamps, under: true),
  ];

  /// Местное API: та самая галка, которой открывают дверь наружу.
  ///
  /// Стоит на вкладке «Приложение», а не у расшифровщика: это не про то,
  /// как распознавать, а про то, кому позволено просить. Ключ показан
  /// целиком — прятать его за звёздочками бессмысленно, он нужен именно
  /// для того, чтобы его скопировать и отдать своей программе.
  List<Widget> _apiSection(SettingsState s) => [
    SectionTitle(l10n.sectionApi),
    Check(l10n.checkApiEnabled, s.apiEnabled, (v) {
      setState(() => _keyCopied = false);
      _cubit.setApiEnabled(v);
    }),
    Hint(
      s.apiEnabled ? l10n.hintApiEnabled('${s.apiPort}') : l10n.hintApiDisabled,
      under: true,
    ),
    if (s.apiEnabled) ...[
      if (s.apiError.isNotEmpty)
        _problem(l10n.apiFailed(s.apiError, '${s.apiPort}')),
      const SizedBox(height: Gap.item),
      _Field(
        l10n.fieldApiKey,
        Row(
          children: [
            Expanded(
              child: Text(
                s.apiKey,
                maxLines: 1,
                style: Type.control.copyWith(fontFamily: 'Menlo'),
              ),
            ),
            const SizedBox(width: Gap.control),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: s.apiKey));
                setState(() => _keyCopied = true);
              },
              child: Text(l10n.buttonCopyKey),
            ),
          ],
        ),
      ),
      Hint(_keyCopied ? l10n.apiKeyCopied : l10n.hintApiKey),
    ],
  ];

  /// Скилл для нейросетевых агентов.
  ///
  /// Раздел свёрнут по умолчанию, и это не кокетство: тому, кто
  /// нейросетевыми агентами не пользуется, он не должен мозолить глаза
  /// на каждом открытии настроек. Развернувшему видно две вещи — кому
  /// скилл уже поставлен и кому его можно поставить.
  ///
  /// Галку у ненайденного агента человек может поставить сам: он вправе
  /// собираться поставить агента следом за нами, и запрещать ему это
  /// значило бы решать за него. Папку тогда заводим мы — но только
  /// по его нажатию и только ту, что этому агенту и принадлежит.
  List<Widget> _skillSection(SettingsState s) {
    final installed = [
      for (final a in skillAgents)
        if (a.alreadyInstalled()) a,
    ];
    return [
      SectionTitle(l10n.sectionSkill),
      Hint(l10n.hintSkill, under: true),
      const SizedBox(height: Gap.inner),
      Disclosure(
        label: l10n.sectionSkill,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Gap.item),
            Text(l10n.skillInstalledFor, style: Type.control),
            const SizedBox(height: Gap.hint),
            Text(
              installed.isEmpty
                  ? l10n.skillNobodyYet
                  : installed.map((a) => a.name).join(', '),
              style: Type.caption.copyWith(
                color: installed.isEmpty
                    ? Surface.secondaryText(context)
                    : MacosColors.systemGreenColor,
              ),
            ),
            const SizedBox(height: Gap.section),
            Text(l10n.skillCanInstallFor, style: Type.control),
            const SizedBox(height: Gap.inner),
            for (final agent in skillAgents)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.tight),
                child: Check(
                  agent.configDir() == null
                      ? '${agent.name} — ${l10n.skillAgentMissing}'
                      : agent.name,
                  _skillPicked(agent),
                  (on) => setState(() => _skillPick[agent.id] = on),
                ),
              ),
            const SizedBox(height: Gap.item),
            Row(
              children: [
                PushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
                  onPressed: () => _cubit.installSkillToAgents([
                    for (final a in skillAgents)
                      if (_skillPicked(a)) a,
                  ]),
                  child: Text(l10n.buttonInstallSkillChosen),
                ),
              ],
            ),
            for (final agent in skillAgents)
              if (s.skillResult[agent.id] != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.hint),
                  child: Text(
                    '${agent.name} — ${switch (s.skillResult[agent.id]!) {
                      SkillOutcome.installed => l10n.skillInstalled,
                      // Место занято чужим скиллом с тем же именем.
                      // Затирать чужую работу хуже, чем не поставить свою.
                      SkillOutcome.foreign => l10n.skillForeign,
                      SkillOutcome.failed => l10n.skillFailed,
                    }}',
                    style: Type.caption.copyWith(
                      color: s.skillResult[agent.id] == SkillOutcome.installed
                          ? MacosColors.systemGreenColor
                          : Surface.secondaryText(context),
                    ),
                  ),
                ),
          ],
        ),
      ),
    ];
  }

  /// Что человек решил про каждого агента. Пусто — решения не было, и
  /// тогда действует умолчание: найденный отмечен, ненайденный нет.
  final _skillPick = <String, bool>{};

  bool _skillPicked(AgentTarget a) =>
      _skillPick[a.id] ?? (a.configDir() != null);

  // ── приложение ────────────────────────────────────────────────────────────

  /// Здесь остаётся только то, что не принадлежит ни расшифровщику,
  /// ни диктовке: как приложение живёт в системе и что ему разрешено.
  /// Всё остальное разъехалось по хозяевам.
  List<Widget> _appTab(SettingsState s) => [
    SectionTitle(l10n.sectionLanguage),
    _Field(
      l10n.fieldLanguage,
      MacosPopupButton<String>(
        value: s.locale,
        items: [
          MacosPopupMenuItem(value: '', child: Text(l10n.languageSystem)),
          // Языки названы на себе самих: так их узнают и те, кто
          // случайно переключился на незнакомый.
          const MacosPopupMenuItem(value: 'ru', child: Text('Русский')),
          const MacosPopupMenuItem(value: 'en', child: Text('English')),
        ],
        onChanged: (v) => _cubit.setLocale(v ?? ''),
      ),
    ),
    Hint(l10n.hintLanguage),
    SectionTitle(l10n.sectionInSystem),
    Check(l10n.checkLoginItem, s.loginItem, _cubit.setLoginItem),
    Hint(l10n.hintLoginItem(os.menuBarName), under: true),
    const SizedBox(height: Gap.item),
    Check(
      l10n.checkShowDockIcon(os.appIconAreaName),
      s.dockIcon,
      _cubit.setDockIcon,
    ),
    Hint(
      l10n.hintDockIcon(appName, os.appIconAreaName, os.menuBarName),
      under: true,
    ),
    ..._apiSection(s),
    ..._skillSection(s),
    // Разрешение системы — вещь macOS: там без «Универсального доступа»
    // не перехватить клавишу и не вставить текст. На Windows такого
    // разрешения нет вовсе, и раздел о нём обещал бы работу, которой
    // не существует. Микрофон — другое дело, но его спрашивает сама
    // система при первой записи.
    if (os.needsAccessibilityPermission) ...[
      SectionTitle(l10n.sectionPermissions),
      Row(
        children: [
          Expanded(
            child: Text(
              s.allowed
                  ? l10n.permissionGranted(os.accessibilityName)
                  : l10n.permissionMissing(os.accessibilityName, appName),
              style: Type.control.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
      Hint(l10n.hintPermissionWhy),
      const SizedBox(height: Gap.item),
      if (!s.allowed)
        Row(
          children: [
            PushButton(
              controlSize: ControlSize.regular,
              onPressed: _cubit.requestPermission,
              child: Text(l10n.buttonRequestPermission),
            ),
            const SizedBox(width: Gap.control),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _cubit.openPermissionSettings,
              child: Text(l10n.buttonOpenSystemSettings),
            ),
          ],
        )
      else
        PushButton(
          controlSize: ControlSize.regular,
          secondary: true,
          onPressed: _cubit.openPermissionSettings,
          child: Text(l10n.buttonOpenSystemSettings),
        ),
    ],
    SectionTitle(l10n.sectionLogging),
    Check(l10n.checkEnableLogging, s.loggingEnabled, _cubit.setLoggingEnabled),
    Hint(l10n.hintEnableLogging, under: true),
    const SizedBox(height: Gap.item),
    Row(
      children: [
        Expanded(
          child: Text(
            Log.logsDir.replaceFirst(home, '~'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(color: Surface.secondaryText(context)),
          ),
        ),
        const SizedBox(width: Gap.inner),
        MacosTooltip(
          message: l10n.tooltipOpenLogsFolder,
          child: PushButton(
            controlSize: ControlSize.regular,
            secondary: true,
            onPressed: () => Log.openLogsFolder(),
            child: Text(l10n.menuOpenLogsFolder),
          ),
        ),
      ],
    ),
    Hint(l10n.tooltipOpenLogsFolder),
  ];
}

/// Подпись над полем, а не слева от него: выпадающий список в macOS
/// шириной со своё самое длинное имя, и в узкой колонке он вылезал
/// за край окна.
class _Field extends StatelessWidget {
  const _Field(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Type.caption.copyWith(color: Surface.secondaryText(context)),
      ),
      // Подпись прижата к своему полю, а расстояние до следующей
      // настройки задаётся снаружи и всегда больше.
      const SizedBox(height: Gap.hint),
      child,
    ],
  );
}

/// Вкладка в полосе: значок над подписью — как в панели инструментов
/// системных приложений.
class _TabButton extends StatefulWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final color = widget.selected ? accent : Surface.secondaryText(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.press),
          curve: Curves.easeOut,
          // Ширины хватает самой длинной подписи («Расшифровщик»):
          // ужатая до многоточия вкладка не называет ничего.
          width: 96,
          margin: const EdgeInsets.symmetric(horizontal: Gap.hint),
          padding: const EdgeInsets.symmetric(vertical: Gap.inner),
          decoration: BoxDecoration(
            color: widget.selected
                ? Surface.pressed(context)
                : _hover
                ? Surface.hover(context)
                : MacosColors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ступень панели инструментов: вкладка стоит в той же
              // полосе, что и панель в других окнах, и значок в ней
              // держится сам, без текста рядом.
              MacosIcon(widget.icon, size: IconSize.toolbar, color: color),
              const SizedBox(height: Gap.hint),
              Text(
                widget.label,
                maxLines: 1,
                style: Type.caption.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VocabularyFilterBar extends StatelessWidget {
  const _VocabularyFilterBar({
    required this.selectedFilter,
    required this.totalCount,
    required this.hintsCount,
    required this.replacementsCount,
    required this.allLabel,
    required this.hintsLabel,
    required this.replacementsLabel,
    required this.onSelected,
  });

  final int selectedFilter;
  final int totalCount;
  final int hintsCount;
  final int replacementsCount;
  final String allLabel;
  final String hintsLabel;
  final String replacementsLabel;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Surface.isDark(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0x1F2A2A2E) : const Color(0x0F000000),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Surface.hairline(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FilterSegment(
            label: allLabel,
            count: totalCount,
            selected: selectedFilter == 0,
            onTap: () => onSelected(0),
          ),
          _FilterSegment(
            label: hintsLabel,
            count: hintsCount,
            selected: selectedFilter == 1,
            onTap: () => onSelected(1),
          ),
          _FilterSegment(
            label: replacementsLabel,
            count: replacementsCount,
            selected: selectedFilter == 2,
            onTap: () => onSelected(2),
          ),
        ],
      ),
    );
  }
}

class _FilterSegment extends StatefulWidget {
  const _FilterSegment({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FilterSegment> createState() => _FilterSegmentState();
}

class _FilterSegmentState extends State<_FilterSegment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Surface.isDark(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: Motion.dur(context, Motion.quick),
          curve: Motion.curve(context, Motion.quickCurve),
          padding: const EdgeInsets.symmetric(horizontal: Gap.inner),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.selected
                ? (isDark ? const Color(0xFF3A3A3C) : const Color(0xFFFFFFFF))
                : (_hover
                      ? (isDark
                            ? const Color(0x10FFFFFF)
                            : const Color(0x08000000))
                      : MacosColors.transparent),
            borderRadius: BorderRadius.circular(5),
            boxShadow: widget.selected
                ? [
                    const BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
            border: widget.selected
                ? Border.all(color: Surface.hairline(context), width: 0.5)
                : null,
          ),
          child: Text(
            '${widget.label} (${widget.count})',
            style: Type.caption.copyWith(
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal,
              color: widget.selected ? null : Surface.secondaryText(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatefulWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : (_hover ? 1.02 : 1.0),
          duration: Motion.dur(context, Motion.press),
          curve: Motion.curve(context, Motion.settleCurve),
          child: AnimatedContainer(
            duration: Motion.dur(context, Motion.quick),
            curve: Motion.curve(context, Motion.quickCurve),
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.control,
              vertical: Gap.inner,
            ),
            decoration: BoxDecoration(
              color: Surface.isDark(context)
                  ? (_hover ? const Color(0xFF48484C) : const Color(0xFF38383B))
                  : (_hover
                        ? const Color(0xFFE5E5E9)
                        : const Color(0xFFF0F0F2)),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _hover
                    ? MacosTheme.of(context).primaryColor.withValues(alpha: 0.5)
                    : Surface.hairline(context),
              ),
            ),
            child: Text(
              widget.label,
              style: Type.control.copyWith(
                color: Surface.isDark(context)
                    ? const Color(0xFFF5F5F7)
                    : const Color(0xFF242428),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
