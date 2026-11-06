#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -d .build/models/LaMa512.mlmodelc && -f .build/models/conversion-evidence.json ]]; then
    exit 0
fi
mkdir -p .build
if [[ ! -x .build/model-conversion-venv/bin/python ]]; then
    uv venv --python 3.10 .build/model-conversion-venv > .build/model-conversion.log 2>&1
fi
uv pip sync --python .build/model-conversion-venv/bin/python \
    tools/model_conversion/requirements.lock >> .build/model-conversion.log 2>&1
if ! .build/model-conversion-venv/bin/python tools/model_conversion/convert_lama.py \
    --output .build/models >> .build/model-conversion.log 2>&1; then
    tail -60 .build/model-conversion.log
    exit 1
fi
