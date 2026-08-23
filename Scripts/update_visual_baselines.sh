#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPOSITORY_ROOT}"

OPENFIND_UPDATE_VISUAL_BASELINES=1 \
    bash Scripts/test.sh --filter VisualRegressionTests

OPENFIND_RUN_VISUAL_REGRESSION=1 \
    bash Scripts/test.sh --filter VisualRegressionTests

echo "OpenFind visual baselines regenerated and verified."
