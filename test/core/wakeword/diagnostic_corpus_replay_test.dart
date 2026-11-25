import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/wakeword/keyword_tokenizer.dart';
import 'package:tsukiko/core/wakeword/personal_keyword_spotter.dart';
import 'package:tsukiko/core/wakeword/speaker_profile.dart';
import 'package:tsukiko/core/wakeword/speech_verifier.dart';

// Opt-in, local corpus audit. WAVs and reports never enter the repository.
// TSUKIKO_WAKE_CORPUS=<diagnostics directory>
// TSUKIKO_WAKE_REPORT=<output JSON>
// TSUKIKO_WAKE_PROFILE_DIR=<support directory, for legacy sessions>
// TSUKIKO_WAKE_VERIFY=1 replays the whisper second stage as well
// TSUKIKO_WAKE_VERIFY_MODEL=<ggml file> picks the verifier model
// Optional expectations.json in the corpus:
// [{"session":"...","mode":"wake","from":1,"to":3,"detected":true}]
String _sherpaLibraryDir() {
  final configFile = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(configFile.readAsStringSync())
              as Map<String, dynamic>)['packages']
          as List<dynamic>;
  final macos = packages.cast<Map<String, dynamic>>().firstWhere(
    (entry) => entry['name'] == 'sherpa_onnx_macos',
  );
  return '${configFile.uri.resolve(macos['rootUri'] as String).toFilePath()}/macos';
}

