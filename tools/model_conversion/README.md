# Big LaMa conversion

This is developer tooling. The installed application uses the compiled Core ML
model and does not require Python, PyTorch, or a model server.

From the repository root:

```sh
uv python install 3.10
uv venv --python 3.10 .build/model-conversion-venv
uv pip sync --python .build/model-conversion-venv/bin/python tools/model_conversion/requirements.lock
.build/model-conversion-venv/bin/python tools/model_conversion/convert_lama.py
tools/model_conversion/verify_runtime.sh
```

The converter downloads the fixed Big LaMa checkpoint only if it is absent,
checks its length, MD5 and SHA-256, then compiles
`.build/models/LaMa512.mlmodelc`. It retains the source and `.mlpackage` under
`.build/models/`; these generated model files are not source-control inputs.

The environment is frozen in `requirements.lock`, including Python-side pins
`torch==2.2.0`, `coremltools==7.2` and `numpy==1.26.4`. Python 3.10 is required.

The input/output contract is normalized Float32 NCHW: `image` `[1,3,512,512]`,
`mask` `[1,1,512,512]`, and `output` `[1,3,512,512]`. Mask one means restore.
The wrapper does not divide inputs by 255 or multiply outputs by 255; Swift owns
those conversions exactly once. Core ML uses CPU/GPU execution with float32
conversion and no low-precision GPU accumulation.

`conversion-evidence.json` records checkpoint provenance and three synthetic
Core ML/PyTorch parity comparisons. Conversion fails unless every channel's
mean absolute error is at most 1.0 on an 8-bit scale. The native verification
uses a 600x300 synthetic image spanning two overlapping tiles. It checks native
model loading, overlap weights, exact preservation of pixels outside the erase
and text-backing region, and the retained contrast floor. It writes
`runtime-verification.txt`. These checks do not establish visual reconstruction
quality on real documents.

Reference: [CoreMLaMa at 55550555a01a235357cac3f066f31dce21f22264](https://github.com/mallman/CoreMLaMa/tree/55550555a01a235357cac3f066f31dce21f22264),
Apache-2.0. The normalized tensor wrapper intentionally differs from its
ImageType scaling. Third-party license copies are in
`Resources/ThirdPartyNotices.md`.
