#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_checks="$gremma_root/.build/VideoSpeechPolicyValidation"
mkdir -p "$gremma_checks/ModuleCache"
xcrun swiftc -module-cache-path "$gremma_checks/ModuleCache" \
  "$gremma_root/Gremma/Gremma/Voice/VideoSpeechPolicy.swift" \
  "$gremma_root/Gremma/CoreTests/VideoSpeechPolicyChecks.swift" \
  -o "$gremma_checks/policy-checks"
"$gremma_checks/policy-checks"
