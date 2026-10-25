#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_checks="$gremma_root/.build/UploadValidation"
mkdir -p "$gremma_checks/ModuleCache"
xcrun swiftc -target arm64-apple-macos15.0 -module-cache-path "$gremma_checks/ModuleCache" \
  "$gremma_root/Gremma/Gremma/Network/LocalVideoUploadProtocol.swift" \
  "$gremma_root/Gremma/Gremma/Network/LocalVideoUploadServer.swift" \
  "$gremma_root/Gremma/CoreTests/UploadServerSmoke.swift" \
  -o "$gremma_checks/server-smoke"
"$gremma_checks/server-smoke"
