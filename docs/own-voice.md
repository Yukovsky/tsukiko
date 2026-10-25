# Dictation: "Only my voice" and "Record a conversation"

## Only my voice

Before a dictated phrase goes to recognition, speech that does not sound like the owner is
dropped — a colleague, the TV, the other side of a call. It is the inverse of speaker labels: in
dictation people ask for this (e.g. VoiceInk #954 "Speaker lock"), not for "Voice 1 / Voice 2".

Pipeline (`lib/core/diarization/own_voice.dart`, runs in `Isolate.run`):

1. Once, the user reads a short text aloud (~20 s). Silero VAD keeps the speech, it is cut into
   3 s windows, TitaNet-S embeds each window, the normalized mean is the voice print
   (`own_voice.json` in the support folder; deleted with one button).
2. Per phrase: Silero VAD splits it into speech pieces; pieces ≥ 0.7 s get an embedding and a
   cosine score against the print; below the threshold they are replaced with silence (not cut,
   so timing and pauses stay). Shorter pieces follow the nearest judged neighbour. If nothing can
   be judged (a lone "yes"), the phrase is kept — losing your own words is worse than letting a
   stray word in. Any failure falls back to the unfiltered phrase.
3. If nothing of the owner is left, nothing is inserted and the HUD says why.

Models: TitaNet-S (shared with speaker labels in the queue) and `silero_vad.onnx` (the same file
voice activation uses), both SHA-256 pinned (`own_voice_models.dart`).

### Threshold measurement

`tool/own_voice_probe.dart` on 28 real speakers (14 Russian, 14 English, VoxForge): print from
5 utterances (~20 s), then every piece of speech of the remaining utterances of every speaker of
the same language scored against every print.

| Threshold | Own speech dropped | Foreign speech passed |
| ---: | ---: | ---: |
| 0.35 (Lenient) | 0.0 % | 8.8 % |
| 0.40 | 0.0 % | 4.0 % |
| **0.45 (Normal, default)** | **0.5 %** | **1.8 %** |
| 0.50 | 0.8 % | 0.9 % |
| 0.55 (Strict) | 1.9 % | 0.1 % |
| 0.60 | 3.7 % | 0.0 % |

Mixed phrases (own utterance, pause, another speaker's utterance): split correctly in 28 of 28 at
0.45. Self-similarity of the enrollment windows: min 0.65, median 0.88.

Caveat: every VoxForge speaker used their own microphone, which makes voices easier to separate
than two people in one room on one laptop mic. Re-check on real recordings; "Strict"/"Lenient"
in Settings move the threshold by ±0.1.

## Record a conversation

A button in the menu-bar panel records with the dictation microphone, but on stop the audio is
not recognized there and not pasted: it is moved to the library (`Разговоры/`) and handed to the
main window queue with "Multiple voices" on for that job (`ConversationReceived`). The panel and
the main window are isolates of one process; the queue registers a `ReceivePort` under
`conversationInboxPort` in `IsolateNameServer`, the panel looks it up and sends the path. If the
queue does not answer, the file stays in the library and the panel says so.

The dictation model is not loaded or held during a conversation (it can last an hour; the queue
transcribes it with its own model). Dictation hotkeys are ignored while a conversation records, so
a stray press does not cut it; the cancel hotkey still works.
