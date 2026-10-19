import 'dart:async';

import 'support/fake_os.dart';

/// Общая подмена для всех тестов: настоящая папка пользователя не трогается.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installTempOsForFile();
  await testMain();
}
