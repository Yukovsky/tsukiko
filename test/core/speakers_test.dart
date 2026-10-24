import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/text_commands.dart';
import 'package:tsukiko/core/transcript.dart';
import 'package:tsukiko/core/vocabulary.dart';
import 'package:tsukiko/core/whisper.dart';
import 'package:tsukiko/features/queue/job.dart';
import 'dart:io';

/// Прежняя группировка слов NeMo — копия кода до выноса в [groupWords].
/// Нужна ровно для одного: доказать, что без голосов новая дорога даёт
/// те же фрагменты символ в символ.
List<Segment> _oldNemoGrouping(List<Segment> words) {
  final segments = <Segment>[];
  var start = 0;
  for (var i = 0; i < words.length; i++) {
    final current = words[i];
    final next = i + 1 < words.length ? words[i + 1] : null;
    final chars = words
        .sublist(start, i + 1)
        .fold<int>(0, (sum, word) => sum + word.text.length + 1);
    final sentenceEnd = RegExp(r'[.!?…][\"»”’)]*$').hasMatch(current.text);
    final pause = next != null && next.from - current.to >= 700;
    final tooLong = chars >= 90 || current.to - words[start].from >= 12000;
    if (next == null || sentenceEnd || pause || tooLong) {
      final rawText = words
          .sublist(start, i + 1)
          .map((word) => word.text)
          .join(' ')
          .trim();
      if (rawText.isNotEmpty && !looksLikeSilenceHallucination(rawText)) {
        final text = stripSilenceHallucinations(rawText).trim();
        if (text.isNotEmpty && !looksLikeSilenceHallucination(text)) {
          segments.add(Segment(words[start].from, current.to, text));
        }
      }
      start = i + 1;
    }
  }
  return collapseRepeats(segments);
}

String _dump(List<Segment> segs) => segs
    .map((s) => '${s.from}|${s.to}|${s.text}|${s.speaker}|${s.overlap}')
    .join('\n');

const _a = 'S1', _b = 'S2';