void main() {
  final corpus = Platform.environment['TSUKIKO_WAKE_CORPUS'];
  final verifier = Platform.environment['TSUKIKO_WAKE_VERIFY'] == '1'
      ? SpeechVerifier(
          customModelPath: Platform.environment['TSUKIKO_WAKE_VERIFY_MODEL'],
          sherpaLibraryDir: _sherpaLibraryDir(),
        )
      : null;
  test(
    'replay every diagnostic WAV from first to last PCM sample',
    () async {
      final directories =
          Directory(corpus!)
              .listSync()
              .whereType<Directory>()
              .where((dir) => File('${dir.path}/metadata.json').existsSync())
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(directories, isNotEmpty);
      final legacyProfiles = <SpeakerProfile>[];
      final profileDir = Platform.environment['TSUKIKO_WAKE_PROFILE_DIR'];
      if (profileDir != null) {
        for (final file in [
          File('$profileDir/speaker_profile.json'),
          if (Directory('$profileDir/backups').existsSync())
            ...Directory('$profileDir/backups').listSync().whereType<File>(),
        ]) {
          final profile = SpeakerProfile.load(file.path);
          if (profile != null) legacyProfiles.add(profile);
        }
      }
      bool sameWord(String a, String b) =>
          KeywordTokenizer.normalizeKeywordText(a) ==
          KeywordTokenizer.normalizeKeywordText(b);
      final results = <Map<String, Object?>>[];
      for (final dir in directories) {
        final metadata =
            jsonDecode(File('${dir.path}/metadata.json').readAsStringSync())
                as Map<String, dynamic>;
        final wakeWord = metadata['wakeWord'] as String;
        final closeWord = metadata['closeWord'] as String;
        final snapshot = SpeakerProfile.load('${dir.path}/profile.json');
        SpeakerProfile? profile = snapshot;
        profile ??= legacyProfiles
            .where((p) => sameWord(p.wakeWord, wakeWord))
            .firstOrNull;
        final wakeComparable =
            profile != null &&
            sameWord(profile.wakeWord, wakeWord) &&
            profile.wakeTemplates.length >= 3;
        final closeComparable =
            profile != null &&
            sameWord(profile.closeWord, closeWord) &&
            profile.closeTemplates.length >= 3;
        final bytes = File('${dir.path}/audio.wav').readAsBytesSync();
        final pcm = ByteData.sublistView(bytes);
        expect(bytes.length, greaterThanOrEqualTo(44));
        expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
        expect(ascii.decode(bytes.sublist(36, 40)), 'data');
        expect(pcm.getUint16(20, Endian.little), 1); // PCM
        expect(pcm.getUint16(22, Endian.little), 1); // mono
        expect(pcm.getUint32(24, Endian.little), 16000);
        expect(pcm.getUint16(34, Endian.little), 16);
        expect((bytes.length - 44) % 2, 0);
        // The header may lag up to ten seconds after an interrupted recording.
        final sampleCount = (bytes.length - 44) ~/ 2;
        final detections = {'wake': <double>[], 'close': <double>[]};
        final scores = <Map<String, Object?>>[];
        final detectors = <String, PersonalKeywordSpotter>{};
        var seconds = 0.0;
        final candidates = <(String, double, KeywordCandidate)>[];
        // TSUKIKO_WAKE_VERIFY_MODEL forces the whisper path for comparison.
        if (Platform.environment['TSUKIKO_WAKE_VERIFY_MODEL'] == null) {
          await verifier?.prepare(wakeWord: wakeWord, closeWord: closeWord);
        }
        if (profile != null) {
          for (final mode in ['wake', 'close']) {
            if (mode == 'wake' ? !wakeComparable : !closeComparable) continue;
            detectors[mode] =
                PersonalKeywordSpotter(
                    wakeWord: wakeWord,
                    closeWord: closeWord,
                    wakeTemplates: wakeComparable
                        ? profile.wakeTemplates
                        : const [],
                    closeTemplates: closeComparable
                        ? profile.closeTemplates
                        : const [],
                    wakeNegatives: wakeComparable
                        ? profile.wakeNegatives
                        : const [],
                    closeNegatives: closeComparable
                        ? profile.closeNegatives
                        : const [],
                  )
                  ..listenForClose = mode == 'close'
                  ..proposeCandidates = verifier != null
                  ..onScore = (score) {
                    if (score.wakeReason != null ||
                        (score.closeReason != null &&
                            score.closeReason != 'awaiting_boundary')) {
                      scores.add({
                        'seconds': seconds,
                        'mode': mode,
                        ...score.toJson(),
                      });
                    }
                  };
          }
        }
        // Independent classifiers: old recording state transitions must not
        // suppress words that the new algorithm detects at a different time.
        for (var at = 0; at < sampleCount; at += 1600) {
          final end = (at + 1600).clamp(0, sampleCount);
          seconds = end / 16000;
          final chunk = Float32List(end - at);
          for (var i = 0; i < chunk.length; i++) {
            chunk[i] = pcm.getInt16(44 + (at + i) * 2, Endian.little) / 32768;
          }
          for (final entry in detectors.entries) {
            entry.value.acceptAudio(chunk);
            if (verifier != null) {
              final candidate = entry.value.takeCandidate();
              if (candidate != null) {
                candidates.add((entry.key, seconds, candidate));
              }
            } else if (entry.value.takeDetection() != null) {
              detections[entry.key]!.add(seconds);
            }
          }
        }
        for (final (mode, at, candidate) in candidates) {
          final confirmed = await verifier!.confirmKeyword(
            candidate.audio,
            mode == 'close' ? closeWord : wakeWord,
            isClose: mode == 'close',
            spellings:
                (mode == 'close'
                    ? profile?.closeSpellings
                    : profile?.wakeSpellings) ??
                const [],
          );
          if (confirmed ?? candidate.strict) detections[mode]!.add(at);
        }
        final events = File('${dir.path}/events.jsonl')
            .readAsLinesSync()
            .where((line) => line.trim().isNotEmpty)
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
        final marks = <String, Object?>{};
        for (final mode in ['wake', 'close']) {
          final marked = events.where(
            (e) => e['type'] == 'mark' && e['word'] == mode,
          );
          marks[mode] = {
            'total': marked.length,
            'matched': detectors.containsKey(mode)
                ? marked
                      .where(
                        (e) => detections[mode]!.any(
                          (at) =>
                              at >= (e['seconds'] as num) - 0.5 &&
                              at <= (e['seconds'] as num) + 1.8,
                        ),
                      )
                      .length
                : null,
          };
        }
        results.add({
          'session': dir.uri.pathSegments.where((p) => p.isNotEmpty).last,
          'version': metadata['version'],
          'seconds': sampleCount / 16000,
          'samplesProcessed': sampleCount,
          'profileSource': snapshot != null
              ? 'snapshot'
              : profile != null
              ? 'legacy_same_word_not_original'
              : 'missing',
          'wakeComparable': wakeComparable,
          'closeComparable': closeComparable,
          'marks': marks,
          'detections': detections,
          'originalTriggers': {
            for (final mode in ['wake', 'close'])
              mode: events
                  .where((e) => e['type'] == '${mode}_triggered')
                  .map((e) => e['seconds'])
                  .toList(),
          },
          'scores': scores,
        });
      }
      final report = Platform.environment['TSUKIKO_WAKE_REPORT'];
      expect(report, isNotNull, reason: 'provide an output path for the audit');
      File(report!).parent.createSync(recursive: true);
      File(report).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'formatVersion': 1,
          'markToleranceSeconds': [-0.5, 1.8],
          'sessions': results,
        }),
      );
      final expectationsFile = File('$corpus/expectations.json');
      if (expectationsFile.existsSync()) {
        final expectations =
            jsonDecode(expectationsFile.readAsStringSync()) as List;
        for (final expected in expectations.cast<Map<String, dynamic>>()) {
          final result = results.singleWhere(
            (r) => r['session'] == expected['session'],
          );
          expect(result['${expected['mode']}Comparable'], isTrue);
          final detections = result['detections'] as Map<String, List<double>>;
          final found = detections[expected['mode']]!.any(
            (at) =>
                at >= (expected['from'] as num) &&
                at <= (expected['to'] as num),
          );
          expect(found, expected['detected'], reason: jsonEncode(expected));
        }
      }
    },
    skip: corpus == null,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
