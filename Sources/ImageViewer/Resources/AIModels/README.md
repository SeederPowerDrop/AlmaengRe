# QuickSRNet Small 2× in AlmaengRe

This is a learned image super-resolution network, not a renamed image interpolation filter.
It runs entirely on the user's Mac. No image uploads, accounts or runtime model downloads are used.

- Model and architecture: Qualcomm Innovation Center, Inc., QuickSRNet Small 2×.
- Original source: https://github.com/quic/aimet-model-zoo/tree/develop/aimet_zoo_torch/quicksrnet
- Current Qualcomm recipe referencing the same weights: https://github.com/qualcomm/ai-hub-models/blob/main/src/qai_hub_models/models/quicksrnetsmall/model.py
- License: BSD-3-Clause, included verbatim in `QuickSRNet-LICENSE.txt`.
- Architecture attribution: Copyright (c) 2022 Qualcomm Innovation Center, Inc. All rights reserved.
- Exact upstream checkpoint URL, SHA-256 and conversion verification: `QuickSRNet-provenance.json`.

The bundled `.mlmodel` contains the original trained float32 weights. Four convolution layers,
clipped activations and PixelShuffle predict 2× RGB output. A single-file Core ML neural-network
format is used so both SwiftPM and the plain app-bundle build preserve it reliably. The app compiles
the model locally and asks Core ML to use available processors; it can fall back to CPU execution.
Intel CPU execution is supported by the API and model operations but has not been tested on Intel
hardware. The recorded CPU parity test was performed on Apple Silicon. No speed guarantee is made.

AI enlargement is an explicit command with progress and cancellation. It uses bounded 128×128
tiles with four pixels of overlap, edge replication, and a maximum of 64 million output pixels
(reduced on low-memory machines). The result is 8-bit SDR sRGB, preserves separately interpolated
alpha, and uses the first frame of animated inputs. Original files are never overwritten. Inferred
detail may differ from the original subject; this is an enlargement tool, not evidence recovery.

## Reproduction

Use Python 3.12 in a project-local virtual environment, without changing the system Python:

```sh
python3.12 -m venv .build/ai-model-venv
.build/ai-model-venv/bin/python -m pip install torch==2.7.0 coremltools==8.3.0 numpy==1.26.4
.build/ai-model-venv/bin/python scripts/prepare-ai-model.py
```

The script accepts only the official checkpoint with the pinned SHA-256, loads it with PyTorch's
restricted weights-only loader, converts the model, and compares actual Core ML CPU predictions
against PyTorch predictions. It writes provenance and fails on numerical disagreement. PyTorch
2.7 is newer than coremltools 8.3's declared tested range; the recorded end-to-end parity check
therefore verifies this particular conversion rather than assuming compatibility.

The model architecture adaptation in `scripts/prepare-ai-model.py` carries the same BSD-3-Clause
terms as the upstream implementation. Redistribution must retain the included notice, conditions
and disclaimer. Qualcomm does not endorse AlmaengRe.
