#!/usr/bin/env python3
"""Build-only Big LaMa conversion; no Python is required by ReadingGlass.

Based on mallman/CoreMLaMa commit
55550555a01a235357cac3f066f31dce21f22264 (Apache-2.0). This wrapper deliberately
uses normalized Float32 tensors instead of that project's ImageType scaling.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.request

import coremltools as ct
import numpy as np
import torch


CHECKPOINT_URL = "https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt"
CHECKPOINT_BYTES = 205669692
CHECKPOINT_MD5 = "e3aa4aaa15225a33ec84f9f4bc47e500"
CHECKPOINT_SHA256 = "344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9"


class NormalizedLaMa(torch.nn.Module):
    def __init__(self, lama):
        super().__init__()
        self.lama = lama

    def forward(self, image, mask):
        # Swift owns normalization once. One means erase/restore.
        return torch.clamp(self.lama(image, (mask > 0.5).to(torch.float32)), 0.0, 1.0)


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fixture(index):
    y, x = np.mgrid[:512, :512].astype(np.float32) / 511
    image = np.stack((x, y, (x + y) / 2))[None].astype(np.float32)
    mask = np.zeros((1, 1, 512, 512), dtype=np.float32)
    if index == 0:
        mask[:, :, 180:260, 100:410] = 1
    elif index == 1:
        mask[:, :, 30:42, 20:450] = 1
        mask[:, :, 55:70, 50:470] = 1
    else:
        image = np.full((1, 3, 512, 512), 0.75, dtype=np.float32)
        mask[:, :, 0:100, 400:512] = 1
    return image, mask


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(".build/models"))
    args = parser.parse_args()
    output = args.output.resolve()
    checkpoint = output / "source/big-lama.pt"
    checkpoint.parent.mkdir(parents=True, exist_ok=True)
    if not checkpoint.exists():
        temporary = checkpoint.with_suffix(".download")
        urllib.request.urlretrieve(CHECKPOINT_URL, temporary)
        temporary.replace(checkpoint)
    assert checkpoint.stat().st_size == CHECKPOINT_BYTES, "Checkpoint size mismatch"
    assert digest(checkpoint, "md5") == CHECKPOINT_MD5, "Checkpoint MD5 mismatch"
    assert digest(checkpoint, "sha256") == CHECKPOINT_SHA256, "Checkpoint SHA256 mismatch"
    torch.set_num_threads(4)
    model = NormalizedLaMa(torch.jit.load(str(checkpoint), map_location="cpu").eval()).eval()
    scripted = torch.jit.script(model)
    print("Converting normalized 512x512 NCHW Float32 tensors", flush=True)
    converted = ct.convert(
        scripted,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
        inputs=[
            ct.TensorType(name="image", shape=(1, 3, 512, 512), dtype=np.float32),
            ct.TensorType(name="mask", shape=(1, 1, 512, 512), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        skip_model_load=True,
    )
    package = output / "LaMa512.mlpackage"
    converted.save(str(package))
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(output)], check=True)
    runtime = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    metrics = []
    for index in range(3):
        image, mask = fixture(index)
        started = time.monotonic()
        with torch.no_grad():
            expected = model(torch.from_numpy(image), torch.from_numpy(mask)).numpy()
        actual = runtime.predict({"image": image, "mask": mask})["output"]
        assert actual.shape == expected.shape == (1, 3, 512, 512)
        assert np.isfinite(actual).all(), "Nonfinite CoreML output"
        assert actual.min() >= 0 and actual.max() <= 1, "CoreML output range mismatch"
        mae = np.abs(actual - expected).mean(axis=(0, 2, 3)) * 255
        assert (mae <= 1.0).all(), f"Per-channel parity exceeded 1 byte: {mae}"
        metrics.append({"fixture": index, "mae_8bit_per_channel": mae.tolist(),
                        "seconds": time.monotonic() - started})
        print(json.dumps(metrics[-1]), flush=True)
    evidence = {
        "checkpoint_url": CHECKPOINT_URL,
        "checkpoint_bytes": CHECKPOINT_BYTES,
        "checkpoint_md5": CHECKPOINT_MD5,
        "checkpoint_sha256": CHECKPOINT_SHA256,
        "reference_commit": "55550555a01a235357cac3f066f31dce21f22264",
        "torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__,
        "input_image": [1, 3, 512, 512], "input_mask": [1, 1, 512, 512],
        "output": [1, 3, 512, 512], "dtype": "Float32", "range": [0, 1],
        "mask_one_means": "erase", "parity": metrics,
    }
    (output / "conversion-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Verified CoreML artifact: {output / 'LaMa512.mlmodelc'}", flush=True)


if __name__ == "__main__":
    main()
