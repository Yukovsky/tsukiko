import 'package:flutter/foundation.dart' show ValueNotifier;

import 'settings.dart';

/// Строка внешности лунного кота: имя, слова-закрепления и цвет
/// (`lib/design/cat/genome.dart`). Устроена как тема в `app_theme.dart`:
/// у каждого окна свой изолят, с диска строка читается по [refreshCatLook]
/// на старте окна и на «reload» после чужой правки настроек.
final catLook = ValueNotifier<String>(defaultCatLook);

/// Фирменный кот: все части закреплены.
const defaultCatLook = 'tsukiko';

/// Ключ в общих настройках.
const catLookSetting = 'catLook';

/// Перечитать внешность после чужой правки настроек.
void refreshCatLook() {
  final look = (Settings.load()[catLookSetting] as String?)?.trim() ?? '';
  catLook.value = look.isEmpty ? defaultCatLook : look;
}