void main() {
  group('assignSpeakers', () {
    test('голос с наибольшим пересечением', () {
      final words = assignSpeakers(
        [const TimedWord(1000, 2000, 'раз')],
        const [SpeakerTurn(0, 1300, _a), SpeakerTurn(1300, 3000, _b)],
      );
      expect(words.single.speaker, _b);
      expect(words.single.overlap, isFalse);
    });

    test('пересечения одного голоса складываются', () {
      final words = assignSpeakers(
        [const TimedWord(0, 1000, 'раз')],
        const [
          SpeakerTurn(0, 300, _a),
          SpeakerTurn(300, 700, _b),
          SpeakerTurn(700, 1000, _a),
        ],
      );
      expect(words.single.speaker, _a);
    });

    test('ничья — тот, кто начал раньше', () {
      final words = assignSpeakers(
        [const TimedWord(1000, 2000, 'раз')],
        const [SpeakerTurn(1500, 2500, _b), SpeakerTurn(500, 1500, _a)],
      );
      expect(words.single.speaker, _a);
    });

    test('нет пересечений — ближайший не дальше секунды, иначе null', () {
      const turns = [SpeakerTurn(0, 1000, _a), SpeakerTurn(5000, 6000, _b)];
      final near = assignSpeakers([const TimedWord(1800, 2000, 'да')], turns);
      expect(near.single.speaker, _a);
      final nearRight = assignSpeakers(
        [const TimedWord(4200, 4500, 'да')],
        turns,
      );
      expect(nearRight.single.speaker, _b);
      final far = assignSpeakers([const TimedWord(2500, 3000, 'да')], turns);
      expect(far.single.speaker, isNull);
    });

    test('слово в зоне перебивки помечается', () {
      final words = assignSpeakers(
        [
          const TimedWord(0, 1000, 'раз'),
          const TimedWord(1000, 2000, 'два'),
          const TimedWord(2000, 3000, 'три'),
        ],
        const [SpeakerTurn(0, 2500, _a), SpeakerTurn(1500, 4000, _b)],
      );
      expect(words.map((w) => w.overlap), [false, true, true]);
      expect(words.map((w) => w.speaker), [_a, _a, _b]);
    });

    test('маленький нахлёст — ещё не перебивка', () {
      final words = assignSpeakers(
        [const TimedWord(0, 1000, 'раз')],
        const [SpeakerTurn(0, 1000, _a), SpeakerTurn(900, 2000, _b)],
      );
      expect(words.single.overlap, isFalse);
    });

    test('слово нулевой длины не теряет голос', () {
      final words = assignSpeakers(
        [const TimedWord(500, 500, 'а')],
        const [SpeakerTurn(0, 1000, _b)],
      );
      expect(words.single.speaker, _b);
    });

    test('без разметки голосов нет ни у кого', () {
      final words = assignSpeakers([const TimedWord(0, 1, 'а')], const []);
      expect(words.single.speaker, isNull);
    });
  });

  test('fillUnassigned: к предыдущему, в начале — к следующему', () {
    final words = fillUnassigned(const [
      TimedWord(0, 1, 'а'),
      TimedWord(1, 2, 'б', speaker: _b),
      TimedWord(2, 3, 'в'),
      TimedWord(3, 4, 'г', speaker: _a),
    ]);
    expect(words.map((w) => w.speaker), [_b, _b, _b, _a]);
  });

  group('relabelTurns', () {
    test('метки по первому появлению', () {
      final turns = relabelTurns(const [
        SpeakerTurn(5000, 6000, '0'),
        SpeakerTurn(0, 1000, '3'),
        SpeakerTurn(2000, 3000, '1'),
        SpeakerTurn(7000, 8000, '3'),
      ]);
      expect(turns.map((t) => t.clusterId), ['S1', 'S2', 'S3', 'S1']);
      expect(turns.map((t) => t.fromMs), [0, 2000, 5000, 7000]);
    });

    test('перестановка номеров кластеров не меняет ответ', () {
      final random = math.Random(7);
      final base = <SpeakerTurn>[
        for (var i = 0; i < 40; i++)
          SpeakerTurn(i * 1000, i * 1000 + 800, '${random.nextInt(4)}'),
      ];
      final expected = relabelTurns(base);
      for (var round = 0; round < 10; round++) {
        final mapping = ['0', '1', '2', '3']..shuffle(random);
        final permuted = [
          for (final t in base)
            SpeakerTurn(t.fromMs, t.toMs, mapping[int.parse(t.clusterId)]),
        ]..shuffle(random);
        expect(relabelTurns(permuted), expected);
      }
    });
  });

  group('groupWords', () {
    test('разрез на смене голоса, конце предложения, паузе и длине', () {
      final groups = groupWords(const [
        TimedWord(0, 100, 'раз', speaker: _a),
        TimedWord(100, 200, 'два', speaker: _a),
        TimedWord(200, 300, 'три', speaker: _b),
        TimedWord(300, 400, 'четыре.', speaker: _b),
        TimedWord(400, 500, 'пять', speaker: _b),
        TimedWord(1500, 1600, 'шесть', speaker: _b),
      ]);
      expect(groups.map((g) => g.text), [
        'раз два',
        'три четыре.',
        'пять',
        'шесть',
      ]);
      expect(groups.map((g) => g.speaker), [_a, _b, _b, _b]);

      final long = groupWords([
        for (var i = 0; i < 30; i++) TimedWord(i * 100, i * 100 + 90, 'слово'),
      ]);
      expect(long.length, greaterThan(1));
      expect(long.every((g) => g.text.length < 100), isTrue);
    });

    test('перебивка — по первым словам фрагмента', () {
      final groups = groupWords(const [
        TimedWord(0, 100, 'раз', speaker: _a),
        TimedWord(100, 200, 'два', speaker: _b, overlap: true),
        TimedWord(200, 300, 'три', speaker: _b),
      ]);
      expect(groups.map((g) => g.overlap), [false, true]);
    });

    test('NeMo без голосов — символ в символ как до выноса', () {
      final random = math.Random(42);
      const vocabulary = [
        'привет',
        'как',
        'дела?',
        'хорошо.',
        'спасибо',
        'за',
        'просмотр.',
        'Продолжение',
        'следует…',
        'ну',
        'да',
        'и',
        'вот',
        'так!',
      ];
      for (var round = 0; round < 200; round++) {
        var at = 0;
        final words = <Map<String, Object>>[];
        final count = random.nextInt(60);
        for (var i = 0; i < count; i++) {
          at += random.nextInt(random.nextBool() ? 200 : 1500);
          final length = 50 + random.nextInt(500);
          words.add({
            'word': vocabulary[random.nextInt(vocabulary.length)],
            'start': at / 1000,
            'end': (at + length) / 1000,
          });
          at += length;
        }
        final json = jsonEncode({'language': 'ru', 'words': words});
        final old = _oldNemoGrouping([
          for (final w in words)
            Segment(
              ((w['start'] as num) * 1000).round(),
              ((w['end'] as num) * 1000).round(),
              w['word'] as String,
            ),
        ]);
        expect(_dump(parseNemoJson(json).segments), _dump(old));
      }
    });
  });

  group('smoothSingleWords', () {
    test('A A B A A — короткое B возвращается соседям', () {
      final words = smoothSingleWords(const [
        TimedWord(0, 300, 'раз', speaker: _a),
        TimedWord(300, 600, 'два', speaker: _a),
        TimedWord(600, 800, 'и', speaker: _b),
        TimedWord(800, 1100, 'три', speaker: _a),
        TimedWord(1100, 1400, 'четыре', speaker: _a),
      ]);
      expect(words.map((w) => w.speaker).toSet(), {_a});
    });

    test('длинное слово, перебивка и разные соседи остаются', () {
      final long = smoothSingleWords(const [
        TimedWord(0, 300, 'раз', speaker: _a),
        TimedWord(300, 900, 'длинное', speaker: _b),
        TimedWord(900, 1100, 'три', speaker: _a),
      ]);
      expect(long[1].speaker, _b);
      final overlap = smoothSingleWords(const [
        TimedWord(0, 300, 'раз', speaker: _a),
        TimedWord(300, 400, 'да', speaker: _b, overlap: true),
        TimedWord(400, 700, 'три', speaker: _a),
      ]);
      expect(overlap[1].speaker, _b);
      final edge = smoothSingleWords(const [
        TimedWord(0, 300, 'раз', speaker: _a),
        TimedWord(300, 400, 'да', speaker: _b),
        TimedWord(400, 700, 'три', speaker: 'S3'),
      ]);
      expect(edge[1].speaker, _b);
    });
  });

  group('voteBySentences', () {
    test('хвост прежнего голоса в начале предложения уходит новому', () {
      final words = voteBySentences(const [
        TimedWord(0, 300, 'где', speaker: _a),
        TimedWord(300, 600, 'льды.', speaker: _a),
        TimedWord(700, 800, 'В', speaker: _a),
        TimedWord(800, 1200, 'сарае', speaker: _b),
        TimedWord(1200, 1600, 'лампа.', speaker: _b),
      ]);
      expect(words.map((w) => w.speaker), [_a, _a, _b, _b, _b]);
    });

    test('предложение одного человека не рассыпается на куски', () {
      final words = voteBySentences(const [
        TimedWord(0, 300, 'Now', speaker: _b),
        TimedWord(300, 600, 'run', speaker: _b),
        TimedWord(600, 900, 'along', speaker: _a),
        TimedWord(900, 1200, 'and', speaker: _a),
        TimedWord(1200, 1500, 'tell', speaker: _a),
        TimedWord(1500, 1800, 'them', speaker: _a),
        TimedWord(1800, 2100, 'to', speaker: _b),
        TimedWord(2100, 2400, 'hurry.', speaker: _a),
      ]);
      expect(words.map((w) => w.speaker).toSet(), {_a});
    });

    test('настоящая перебивка посреди фразы остаётся', () {
      final words = voteBySentences([
        for (var i = 0; i < 6; i++) TimedWord(i * 500, i * 500 + 450, 'раз', speaker: _a),
        for (var i = 6; i < 10; i++) TimedWord(i * 500, i * 500 + 450, 'два', speaker: _b),
        const TimedWord(5000, 5400, 'три.', speaker: _a),
      ]);
      expect(words.where((w) => w.speaker == _b).length, 4);
    });

    test('слова в зоне перебивки уходят хозяину предложения, отметка остаётся', () {
      final words = voteBySentences(const [
        TimedWord(0, 400, 'стороны.', speaker: _a),
        TimedWord(400, 600, 'На', speaker: _a, overlap: true),
        TimedWord(600, 800, 'вопрос', speaker: _a, overlap: true),
        TimedWord(800, 1300, 'кальцией', speaker: _b),
        TimedWord(1300, 1800, 'здесь', speaker: _b),
        TimedWord(1800, 2300, 'Сарая.', speaker: _b),
      ]);
      expect(words.map((w) => w.speaker), [_a, _b, _b, _b, _b, _b]);
      expect(words[1].overlap, isTrue);
    });

    test('короткий ответ своим предложением — свой голос', () {
      final words = voteBySentences(const [
        TimedWord(0, 300, 'Готово?', speaker: _a),
        TimedWord(400, 600, 'Да.', speaker: _b),
      ]);
      expect(words.map((w) => w.speaker), [_a, _b]);
    });
  });

  group('timeWords', () {
    test('слова от движка совпали по числу — время как есть', () {
      final words = timeWords('Раз, два', 0, 1000, const [
        TimedWord(10, 400, 'раз,'),
        TimedWord(500, 990, 'два'),
      ]);
      expect(words.map((w) => (w.from, w.to, w.text)), [
        (10, 400, 'Раз,'),
        (500, 990, 'два'),
      ]);
    });

    test('без слов — по доле символов внутри фрагмента', () {
      final words = timeWords('аааа бббб', 1000, 2000);
      expect(words.first.from, 1000);
      expect(words.last.to, 2000);
      expect(words.last.from, inInclusiveRange(1450, 1600));
    });

    test('замена словаря сдвинула число слов — время по опорным словам', () {
      final words = timeWords('искусственный интеллект', 0, 4000, const [
        TimedWord(0, 1000, 'ии'),
        TimedWord(3000, 4000, 'ещё'),
      ]);
      expect(words.length, 2);
      expect(words.first.from, 0);
      expect(words.last.to, 4000);
    });
  });

  group('splitBySpeakers', () {
    test('режет по смене голоса и сохраняет замены словаря', () {
      const seg = Segment(
        0,
        3000,
        'привет ИИ. как дела',
        replacements: [
          TextReplacement(start: 7, end: 9, original: 'ии', replacement: 'ИИ'),
          TextReplacement(
            start: 15,
            end: 19,
            original: 'дила',
            replacement: 'дела',
          ),
        ],
      );
      final parts = splitBySpeakers(
        seg,
        const [SpeakerTurn(0, 1500, _a), SpeakerTurn(1500, 3000, _b)],
        const [
          TimedWord(0, 600, 'привет'),
          TimedWord(600, 1400, 'ии.'),
          TimedWord(1600, 2200, 'как'),
          TimedWord(2200, 3000, 'дила'),
        ],
      );
      expect(parts.map((p) => p.text), ['привет ИИ.', 'как дела']);
      expect(parts.map((p) => p.speaker), [_a, _b]);
      expect(parts.map((p) => (p.from, p.to)), [(0, 1400), (1600, 3000)]);
      expect(parts[0].replacements.single.start, 7);
      expect(parts[1].replacements.single.start, 4);
      expect(parts[1].undoReplacement(0).text, 'как дила');
    });

    test('один голос — фрагмент целиком', () {
      final parts = splitBySpeakers(
        const Segment(0, 1000, 'раз два'),
        const [SpeakerTurn(0, 1000, _a)],
      );
      expect(parts.single.text, 'раз два');
      expect(parts.single.speaker, _a);
    });
  });

  group('перенос голоса через правки', () {
    const seg = Segment(0, 1000, 'раз два', speaker: _b, overlap: true);

    test('applyCommands, applyVocabulary, undoReplacement', () {
      final commanded = seg.applyCommands(const [
        TextCommand('два', '2'),
      ]);
      expect(commanded.text, 'раз 2');
      expect(commanded.speaker, _b);
      expect(commanded.overlap, isTrue);

      final vocab = seg.applyVocabulary(const [
        VocabularyItem(id: 'v', phrase: 'раз', replacement: 'один'),
      ]);
      expect(vocab.speaker, _b);
      expect(vocab.overlap, isTrue);

      final undone = vocab.undoReplacement(0);
      expect(undone.text, 'раз два');
      expect(undone.speaker, _b);
      expect(undone.overlap, isTrue);
    });

    test('Transcript.applyVocabulary хранит голоса и список', () {
      const t = Transcript(
        'ru',
        [seg],
        speakers: [
          SpeakerInfo(id: _a, name: 'Иван'),
          SpeakerInfo(id: _b, name: 'Мария'),
        ],
      );
      final changed = t.applyVocabulary(const [
        VocabularyItem(id: 'v', phrase: 'раз', replacement: 'один'),
      ]);
      expect(changed.segments.single.speaker, _b);
      expect(changed.segments.single.overlap, isTrue);
      expect(changed.speakers.map((s) => s.name), ['Иван', 'Мария']);
    });

    test('collapseRepeats не схлопывает повторы разных голосов', () {
      final same = collapseRepeats(const [
        Segment(0, 1, 'Да.', speaker: _a),
        Segment(1, 2, 'Да.', speaker: _a),
        Segment(2, 3, 'Да.', speaker: _a),
      ]);
      expect(same.single.speaker, _a);
      expect((same.single.from, same.single.to), (0, 3));

      final different = collapseRepeats(const [
        Segment(0, 1, 'Да.', speaker: _a),
        Segment(1, 2, 'Да.', speaker: _b),
        Segment(2, 3, 'Да.', speaker: 'S3'),
      ]);
      expect(different.length, 3);
    });

    test('Job.replaceSegment хранит голоса и список', () {
      const t = Transcript(
        'ru',
        [seg],
        speakers: [
          SpeakerInfo(id: _a, name: 'Иван'),
          SpeakerInfo(id: _b, name: 'Мария'),
        ],
      );
      final job = Job(File('/x.wav'), transcript: t);
      final current = job.segments.single;
      final changed = job.replaceSegment(
        current,
        current.withText('раз три', const []),
      );
      expect(changed.transcript!.segments.single.speaker, _b);
      expect(changed.transcript!.segments.single.overlap, isTrue);
      expect(changed.transcript!.speakers.length, 2);
    });
  });

  group('список голосов', () {
    test('статистика, реплики и сохранение имён', () {
      final roster = speakerRoster(
        [
          (from: 0, to: 1000, speaker: _a),
          (from: 1000, to: 1500, speaker: _a),
          (from: 1500, to: 4000, speaker: _b),
          (from: 4000, to: 5000, speaker: _a),
        ],
        previous: const [SpeakerInfo(id: _b, name: 'Мария', colorIndex: 0)],
      );
      expect(roster.map((s) => s.id), [_a, _b]);
      expect(roster[0].name, 'Голос 1');
      expect(roster[0].talkMs, 2500);
      expect(roster[0].turns, 2);
      expect((roster[0].firstMs, roster[0].lastMs), (0, 5000));
      expect(roster[1].name, 'Мария');
      expect(roster[1].colorIndex, 0);
      expect(roster[0].colorIndex, 1);
    });

    test('один голос — разметка снимается целиком', () {
      final t = finishSpeakers(
        const Transcript('ru', [
          Segment(0, 1000, 'раз', speaker: _a, overlap: true),
          Segment(1000, 2000, 'два', speaker: _a),
        ]),
      );
      expect(t.speakers, isEmpty);
      expect(t.segments.every((s) => s.speaker == null && !s.overlap), isTrue);
    });

    test('перебивка по времени: начало раньше конца чужой реплики', () {
      final t = finishSpeakers(
        const Transcript('ru', [
          Segment(0, 3000, 'раз', speaker: _a),
          Segment(2500, 4000, 'два', speaker: _b),
          Segment(3950, 5000, 'три', speaker: _a),
        ]),
      );
      expect(t.segments.map((s) => s.overlap), [false, true, false]);
    });
  });

  group('looksFragmented', () {
    SpeakerInfo voice(int n, int talkMs) =>
        SpeakerInfo(id: 'S$n', name: 'Голос $n', talkMs: talkMs);

    test('короткая запись с тремя голосами — не осколки', () {
      expect(
        looksFragmented([voice(1, 10000), voice(2, 10000), voice(3, 10000)]),
        isFalse,
      );
    });

    test('много мелких меток — осколки', () {
      expect(
        looksFragmented([
          voice(1, 600000),
          voice(2, 500000),
          for (var i = 3; i < 20; i++) voice(i, 3000),
        ]),
        isTrue,
      );
    });

    test('обычная встреча с одним молчуном — не осколки', () {
      expect(
        looksFragmented([
          voice(1, 900000),
          voice(2, 700000),
          voice(3, 400000),
          voice(4, 15000),
        ]),
        isFalse,
      );
    });

    test('двух голосов для осколков мало', () {
      expect(looksFragmented([voice(1, 900000), voice(2, 1000)]), isFalse);
    });
  });

  group('whisper с голосами', () {
    test('полный JSON: слова из токенов, разрез на смене голоса', () {
      Map<String, Object> token(String text, int from, int to) => {
        'text': text,
        'offsets': {'from': from, 'to': to},
      };
      final json = jsonEncode({
        'result': {'language': 'ru'},
        'transcription': [
          {
            'offsets': {'from': 0, 'to': 4000},
            'text': ' Привет, как дела? Хорошо.',
            'tokens': [
              token('[_BEG_]', 0, 0),
              token(' При', 0, 300),
              token('вет', 300, 600),
              token(',', 600, 650),
              token(' как', 700, 1000),
              token(' дела', 1000, 1500),
              token('?', 1500, 1550),
              token(' Хоро', 2500, 3000),
              token('шо', 3000, 3500),
              token('.', 3500, 3600),
              token('[_TT_200]', 4000, 4000),
            ],
          },
        ],
      });
      final t = parseWhisperJson(
        json,
        turns: const [SpeakerTurn(0, 1800, _a), SpeakerTurn(2200, 4000, _b)],
      );
      expect(t.segments.map((s) => s.text), [
        'Привет, как дела?',
        'Хорошо.',
      ]);
      expect(t.segments.map((s) => s.speaker), [_a, _b]);
      expect(t.speakers.length, 2);

      // Без разметки — ровно прежний разбор.
      final plain = parseWhisperJson(json);
      expect(plain.segments.single.text, 'Привет, как дела? Хорошо.');
      expect(plain.segments.single.speaker, isNull);
      expect(plain.speakers, isEmpty);
    });

    test('ключ полного JSON при включённом режиме', () {
      const o = RunOptions(model: '/m.bin', lang: 'ru', threads: 4);
      expect(buildArgs(o, '/a.wav', '/out'), contains('-oj'));
      expect(buildArgs(o, '/a.wav', '/out'), isNot(contains('-ojf')));
      final on = buildArgs(o.copyWith(diarize: true), '/a.wav', '/out');
      expect(on, contains('-ojf'));
      expect(on, isNot(contains('-oj')));
    });

    test('RunOptions читает старый файл настроек', () {
      const fallback = RunOptions(model: '/m.bin', lang: 'ru', threads: 4);
      final old = RunOptions.fromJson({'model': '/x.bin'}, fallback);
      expect(old.diarize, isFalse);
      expect(old.speakerCount, 0);
      final saved = RunOptions.fromJson(
        fallback.copyWith(diarize: true, speakerCount: 3).toJson(),
        fallback,
      );
      expect(saved.diarize, isTrue);
      expect(saved.speakerCount, 3);
    });
  });
}
