part of 'home_page.dart';

/// Меню в строке меню. Собирается заново только когда меняется то, что
/// в нём видно, — иначе Flutter пересобирал бы NSMenu на каждое состояние.
extension _Menus on _HomeViewState {
  /// PlatformMenuItem сравнивается по ссылке, поэтому Flutter пересобирает
  /// NSMenu на каждый setState — а во время распознавания их десятки в секунду.
  /// Пересобираем меню только когда меняется то, что в нём видно.
  List<PlatformMenuItem> _menus(QueueState s) {
    // Список значений, а не склеенная строка. Склейка работала верно:
    // разделителями стояли управляющие символы \x00 и \x01, которых
    // в путях не бывает. Но стояли они в исходнике сырыми байтами — файл
    // после этого двоичный для git (никакого diff по нему) и неразличимый
    // на глаз в любом редакторе. Сравнение списков даёт ту же гарантию
    // и остаётся читаемым.
    final signature = <Object?>[
      s.readyTargets.isNotEmpty,
      s.targets.isNotEmpty,
      s.targets.any((j) => !j.imported),
      s.targets.every((j) => j.done),
      s.running,
      s.hasPending,
      s.jobs.any((j) => j.done),
      s.jobs.isEmpty,
      s.selected.isEmpty,
      s.lead == null,
      s.timestamps,
      s.libraryPath,
      s.lead?.file.path,
      ...s.recent,
    ];
    if (listEquals(signature, _menuSignature)) return _menuCache;
    _menuSignature = signature;
    return _menuCache = _buildMenus(s);
  }

  List<PlatformMenuItem> _buildMenus(QueueState s) {
    final l10n = AppLocalizations.of(context);
    final ready = s.readyTargets.isNotEmpty;
    final selected = s.targets.isNotEmpty;
    return [
      PlatformMenu(
        label: appName,
        menus: [
          PlatformMenuItem(label: l10n.menuAbout(appName), onSelected: _about),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuSettingsEllipsis,
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              onSelected: () => _openSettings(),
            ),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuFile,
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: l10n.menuAddAudio, shortcut: _HomeViewState._cmd, onSelected: _pickFiles),
            PlatformMenuItem(
              label: l10n.menuOpenTranscript,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
              onSelected: _openTranscript,
            ),
            PlatformMenuItem(
              label: l10n.menuConvertTranscript,
              onSelected: _convertTranscript,
            ),
            PlatformMenuItem(
              label: l10n.menuPastTranscripts,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyL, meta: true),
              onSelected: () => _showLibrary(s),
            ),
            PlatformMenu(
              label: l10n.menuOpenRecent,
              menus: [
                for (final p in s.recent)
                  PlatformMenuItem(
                    label: os.basename(p),
                    onSelected: () => _send(audioExt.contains(_ext(p))
                        ? FilesAdded([p])
                        : TranscriptOpened(p)),
                  ),
                if (s.recent.isNotEmpty)
                  PlatformMenuItemGroup(members: [
                    PlatformMenuItem(
                      label: l10n.menuClearRecentList,
                      onSelected: () => _send(const RecentCleared()),
                    ),
                  ]),
              ],
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuSaveAs,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
              onSelected: ready ? () => _saveAs(s) : null,
            ),
            PlatformMenuItem(
              label: l10n.menuExportToFolder,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true),
              onSelected: s.jobs.any((j) => j.done) ? () => _exportAll(s) : null,
            ),
            PlatformMenuItem(
              label: l10n.menuShowLibraryIn(os.fileManagerName),
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true),
              onSelected: () =>
                  revealInFinder(s.libraryPath, createIfMissing: true),
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuShowSourceIn(os.fileManagerName),
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
              onSelected:
                  s.lead == null ? null : () => _revealSource(s.lead!.path),
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuEdit,
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuCopyText,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true),
              onSelected: ready ? () => _copy(formatPlainText) : null,
            ),
            PlatformMenuItem(
              label: l10n.menuCopyWithTimestamps,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyC,
                  meta: true, shift: true, alt: true),
              onSelected: ready ? () => _copy(formatTimedText) : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuSelectAllRecordings,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
              onSelected: s.jobs.isEmpty ? null : _sendAll,
            ),
            PlatformMenuItem(
              label: l10n.menuDeselectAll,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true),
              onSelected: s.selected.isEmpty ? null : _sendDeselect,
            ),
            PlatformMenuItem(
              label: l10n.menuRemoveFromQueue,
              shortcut: const SingleActivator(LogicalKeyboardKey.backspace, meta: true),
              onSelected: selected ? _sendRemove : null,
            ),
            PlatformMenuItem(
              label: l10n.menuRemoveAllFinished,
              onSelected: s.jobs.any((j) => j.done) ? _sendClearFinished : null,
            ),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuFindInTranscript,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
              onSelected: s.lead == null ? null : _openFind,
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuRecognition,
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: l10n.menuRunQueue,
              shortcut: const SingleActivator(LogicalKeyboardKey.enter, meta: true),
              onSelected: s.running || !s.hasPending ? null : _sendStart,
            ),
            PlatformMenuItem(
              label: _recognizeLabel(s.targets, many: s.targets.length > 1),
              shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true, alt: true),
              onSelected: s.running || !s.canRetry ? null : _sendRetry,
            ),
            PlatformMenuItem(
              label: l10n.menuStop,
              shortcut: const SingleActivator(LogicalKeyboardKey.period, meta: true),
              onSelected: s.running ? _sendStop : null,
            ),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuView,
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(
              label: s.timestamps ? l10n.menuHideTimestamps : l10n.menuShowTimestamps,
              shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, alt: true),
              onSelected: () => _send(const TimestampsToggled()),
            ),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuWindow,
        menus: [
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          ]),
          PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ]),
        ],
      ),
      PlatformMenu(
        label: l10n.menuHelp,
        menus: [
          PlatformMenuItem(
            label: l10n.menuWhereTranscriptsLive,
            onSelected: () =>
                revealInFinder(s.libraryPath, createIfMissing: true),
          ),
          PlatformMenuItem(
            label: l10n.menuOpenLogsFolder,
            onSelected: () => Log.openLogsFolder(),
          ),
          PlatformMenuItem(label: l10n.menuAbout(appName), onSelected: _about),
        ],
      ),
    ];
  }
}
