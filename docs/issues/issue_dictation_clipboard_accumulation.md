# Issue: Clipboard Accumulates Sequential Dictations When Queued Without Idle

**Type**: Bug / Unexpected Behavior  
**Platform**: Cross-platform (Dart / Flutter)  
**Component**: Dictation Cubit (`lib/features/dictation/dictation_cubit.dart`)  
**Introduced In**: Commit `ed55b44` (*"feat(dictation): queue recordings independently of transcription"*)  
**Status**: Investigated / Documented  

---

## 1. Description

When the user dictates multiple audio segments in sequence where a second (or third) dictation is started while the previous dictation is still transcribing:
- Dictation #1 finishes transcribing and its text is copied to the clipboard. The user pastes it into an application, and it pastes correctly.
- Dictation #2 finishes transcribing.
- **Expected Behavior**: The clipboard should contain **only** Dictation #2 (`"Text 2"`), because Dictation #2 is an independent utterance and Dictation #1 was already delivered.
- **Actual Behavior**: The clipboard contains **both** Dictation #1 and Dictation #2 concatenated with a newline (`"Text 1\nText 2"`).
- If Dictation #3 is started before #2 completes, it concatenates all three: `"Text 1\nText 2\nText 3"`.

This behavior occurs whenever dictation is set to copy to clipboard (`insert == false` in settings) or when insertion fails and falls back to clipboard copy.

---

## 2. Reproduction Steps

1. Configure Tsukiko dictation to copy text to clipboard (`_settings.insert == false`).
2. Press the dictation hotkey and speak Phrase 1 (e.g., *"Привет, как дела"*).
3. Release the hotkey to stop recording. Phrase 1 enters transcription (`Phase.transcribing`).
4. **While Phrase 1 is still transcribing**, immediately press the hotkey again and speak Phrase 2 (e.g., *"Давай встретимся завтра"*).
5. Stop recording Phrase 2.
6. Phrase 1 finishes transcribing:
   - Tsukiko copies Phrase 1 to the clipboard.
   - User pastes into an editor: *"Привет, как дела"* is pasted.
7. Phrase 2 finishes transcribing:
   - Tsukiko copies result to clipboard.
   - User pastes into an editor:
     ```
     Привет, как дела
     Давай встретимся завтра
     ```
8. **Result**: Phrase 1 is duplicated in the clipboard alongside Phrase 2.

---

## 3. Technical Root Cause Analysis

In commit `ed55b44ee4cf2f1840f04f046c887abdfef4926f`, the author added a job queue (`_pending`) to allow starting new recordings while previous ones were still transcribing.

Let's examine `lib/features/dictation/dictation_cubit.dart`:

### 1. State Phase Logic
```dart
// lib/features/dictation/dictation_cubit.dart:248-249
Phase get _restingPhase =>
    _active != null || _pending.isNotEmpty ? Phase.transcribing : Phase.idle;
```

When Phrase 1 is transcribing:
- `_active != null`, so `_restingPhase == Phase.transcribing`.
- `state.phase` is `Phase.transcribing`.

### 2. Clearing of `_clipboardResults`
In `start()`:
```dart
// lib/features/dictation/dictation_cubit.dart:597-600
Future<void> start({bool startedByVoice = false}) async {
  if (_finishingRecording != null) await _finishingRecording;
  if (isClosed || state.recording || _startingRecording != null) return;
  if (state.phase == Phase.idle) _clipboardResults = '';
  ...
```
Notice line 600:
```dart
if (state.phase == Phase.idle) _clipboardResults = '';
```
Because Phrase 1 was transcribing when Phrase 2 started recording, `state.phase` was `Phase.transcribing` (**NOT** `Phase.idle`).
Therefore, **`_clipboardResults` was never reset to empty**!

### 3. Result Concatenation in `_copyResult`
When each job finishes, `_copyResult` is called:
```dart
// lib/features/dictation/dictation_cubit.dart:1029-1035
Future<void> _copyResult(String text) async {
  _clipboardResults = _clipboardResults.isEmpty
      ? text
      : '$_clipboardResults\n$text';
  _emit(state.copyWith(last: _clipboardResults));
  await bridge.copyText(_clipboardResults);
}
```

Timeline breakdown:
| Step | Action | `state.phase` | `_clipboardResults` | Text Copied to System Clipboard |
|---|---|---|---|---|
| 1 | Idle state | `Phase.idle` | `""` | None |
| 2 | Start Phrase 1 | `Phase.recording` | `""` (cleared because idle) | None |
| 3 | Stop Phrase 1 | `Phase.transcribing` | `""` | None |
| 4 | Start Phrase 2 (while #1 transcribes) | `Phase.recording` | `""` (**not** cleared because phase was `transcribing`) | None |
| 5 | Phrase 1 completes | `Phase.recording` | `"Text 1"` | `"Text 1"` |
| 6 | Stop Phrase 2 | `Phase.transcribing` | `"Text 1"` | None |
| 7 | Phrase 2 completes | `Phase.idle` | `"Text 1\nText 2"` | **`"Text 1\nText 2"`** |

Furthermore, `state.copyWith(last: _clipboardResults)` stores the concatenated string into `state.last`, so calling `copyLast()` also copies the entire accumulated backlog rather than the last phrase uttered.

### Why Did the Original Author Write It This Way?
In line 1097 of `dictation_cubit.dart`:
```dart
/// Copies one transcript, rather than the accumulated clipboard queue.
/// NativeBridge serializes this operation with automatic pastes.
Future<bool> copyEntry(String id) async { ... }
```
The original author assumed that if someone dictates multiple phrases quickly without returning to idle, they might want all phrases appended together into one clipboard block.

However, in actual daily use:
1. Every dictation activation represents a discrete utterance.
2. If the user dictates a sentence, pastes it, and then dictates another sentence while the system is under load, they do not want their previously pasted sentence prepended to the new one.
3. There is no user preference or visual indication that clipboard concatenation is occurring.

---

## 4. Proposed Solution

### Solution A: Copy Individual Segments (Recommended)
Each dictation job should only deliver its own transcribed text to the clipboard:

```dart
// lib/features/dictation/dictation_cubit.dart:1029-1035
Future<void> _copyResult(String text) async {
  _emit(state.copyWith(last: text));
  await bridge.copyText(text);
}
```

And in `start()`:
```dart
// lib/features/dictation/dictation_cubit.dart:600
// Reset clipboard accumulator on every new recording start, or eliminate _clipboardResults entirely.
_clipboardResults = '';
```

### Solution B: Make Queue Accumulation an Explicit Setting (Optional Alternative)
If the project maintainer wishes to retain queue concatenation as a feature:
1. Add a setting to `DictationSettings`:
   ```dart
   final bool accumulateClipboard; // default: false
   ```
2. When `accumulateClipboard == true`, retain the `\n` join behavior.
3. When `accumulateClipboard == false` (default), only copy the current segment.

---

## 5. Verification Checklist

- [ ] Set dictation output to clipboard mode.
- [ ] Record utterance 1: *"Alpha"*.
- [ ] Immediately while transcribing, record utterance 2: *"Beta"*.
- [ ] Wait for utterance 1 to finish. Paste clipboard -> should contain only *"Alpha"*.
- [ ] Wait for utterance 2 to finish. Paste clipboard -> should contain only *"Beta"*, not *"Alpha\nBeta"*.
- [ ] Verify `state.last` correctly reflects only the most recent transcript.
- [ ] Run unit tests in `test/` to ensure no regression in queue processing.
