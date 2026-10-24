#!/bin/bash
set -euo pipefail

# Runs actual decision-validation and room-consensus code against controlled model responses.
# This does not invoke Gemma or build the iOS app. Real ReadingMode and history types are used.
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/CoordinatorBoundaryValidation"
mkdir -p "$gremma_validation/ModuleCache"

/usr/bin/xcrun swiftc -Onone \
    -module-cache-path "$gremma_validation/ModuleCache" \
    "$gremma_workspace/Gremma/Gremma/Core/Reading.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/ConversationHistory.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/AgentCoordinator.swift" \
    "$gremma_workspace/Gremma/Gremma/Core/VideoRoomClassifier.swift" \
    "$gremma_workspace/Gremma/CoreTests/CoordinatorModelStub.swift" \
    "$gremma_workspace/Gremma/CoreTests/CoordinatorBoundaryChecks.swift" \
    -o "$gremma_validation/checks"

exec "$gremma_validation/checks"
