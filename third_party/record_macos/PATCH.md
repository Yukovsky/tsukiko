# record_macos 2.1.1 — local patch

Upstream: https://pub.dev/packages/record_macos/versions/2.1.1 (BSD-3, see LICENSE).

Only `macos/record_macos/Sources/record_macos/delegate/RecorderStreamDelegate.swift` differs:
`setVoiceProcessingEnabled` is called in `start()` / `stop()` only when echo cancel or auto gain was requested.
tsukiko always passes both as false, so the call is dropped entirely.

Why (trigger suspected, not proven — the stuck state was observed, not reproduced): after thousands of stream restarts the app was found with `AVAudioIOUnit` spinning in
`IOUnitPropertyListener → _GetHWFormat` (30% CPU, `coreaudiod` 75%), malloc growing by ~100 MB/min,
and `Recorder.startStream` blocked forever in `inputFormat(forBus:)`. The plugin has a single shared
serial queue, so one stuck call blocks every later recorder call.

Drop this directory and the `dependency_overrides` entry when upstream no longer needs it.
