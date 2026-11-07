import 'dart:io' show FileSystemEntity, FileSystemEntityType;

import 'package:flutter/widgets.dart';

import 'queue_bloc.dart' show normalizePath;

/// Фокус в поле ввода: там ⌘V (Ctrl+V) остаётся обычной вставкой текста.
bool textFieldFocused() =>
    primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() !=
    null;

/// Что ⌘V (Ctrl+V) вне поля ввода кладёт в очередь.
///
/// Сначала файлы, скопированные в Finder или Проводнике ([files] читает их
/// у раннера). Если их нет, текст: «Копировать как путь» в Проводнике
/// и ⌥⌘C в Finder кладут путь строкой. Его берём, только если каждая
/// строка ведёт к существующему файлу или папке, иначе это обычный текст.
/// Подходит ли файл очереди, решает уже она и сама говорит, если нет.
Future<List<String>> pastedPaths({
  required Future<List<String>?> Function() files,
  required Future<String?> Function() text,
}) async {
  try {
    final copied = await files();
    if (copied != null && copied.isNotEmpty) return copied;
  } catch (_) {
    // Раннер не ответил: остаётся текст.
  }
  final lines = (await text() ?? '')
      .split(RegExp(r'[\r\n]+'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  return lines.isNotEmpty && lines.every(_exists) ? lines : const [];
}

bool _exists(String line) {
  try {
    return FileSystemEntity.typeSync(normalizePath(line)) !=
        FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}
