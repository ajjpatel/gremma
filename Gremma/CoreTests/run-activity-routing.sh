#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_root/.build/ActivityRoutingValidation"
mkdir -p "$gremma_validation/ModuleCache"
xcrun swiftc -Onone -module-cache-path "$gremma_validation/ModuleCache" \
    "$gremma_root/Gremma/Gremma/Core/ActivityFastRouter.swift" \
    "$gremma_root/Gremma/Gremma/Core/VoiceCommandRouter.swift" \
    "$gremma_root/Gremma/Gremma/Core/Reading.swift" \
    "$gremma_root/Gremma/CoreTests/ActivityFastRouterChecks.swift" \
    -o "$gremma_validation/checks"
exec "$gremma_validation/checks"
