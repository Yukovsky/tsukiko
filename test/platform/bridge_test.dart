import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/platform/bridge.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late NativeBridge bridge;
  String? mockHudStateResponse;

  setUp(() {
    NativeBridge.debugReset();
    mockHudStateResponse = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        if (call.method == 'getHudState') {
          return mockHudStateResponse;
        }
        return null;
      },
    );
    bridge = NativeBridge();
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      null,
    );
  });

  testWidgets('paste returns immediately; subsequent clipboard use waits', (
    tester,
  ) async {
    NativeBridge.debugReset();
    bridge = NativeBridge();
    final pasted = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        if (call.method == 'paste') {
          pasted.add((call.arguments as Map)['text'] as String);
          return true;
        }
        return null;
      },
    );
    var firstDone = false;
    unawaited(
      bridge.insert('first').then((sent) {
        firstDone = sent;
      }),
    );
    await tester.pump();
    expect(
      firstDone,
      isTrue,
      reason: 'Next ASR may start without the paste cooldown',
    );
    var clipboardReady = false;
    unawaited(
      bridge.waitForPaste().then((_) {
        clipboardReady = true;
      }),
    );
    var secondDone = false;
    unawaited(
      bridge.insert('second').then((sent) {
        secondDone = sent;
      }),
    );
    await tester.pump(const Duration(milliseconds: 449));
    expect(pasted, ['first']);
    expect(clipboardReady, isFalse);
    expect(secondDone, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pasted, ['first', 'second']);
    expect(clipboardReady, isTrue);
    expect(secondDone, isTrue);
    final copied = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    final copy = bridge.copyText('manual copy');
    final third = bridge.insert('third');
    await tester.pump(const Duration(milliseconds: 449));
    expect(copied, isEmpty);
    expect(pasted, ['first', 'second']);
    await tester.pump(const Duration(milliseconds: 1));
    await copy;
    expect(copied, ['manual copy']);
    expect(await third, isTrue);
    expect(pasted, ['first', 'second', 'third']);
    await tester.pump(const Duration(milliseconds: 450));
    await bridge.waitForPaste();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  test('failed or rejected paste releases subsequent requests', () async {
    var attempts = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('tsukiko/dictation'),
      (call) async {
        if (call.method == 'paste') {
          attempts++;
          if (attempts == 1) throw PlatformException(code: 'paste-failed');
          return false;
        }
        return null;
      },
    );
    final failed = bridge.insert('first');
    final next = bridge.insert('second');
    await expectLater(failed, throwsA(isA<PlatformException>()));
    expect(await next, isFalse);
    await bridge.waitForPaste();
    expect(attempts, 2);
  });

  group('currentHudState', () {
    test('возвращает null если канал вернул null', () async {
      mockHudStateResponse = null;
      final state = await bridge.currentHudState();
      expect(state, isNull);
    });

    test('возвращает корректный HudState для известных состояний', () async {
      mockHudStateResponse = 'recording';
      expect(await bridge.currentHudState(), HudState.recording);

      mockHudStateResponse = 'transcribing';
      expect(await bridge.currentHudState(), HudState.transcribing);

      mockHudStateResponse = 'done';
      expect(await bridge.currentHudState(), HudState.done);

      mockHudStateResponse = 'hidden';
      expect(await bridge.currentHudState(), HudState.hidden);
    });

    test('возвращает HudState.hidden для неизвестного состояния', () async {
      mockHudStateResponse = 'some_unrecognized_state';
      expect(await bridge.currentHudState(), HudState.hidden);
    });
  });

  group('система: сон и пробуждение', () {
    test('транслирует события systemSleep и systemWake', () async {
      var slept = false;
      var woke = false;
      bridge.systemSleep.listen((_) => slept = true);
      bridge.systemWake.listen((_) => woke = true);

      const codec = StandardMethodCodec();
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'tsukiko/dictation',
        codec.encodeMethodCall(const MethodCall('systemSleep')),
        (_) {},
      );
      expect(slept, isTrue);
      expect(woke, isFalse);

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'tsukiko/dictation',
        codec.encodeMethodCall(const MethodCall('systemWake')),
        (_) {},
      );
      expect(woke, isTrue);
    });
  });
}
