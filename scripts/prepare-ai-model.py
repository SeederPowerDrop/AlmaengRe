#!/usr/bin/env python3
"""Reproduce the bundled, genuinely learned QuickSRNet Small 2x Core ML model.

Run with .build/ai-model-venv/bin/python after installing the pinned versions below.
Only the official Qualcomm checkpoint is downloaded; the checksum is mandatory.
The app never needs Python or a network connection for AI enlargement.
"""
from pathlib import Path
from collections import defaultdict
import hashlib
import json
import urllib.request

import coremltools as ct
import numpy as np
import torch
from torch import nn

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/ImageViewer/Resources/AIModels"
CHECKPOINT = ROOT / ".build/ai-model-inputs/quicksrnet_small_2x_checkpoint_float32.pth.tar"
URL = "https://github.com/quic/aimet-model-zoo/releases/download/phase_2_january_artifacts/quicksrnet_small_2x_checkpoint_float32.pth.tar"
SHA256 = "d95d70f1d2366cb9c28d99f8c7aa5bb07e1ffeaf5d7e30d9c66ab0fa28c6d0f8"


class QuickSRNetSmall(nn.Module):
    """Qualcomm QuickSRNetBase with 32 channels, 2 intermediate layers, no ITO.

    Architecture adapted from Qualcomm Innovation Center's BSD-3-Clause source:
    aimet_zoo_torch/quicksrnet/model/models.py. See the adjacent bundled license.
    Initialization is unnecessary because every parameter is replaced strictly.
    """
    def __init__(self):
        super().__init__()
        layers = [nn.Conv2d(3, 32, 3, padding=1), nn.Hardtanh(0.0, 1.0)]
        for _ in range(2):
            layers += [nn.Conv2d(32, 32, 3, padding=1), nn.Hardtanh(0.0, 1.0)]
        self.cnn = nn.Sequential(*layers)
        self.conv_last = nn.Conv2d(32, 12, 3, padding=1)
        self.clip_output = nn.Hardtanh(0.0, 1.0)
        self.depth_to_space = nn.PixelShuffle(2)

    def forward(self, image):
        return self.depth_to_space(self.clip_output(self.conv_last(self.cnn(image))))


def main():
    CHECKPOINT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if not CHECKPOINT.exists():
        with urllib.request.urlopen(URL) as response:
            CHECKPOINT.write_bytes(response.read())
    if hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Official checkpoint checksum mismatch; refusing conversion")
    torch.manual_seed(20260923)
    model = QuickSRNetSmall().eval()
    # The official training checkpoint also contains an Adam optimizer. Permit
    # only its known PyTorch/container types, never arbitrary pickle globals.
    with torch.serialization.safe_globals([torch.optim.Adam, defaultdict, dict]):
        checkpoint = torch.load(CHECKPOINT, map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    sample = torch.rand(1, 3, 128, 128)
    traced = torch.jit.trace(model, sample)
    # A single-file neural network is intentional: SwiftPM and the plain .app
    # build both package it without an Xcode-only model compilation phase.
    # Core ML compiles it locally and selects CPU/GPU/Neural Engine at runtime.
    converted = ct.convert(
        traced, convert_to="neuralnetwork", minimum_deployment_target=ct.target.macOS11,
        inputs=[ct.TensorType(name="image", shape=sample.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="upscaled", dtype=np.float32)],
    )
    converted.author = "Qualcomm Innovation Center, Inc.; Core ML conversion by AlmaengRe"
    converted.license = "BSD-3-Clause; see QuickSRNet-LICENSE.txt"
    converted.short_description = "QuickSRNet Small 2x; learned RGB super-resolution; 128x128 tiles"
    converted.version = "1"
    destination = OUTPUT / "QuickSRNetSmall2x.mlmodel"
    converted.save(str(destination))

    # Real inference against PyTorch, including a CPU-only Core ML execution.
    reference = model(sample).detach().numpy()
    cpu = ct.models.MLModel(str(destination), compute_units=ct.ComputeUnit.CPU_ONLY)
    actual = cpu.predict({"image": sample.numpy()})["upscaled"]
    max_error = float(np.max(np.abs(reference - actual)))
    if max_error > 0.002:
        raise RuntimeError(f"Core ML parity failed: {max_error}")
    report = {
        "model": "QuickSRNet Small 2x", "scale": 2, "input": [1, 3, 128, 128],
        "output": [1, 3, 256, 256], "checkpoint_url": URL,
        "checkpoint_sha256": SHA256,
        "model_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__,
        "cpu_pytorch_max_absolute_error": max_error,
        "cpu_pytorch_mean_absolute_error": float(np.mean(np.abs(reference - actual))),
        "notes": "CPU parity checked on Apple Silicon; Intel hardware has not been exercised.",
    }
    (OUTPUT / "QuickSRNet-provenance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
