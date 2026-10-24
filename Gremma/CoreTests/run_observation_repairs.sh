#!/bin/bash
set -euo pipefail
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/ObservationRepairValidation"
mkdir -p "$gremma_validation/ModuleCache"
/usr/bin/xcrun swiftc -Onone \
    -module-cache-path "$gremma_validation/ModuleCache" \
    "$gremma_workspace/Gremma/Gremma/Core/MemoryObservation.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/MemoryRepository.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/ObservationDecoder.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/ObservationService.swift" \
    "$gremma_workspace/Gremma/Gremma/Diagnostics/ObservationDebugLog.swift" \
    "$gremma_workspace/Gremma/CoreTests/ObservationRepairModelStub.swift" \
    "$gremma_workspace/Gremma/CoreTests/ObservationRepairChecks.swift" \
    -o "$gremma_validation/checks"
exec "$gremma_validation/checks"
