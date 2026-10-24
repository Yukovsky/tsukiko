import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/transcript.dart';

const _segs = [
  Segment(0, 1500, 'Привет.', speaker: 'S1'),
  Segment(1500, 3000, 'Как дела?', speaker: 'S1'),
  Segment(2800, 4000, 'Хорошо.', speaker: 'S2', overlap: true),
  Segment(4000, 5000, 'Отлично.', speaker: 'S1'),
];

const _voices = [
  SpeakerInfo(id: 'S1', name: 'Иван', talkMs: 4000, turns: 2),
  SpeakerInfo(id: 'S2', name: 'Мария', talkMs: 1200, turns: 1),
];

const _info = DiarizationInfo(
  segmentation: 'pyannote-segmentation-3.0',
  embedding: 'nemo_en_titanet_small',
  threshold: 0.9,
  requestedSpeakers: 0,
  detectedSpeakers: 2,
);

const _voiced = Transcript('ru', _segs, speakers: _voices, diarization: _info);

/// Те же фрагменты без голосов — так выглядела расшифровка до режима.
const _plainSegs = [
  Segment(0, 1500, 'Привет.'),
  Segment(1500, 3000, 'Как дела?'),
  Segment(2800, 4000, 'Хорошо.'),
  Segment(4000, 5000, 'Отлично.'),
];

void main() {
  group('без голосов вывод прежний', () {
    // Ожидания записаны руками по прежним рендерам: голоса не должны
    // сдвинуть в старом выводе ни одного символа.
    const t = Transcript('ru', _plainSegs);

    test('txt и txt с таймкодами', () {
      expect(renderAs(formatPlainText, t), 'Привет.\nКак дела?\nХорошо.\nОтлично.');
      expect(
        renderAs(formatTimedText, t).split('\n').first,
        '[00:00:00.000 → 00:00:01.500]  Привет.',
      );
    });

    test('srt, vtt, md, json', () {
      expect(
        renderAs(formatSrt, t),
        startsWith('1\n00:00:00,000 --> 00:00:01,500\nПривет.\n\n2\n'),
      );
      expect(
        renderAs(formatVtt, t),
        startsWith('WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nПривет.\n\n'),
      );
      expect(
        renderAs(formatMarkdown, t, name: 'x'),
        startsWith('# x\n\n**[00:00:00.000]** Привет.\n\n'),
      );
      final json = renderAs(formatJson, t);
      expect(json.contains('speaker'), isFalse);
      expect(json.contains('diarization'), isFalse);
    });

    test('один голос в списке — тоже без подписей', () {
      const single = Transcript(
        'ru',
        [Segment(0, 1000, 'раз', speaker: 'S1')],
        speakers: [SpeakerInfo(id: 'S1', name: 'Иван')],
      );
      expect(renderAs(formatPlainText, single), 'раз');
      expect(renderAs(formatSrt, single).contains('Иван'), isFalse);
      expect(renderAs(formatJson, single).contains('speaker'), isFalse);
    });
  });

  group('с голосами', () {
    test('txt: реплика одного голоса — абзац с одной шапкой', () {
      expect(
        renderAs(formatPlainText, _voiced),
        'Иван: Привет. Как дела?\n\n'
        '⇄ Мария: Хорошо.\n\n'
        'Иван: Отлично.',
      );
    });

    test('txt с таймкодами', () {
      final lines = renderAs(formatTimedText, _voiced).split('\n');
      expect(lines[0], '[00:00:00.000 → 00:00:01.500]  Иван: Привет.');
      expect(lines[2], '[00:00:02.800 → 00:00:04.000]  ⇄ Мария: Хорошо.');
    });

    test('srt: имя в первой строке реплики', () {
      final srt = renderAs(formatSrt, _voiced);
      expect(srt, contains('00:00:02,800 --> 00:00:04,000\nМария: Хорошо.\n'));
      expect(srt.contains('⇄'), isFalse);
    });

    test('vtt: голосовой тег и экранирование', () {
      expect(renderAs(formatVtt, _voiced), contains('<v Иван>Привет.</v>'));
      final tricky = _voiced.copyWith(
        speakers: const [
          SpeakerInfo(id: 'S1', name: 'A<b>&c'),
          SpeakerInfo(id: 'S2', name: 'Мария'),
        ],
      );
      expect(renderAs(formatVtt, tricky), contains('<v A&lt;b&gt;&amp;c>'));
    });

    test('md: имя, время, перебивка и экранирование', () {
      final md = renderAs(formatMarkdown, _voiced, name: 'x');
      expect(md, contains('**Иван** · [00:00:00.000]\nПривет. Как дела?\n'));
      expect(md, contains('⇄ **Мария** · [00:00:02.800]\nХорошо.\n'));
      final tricky = _voiced.copyWith(
        speakers: const [
          SpeakerInfo(id: 'S1', name: '*Иван* [1]'),
          SpeakerInfo(id: 'S2', name: 'Мария'),
        ],
      );
      expect(
        renderAs(formatMarkdown, tricky, name: 'x'),
        contains(r'**\*Иван\* \[1\]**'),
      );
    });

    test('json: круговой обмен', () {
      final json = renderAs(formatJson, _voiced);
      expect(json, contains('"speaker": "S2"'));
      expect(json, contains('"overlap": true'));
      expect(json, contains('"engine": "sherpa-onnx"'));

      final back = readTranscript('x.json', json).parsed!;
      expect(back.lang, 'ru');
      expect(back.segments.map((s) => s.text), _segs.map((s) => s.text));
      expect(back.segments.map((s) => s.speaker), _segs.map((s) => s.speaker));
      expect(back.segments.map((s) => s.overlap), _segs.map((s) => s.overlap));
      expect(back.speakers, _voices);
      expect(back.diarization, _info);
      expect(renderAs(formatJson, back), json);
    });

    test('свой json без голосов тоже открывается', () {
      const t = Transcript('ru', _plainSegs);
      final back = readTranscript('x.json', renderAs(formatJson, t)).parsed!;
      expect(back.segments.length, 4);
      expect(back.speakers, isEmpty);
    });
  });
}
