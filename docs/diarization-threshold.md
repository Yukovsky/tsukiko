# Diarization: embedder and threshold

The clustering threshold of `FastClusteringConfig` is a distance in the space of one particular
embedder. A value tuned for one embedder means something else for another, and the optimum also
depends on the recording. The value from the sherpa-onnx example (0.5) is tuned for a Chinese
3D-Speaker embedder and over-splits meetings (YazSes measured 86 "speakers" instead of 4 on AMI).
So the defaults in `DiarizationModels` come from measurement with `tool/diarize_probe.dart`, not from
the example.

## Status

**Provisional.** The only real multi-speaker recording measured so far is
`0-four-speakers-zh.wav` from the sherpa-onnx `speaker-segmentation-models` release (Chinese,
4 speakers, 56.9 s). No Russian benchmark with ground truth was found. The defaults must be
re-checked on 3–5 real Russian recordings (2, 3 and 4 voices, at least one with interruptions,
3–10 minutes each, with a hand-made RTTM) before they are treated as final. The probe reads
`<name>.rttm` next to each WAV and prints a frame-level DER.

## Setup

- Segmentation: `sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx` (archive SHA-256
  `24615ee8…6488`, MIT, `LICENSE` inside the archive).
- `minDurationOn` 0.3 s, `minDurationOff` 0.5 s, `windowShiftRatio` 0.1, 4 threads.
- Machine: Linux x64 cloud container, 4 cores, `sherpa_onnx_linux` 1.13.8.

```sh
dart run tool/diarize_probe.dart \
    --lib ~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
    --segmentation models/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx \
    --embedder models/nemo_en_titanet_small.onnx \
    --embedder models/wespeaker_en_voxceleb_resnet34_LM.onnx \
    --embedder models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx \
    --from 0.4 --to 2.0 --step 0.1 0-four-speakers-zh.wav
```

## Results: `0-four-speakers-zh.wav` (4 speakers)

Number of voices found per threshold (`*` — correct; `!` — the "fragmented" warning fired):

| Threshold | TitaNet-S | WeSpeaker ResNet34 | 3D-Speaker ERes2Net |
| ---: | :---: | :---: | :---: |
| 0.05 | | 9 ! | |
| 0.10 | | 7 ! | |
| 0.20 | | 7 ! | |
| 0.25 | | 4 * | |
| 0.30 | | 4 * | |
| 0.35 | | 4 * | |
| 0.40 | 8 ! | 2 | 8 ! |
| 0.50 | 7 ! | 2 | 7 ! |
| 0.60 | 7 ! | 1 | 6 ! |
| 0.70 | 4 * | 1 | 6 ! |
| 0.80 | 4 * | 1 | 5 |
| 0.90 | 4 * | 1 | 4 * |
| 1.00 | 3 | 1 | 3 |
| 1.10 | 2 | 1 | 2 |
| 1.20 – 2.00 | 1 | 1 | 1 |

Speed (real-time factor, 4 threads): TitaNet-S 0.07, WeSpeaker 0.08–0.11, ERes2Net 0.10–0.16.
That is about 4–7 s for this minute of audio, roughly 4–10 minutes for an hour.

With `numClusters = 4` TitaNet-S returns exactly 4 voices.

## Chosen defaults

| Embedder | Default | Why |
| :--- | ---: | :--- |
| **TitaNet-S** (default) | 0.8 | Widest correct plateau (0.7–0.9), fastest. License: "covered by the license of the NeMo Toolkit" per the NGC model card → Apache-2.0. |
| WeSpeaker ResNet34-LM | 0.3 | Middle of 0.25–0.35; its space is compressed, everything merges into two voices already at 0.4. CC BY 4.0 (VoxCeleb). |
| 3D-Speaker ERes2Net base | 0.9 | Correct only at exactly 0.9 — the narrow window YazSes also observed for this embedder. |

The embedder is chosen in Settings → Transcriber. A per-machine threshold can be set by hand with
the `diarizationThreshold` key in `settings.json`.

## Synthetic Russian check (smoke only)

A 49 s "dialogue" was assembled from the Russian test fixtures and pitch-shifted copies of them
(ffmpeg `asetrate`), with one 0.8 s overlap and a known RTTM. Every embedder at every threshold
from 0.2 to 1.3 found **one** voice (DER 0.554 — exactly the share of the second "voice"); even with
`numClusters = 2` the result was one voice. Pitch-shifting one TTS voice does not create a
different speaker for an embedder. This confirms that synthetic data (including `say` voices) is
good only as a smoke test for the pipeline, not as evidence for the threshold.

## Open questions

1. Real Russian recordings with ground truth (see Status).
2. Whether `windowShiftRatio` 0.2 keeps quality on hour-long recordings while halving the time.
3. Timing on the target macOS and Windows machines; the numbers above are from Linux x64.
