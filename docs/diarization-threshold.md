# Diarization: embedder, threshold, languages

The clustering threshold of `FastClusteringConfig` is a distance in the space of one particular
embedder. A value tuned for one embedder means something else for another, and the optimum also
depends on the recording. The value from the sherpa-onnx example (0.5) is tuned for a Chinese
3D-Speaker embedder and over-splits meetings (YazSes measured 86 "speakers" instead of 4 on AMI).
The defaults in `DiarizationModels` therefore come from measurements with `tool/diarize_probe.dart`.

## Do the embedders depend on the language?

No. They model the voice, not the words, and the measurements below show no penalty for Russian:
on the Russian recordings the error was as low as or lower than on the English ones (best frame
error 0.07–0.10 on Russian, 0.24–0.35 on English). TitaNet-S (NeMo, English training data) and
ERes2Net (3D-Speaker, Chinese training data) both worked on Russian and English. The recognition
model is independent of this step: any Whisper (tiny … large-v3) and both NeMo models get voices
the same way.

## Test set

All audio is real speech of real, different people; none of it is synthetic.

| File | Speakers | Length | Source |
| :--- | :---: | ---: | :--- |
| `ru_2a`, `ru_2b` | 2 | 148 s, 175 s | VoxForge Russian, 4 different speakers |
| `ru_3` | 3 | 184 s | VoxForge Russian |
| `ru_4` | 4 | 321 s | VoxForge Russian |
| `en_2a`, `en_2b` | 2 | 80 s, 115 s | VoxForge English |
| `en_3` | 3 | 143 s | VoxForge English |
| `en_4` | 4 | 147 s | VoxForge English |
| `en_ami_ES2004a` | 4 | 17.5 min | AMI meeting corpus, headset mix (CC BY 4.0), reference RTTM from `pyannote/AMI-diarization-setup` |
| `0-four-speakers-zh` | 4 | 57 s | sherpa-onnx test file (earlier measurement) |

The VoxForge "conversations" are assembled from per-speaker read utterances (loudness-normalized,
0.15–0.8 s gaps, ~18 % of turns start 0.6–1.2 s before the previous one ends) with an exact RTTM.
Caveat: every speaker recorded with their own microphone, which makes them easier to tell apart
than people in one room — that is what the AMI meeting is for. No Russian meeting with ground truth
was available; real Russian meetings remain the main open check.

Error is the frame-level diarization error (10 ms frames, no collar, overlaps counted), computed by
the probe. Values ≥ 1.0 mean the mapping could not be computed (more than 8 voices found).

## Results: voices found / expected and error, per threshold

### TitaNet-S (default, RTF 0.08–0.16 on 4 threads)

| thr | ru_2a | ru_2b | ru_3 | ru_4 | en_2a | en_2b | en_3 | en_4 | AMI | correct | mean err |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | :---: | ---: |
| 0.7 | 2/2 .10 | 4/2 .33 | 4/3 .41 | 5/4 .08 | 2/2 .35 | 3/2 .38 | 5/3 .35 | 6/4 .40 | 31/4 | 2/9 | 0.38 |
| 0.8 | 2/2 .10 | 3/2 .33 | 3/3 .39 | 4/4 .07 | 2/2 .35 | 2/2 .24 | 4/3 .34 | 6/4 .40 | 22/4 | 5/9 | 0.36 |
| **0.9** | 2/2 .10 | 3/2 .33 | 3/3 .38 | 4/4 .07 | 2/2 .35 | 2/2 .24 | 3/3 .30 | 5/4 .36 | 15/4 | **6/9** | **0.35** |
| 1.0 | 2/2 .10 | 2/2 .27 | 2/3 .48 | 3/4 .28 | 2/2 .35 | 2/2 .24 | 3/3 .30 | 4/4 .35 | 13/4 | 6/9 | 0.38 |
| 1.1 | 2/2 .10 | 2/2 .27 | 1/3 .67 | 2/4 .49 | 2/2 .35 | 2/2 .24 | 3/3 .30 | 3/4 .47 | 5/4 .36 | 5/9 | 0.36 |

### ERes2Net base (RTF ≈ 0.25)

| thr | correct | mean err |
| ---: | :---: | ---: |
| 0.8 | 2/9 | 0.39 |
| **0.9** | **5/9** | **0.37** |
| 1.0 | 4/9 | 0.38 |

### WeSpeaker ResNet34-LM (RTF ≈ 0.32)

Unstable: on the Chinese sample it was correct at 0.25–0.35, on these recordings it needs 0.5 or
more (4/9 correct at 0.5, mean error 0.44 — the best value in the measured range 0.15–0.5).

### With the number of speakers given (`numClusters`, TitaNet-S)

| File | voices | error |
| :--- | :---: | ---: |
| AMI meeting, 4 asked | 4 | 0.36 |
| `en_4`, 4 asked | 4 | 0.35 |
| `ru_3`, 4 asked (3 real) | 3 | 0.38 |

The real meeting is the hard case: no single threshold finds its 4 people (15 voices at 0.9, the
"fragmented" warning fires), but with the count given the result is as good as on the other files.
That is exactly what the warning in the app tells people to do. The count is a target, not a
promise: asked for 4 on a 3-person recording, it still found 3.

## Chosen defaults

| Embedder | Default | Notes |
| :--- | ---: | :--- |
| **TitaNet-S** (default) | 0.9 | Best on correct counts and error, fastest. License: "covered by the license of the NeMo Toolkit" per the NGC model card → Apache-2.0. |
| ERes2Net base | 0.9 | Slightly worse, ~2× slower. Apache-2.0. |
| WeSpeaker ResNet34-LM | 0.5 | Least stable; not recommended. CC BY 4.0 (VoxCeleb). |

A per-machine threshold can be set with the `diarizationThreshold` key in `settings.json`.

## End to end with real whisper.cpp

whisper.cpp 1.9.3 with the app's three patches (`tool/*.patch`), `ggml-small`, TitaNet-S at 0.9:

- **Text is unchanged with the mode on.** `-ojf` vs `-oj` gave byte-identical fragment text on all
  five checked recordings (20/20, 21/21, 21/21, 33/33, 14/14 fragments).
- **Voices:** 2/2, 2/2, 3/2, 3/3, 3/3 voices found.
- The first run exposed a real bug: the change of speaker was cut 1–3 words late, and a sentence of
  one person broke into pieces of two voices ("…где теперь льды. **В**" / "Сарайке…"). Whisper's
  token timestamps and fragment boundaries drift by up to a second at phrase joins. Fixed by
  `voteBySentences`: each sentence (across fragment boundaries) goes to the voice holding most of
  its time; a run of another voice inside it survives only if it is at least 4 words and 1.5 s.
  Words inside an overlap vote too, and keep their `⇄` mark.

## Sortformer (NeMo-Speech.cpp `--diarize`)

The bundled NeMo engine has its own diarization (Streaming Sortformer v2, CC BY 4.0, up to 4
speakers). One CPU run on `en_2a`: 3 voices instead of 2, error 0.58, and 874 s for 80 s of audio
(shared CPU). Not a replacement on CPU; may be worth a look with Metal/Vulkan.

## Reproducing

```sh
dart run tool/diarize_probe.dart \
    --lib ~/.pub-cache/hosted/pub.dev/sherpa_onnx_linux-1.13.8/linux/x64 \
    --segmentation models/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx \
    --embedder models/nemo_en_titanet_small.onnx \
    --from 0.6 --to 1.2 --step 0.1 [--speakers N] recordings/*.wav
```

Each `x.wav` may have `x.rttm` next to it; then the error column is filled in.
