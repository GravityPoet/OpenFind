#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPOSITORY_ROOT}"

OPENFIND_UPDATE_VISUAL_BASELINES=1 \
    swift test --filter VisualRegressionTests

OPENFIND_RUN_VISUAL_REGRESSION=1 \
    swift test --filter VisualRegressionTests

echo "OpenFind visual baselines regenerated and verified."
