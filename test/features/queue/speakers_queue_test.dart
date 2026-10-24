import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/settings.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/features/queue/job.dart';
import 'package:tsukiko/features/queue/queue_bloc.dart';
import 'package:tsukiko/features/queue/queue_event.dart';
import 'package:tsukiko/platform/bridge.dart';

import '../../support/fake_os.dart';

/// Голоса в очереди: правки списка голосов и то, что сбой разметки
/// не трогает готовый текст.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const channel = MethodChannel('tsukiko/dictation');

  useTempSupportDir('tsukiko-speakers-queue');

  setUp(() {
    binding.platformDispatcher.localesTestValue = const [Locale('ru')];
    tmp = Directory.systemTemp.createTempSync('tsukiko-speakers');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    NativeBridge.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tmp.deleteSync(recursive: true);
  });

  const voiced = Transcript(
    'ru',
    [
      Segment(0, 1000, 'Привет.', speaker: 'S1'),
      Segment(1000, 2000, 'Здравствуй.', speaker: 'S2'),
      Segment(2000, 3000, 'Как дела?', speaker: 'S1'),
      Segment(3000, 4000, 'Хорошо.', speaker: 'S3'),
    ],
    speakers: [
      SpeakerInfo(id: 'S1', name: 'Голос 1', colorIndex: 0),
      SpeakerInfo(id: 'S2', name: 'Голос 2', colorIndex: 1),
      SpeakerInfo(id: 'S3', name: 'Голос 3', colorIndex: 2),
    ],
  );

  /// Запись с готовой расшифровкой — как её открывает обзор прошлых.
  Future<QueueBloc> opened() async {
    final audio = File('${tmp.path}/встреча.m4a')..writeAsStringSync('звук');
    final json = File('${tmp.path}/встреча.json')
      ..writeAsStringSync(renderJson(voiced));
    final bloc = QueueBloc(NativeBridge());
    bloc.add(SourceOpened(audio.path, json.path));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await pumpEventQueue();
    return bloc;
  }

  Job lead(QueueBloc b) => b.state.jobs.single;

  test('открытая расшифровка приходит с голосами', () async {
    final b = await opened();
    expect(lead(b).transcript!.speakers.length, 3);
    expect(lead(b).segments.map((s) => s.speaker), ['S1', 'S2', 'S1', 'S3']);
    await b.close();
  });

  test('переименование меняет только список голосов', () async {
    final b = await opened();
    b.add(SpeakerRenamed(lead(b), 'S2', '  Мария '));
    await pumpEventQueue();
    final t = lead(b).transcript!;
    expect(t.speakerName('S2'), 'Мария');
    expect(t.segments[1].speaker, 'S2');
    expect(b.state.status, contains('Мария'));

    // Пустое имя — вернуть имя по умолчанию.
    b.add(SpeakerRenamed(lead(b), 'S2', ''));
    await pumpEventQueue();
    expect(lead(b).transcript!.speakerName('S2'), 'Голос 2');
    await b.close();
  });

  test('слияние переносит фрагменты, имя и цвет остаются у целевого', () async {
    final b = await opened();
    b.add(SpeakerRenamed(lead(b), 'S1', 'Иван'));
    await pumpEventQueue();
    b.add(SpeakersMerged(lead(b), 'S3', 'S1'));
    await pumpEventQueue();
    final t = lead(b).transcript!;
    expect(t.segments.map((s) => s.speaker), ['S1', 'S2', 'S1', 'S1']);
    expect(t.speakers.map((s) => s.id), ['S1', 'S2']);
    expect(t.speakerName('S1'), 'Иван');
    expect(t.speakers.first.colorIndex, 0);

    // Остался один голос — разметка снимается целиком, как без режима.
    b.add(SpeakersMerged(lead(b), 'S2', 'S1'));
    await pumpEventQueue();
    final single = lead(b).transcript!;
    expect(single.speakers, isEmpty);
    expect(single.segments.every((s) => s.speaker == null), isTrue);
    expect(single.segments.length, 4, reason: 'текст не тронут');
    await b.close();
  });

  test('переназначение одного фрагмента', () async {
    final b = await opened();
    final third = lead(b).segments[2];
    b.add(SegmentSpeakerChanged(lead(b), third, 'S2'));
    await pumpEventQueue();
    final t = lead(b).transcript!;
    expect(t.segments.map((s) => s.speaker), ['S1', 'S2', 'S2', 'S3']);
    expect(t.speakers.firstWhere((s) => s.id == 'S2').turns, 1);
    await b.close();
  });

  test('сбой разметки не теряет готовую расшифровку', () async {
    final b = await opened();
    // Звука в «встреча.m4a» нет — подготовка звука падает.
    b.add(DiarizationRequested(lead(b)));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pumpEventQueue();
    final job = lead(b);
    expect(job.state, JobState.done);
    expect(job.transcript!.segments.map((s) => s.text), [
      'Привет.',
      'Здравствуй.',
      'Как дела?',
      'Хорошо.',
    ]);
    expect(b.state.running, isFalse);
    await b.close();
  });

  test('режим включается и выключается в общих настройках', () async {
    final b = QueueBloc(NativeBridge());
    expect(b.state.defaults.diarize, isFalse);
    b.add(const DiarizationToggled(true));
    b.add(const SpeakerCountChosen(3));
    await pumpEventQueue();
    expect(b.state.defaults.diarize, isTrue);
    expect(b.state.defaults.speakerCount, 3);
    await b.close();
  });

  test('разговор из диктовки встаёт в очередь с разметкой голосов', () async {
    final b = QueueBloc(NativeBridge());
    final audio = File('${tmp.path}/Разговор.wav')..writeAsStringSync('звук');
    // Диктовка находит очередь по имени порта — как в приложении.
    IsolateNameServer.lookupPortByName(conversationInboxPort)!.send({
      'path': audio.path,
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pumpEventQueue();
    final job = b.state.jobs.singleWhere((j) => j.path == audio.path);
    expect(b.state.optionsFor(job).diarize, isTrue);
    expect(b.state.defaults.diarize, isFalse, reason: 'общие не трогаем');
    await b.close();
    expect(IsolateNameServer.lookupPortByName(conversationInboxPort), isNull);
  });
}
