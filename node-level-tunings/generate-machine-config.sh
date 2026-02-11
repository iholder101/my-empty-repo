#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
butane "${DIR}/99-swap-node-tuning.bu" -o "${DIR}/99-swap-node-tuning.yaml"
echo "Generated ${DIR}/99-swap-node-tuning.yaml"
