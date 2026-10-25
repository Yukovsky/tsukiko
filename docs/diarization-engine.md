# Diarization engine: why Nemotron-3

"Multiple voices" runs NVIDIA **Nemotron-3-Diarization** through `nemo-speech diarize`
(NeMo-Speech.cpp 0.2.0, the engine the app already bundles for Parakeet and Nemotron ASR). The
first version of the mode used sherpa-onnx (pyannote segmentation 3.0 + TitaNet-S + a clustering
threshold); it was replaced after the comparison below.

## Test set

Ten real recordings with reference RTTM. All English: no Russian meeting with ground truth was
found, so Russian remains the main unchecked case.

| Set | Files | Voices | Length |
| :--- | :--- | :---: | :--- |
| AMI meetings (headset mix, CC BY 4.0, RTTM from `pyannote/AMI-diarization-setup`) | ES2004a, IS1009a, TS3003a, EN2002a | 4 each | 14–36 min |
| VoxConverse dev (CC BY 4.0) | aisvi, bauzd, dbugl, eapdk, edixl, fkvvo | 5–9 | 5–13 min |

Error is DER from `pyannote.metrics` (collar 0, overlap counted). Machine: Apple M5, 16 GB.

## Results

| Engine | DER, AMI | DER, VoxConverse | Voices found | Time, 17.5 min meeting |
| :--- | ---: | ---: | :--- | ---: |
| **Nemotron-3 (`nemo-speech` 0.2.0, Metal)** | **0.253** | **0.054** | right on 9 of 10, up to 8 | 58 s |
| pyannote community-1 (FluidAudio, CoreML) | 0.249 | 0.082 | often too few (2 of 4, 4 of 8, 5 of 9) | 5 s |
| Sortformer v2 4spk (`nemo-speech`, Metal) | 0.275 | 0.275 | always 4 | 46 s |
| sherpa-onnx + TitaNet-S, threshold 0.9 (first version) | 0.437 | 0.089 | 17–46 on the meetings | 88 s (CPU) |
| same, 4 voices given | 0.332 | — | 4 | 88 s (CPU) |

Per file, Nemotron-3: AMI 0.213 / 0.252 / 0.269 / 0.260, VoxConverse 0.039 (8/8), 0.098 (5/5),
0.039 (8/8), 0.021 (7/7), 0.014 (6/6), 0.108 (8 of 9).

Speed and memory of Nemotron-3:

| Recording | Metal | Peak memory |
| :--- | ---: | ---: |
| 14 min | 26 s | 0.49 GB |
| 36 min | 79 s | 0.91 GB |
| 2.4 h (all ten files joined) | 332 s, 8 voices | 2.35 GB |
| 5 min, CPU only (`--device cpu`) | 45 s | 0.37 GB |

## Why not the others

- **sherpa-onnx + embedder threshold.** No threshold works for both short calls and real
  meetings: four people became 17–46 voices on AMI. Giving the number of voices helps, but people
  rarely know it in advance.
- **community-1.** As good as Nemotron-3 on meetings, weaker and undercounting on 5–9 voices.
  Shipping it would mean porting VBx clustering (PLDA + VB-HMM) to Dart or wrapping a Rust or
  Swift port (speakrs, FluidAudio; the latter is macOS only), and the upstream model is gated on
  Hugging Face. More work for no gain here.
- **Sortformer v2.** Fast on Metal, but limited to four voices: DER up to 0.49 on 7–9 voices.
- **DiariZen** (measured earlier on Linux): CC BY-NC, Python + PyTorch, ~13 GB RAM.

## End to end

Real whisper.cpp (`ggml-small`, `-ojf`) and Parakeet TDT 0.6B v3 (`nemo-speech` 0.2.0) merged
with Nemotron-3 turns by the app's sentence voting (`lib/core/speakers.dart`), counting fragment
time where the fragment's voice matches the reference speaker at its midpoint:

| Recording | Whisper | Parakeet |
| :--- | ---: | ---: |
| VoxConverse edixl, 6 voices | 6 voices, 100 % | 6 voices, 99.6 % |
| AMI IS1009a, 4 voices | 4 voices, 84.8 % | 4 voices, 89.9 % |

## Reproducing

```sh
nemo-speech diarize meeting.wav --model Nemotron-3-Diarization.q8_0.gguf \
    --format rttm --recording-id meeting -o meeting.hyp.rttm
uv run --with pyannote.metrics python -c '…DiarizationErrorRate(collar=0)…'
```

The test `test/core/diarization_test.dart` runs the real engine when `TSUKIKO_NEMO_SPEECH` and
`TSUKIKO_DIARIZATION_MODELS` are set (see the comment at its top).
