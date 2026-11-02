import 'dart:async';

import 'package:tsukiko/design/mascot.dart';

import 'support/fake_os.dart';

/// Общая подмена для всех тестов: настоящая папка пользователя не трогается.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installTempOsForFile();
  // Живой кот тикает без остановки, и pumpAndSettle его бы не дождался.
  Mascot.animate = false;
  await testMain();
}
