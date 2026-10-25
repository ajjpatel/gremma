#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_test="$gremma_root/.build/AttentionCropChecks"
mkdir -p "$gremma_test/ModuleCache"
xcrun swiftc -swift-version 5 -module-cache-path "$gremma_test/ModuleCache" \
  "$gremma_root/Gremma/Gremma/Core/VideoAttentionCrop.swift" \
  "$gremma_root/Gremma/CoreTests/VideoAttentionCropChecks.swift" \
  -o "$gremma_test/checks"
exec "$gremma_test/checks"
