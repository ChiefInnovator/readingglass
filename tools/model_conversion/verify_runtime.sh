#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
mkdir -p .build/models
swiftc -O -swift-version 6 -parse-as-library \
  src/Pipeline/Models.swift src/Pipeline/TranslationModels.swift \
  src/Pipeline/InferenceScheduler.swift src/Rendering/BackgroundInpainter.swift \
  tools/model_conversion/VerifyRestoration.swift \
  -o .build/models/verify-restoration
.build/models/verify-restoration .build/models/LaMa512.mlmodelc | tee .build/models/runtime-verification.txt
