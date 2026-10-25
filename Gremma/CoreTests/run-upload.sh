#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_checks="$gremma_root/.build/UploadValidation"
mkdir -p "$gremma_checks/ModuleCache"
xcrun swiftc -module-cache-path "$gremma_checks/ModuleCache" \
  "$gremma_root/Gremma/Gremma/Network/LocalVideoUploadProtocol.swift" \
  "$gremma_root/Gremma/CoreTests/UploadProtocolChecks.swift" \
  -o "$gremma_checks/protocol-checks"
"$gremma_checks/protocol-checks"
python3 "$gremma_root/Gremma/CoreTests/test_upload_video.py"
