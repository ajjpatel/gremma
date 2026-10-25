#!/bin/bash
set -euo pipefail
gremma_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_test="$gremma_root/.build/TemporalVideoValidation"
mkdir -p "$gremma_test/Sources/TemporalVideoCore" "$gremma_test/Tests/TemporalVideoTests" "$gremma_test/ModuleCache" "$gremma_test/Cache" "$gremma_test/Config" "$gremma_test/Security"
cp "$gremma_root/Gremma/Gremma/Core/VideoIndexQueue.swift" "$gremma_test/Sources/TemporalVideoCore/"
cp "$gremma_root/Gremma/CoreTests/TemporalVideoTests.swift" "$gremma_test/Tests/TemporalVideoTests/"
cp "$gremma_root/Gremma/CoreTests/ActivityVideoExtractionTests.swift" "$gremma_test/Tests/TemporalVideoTests/"
cp "$gremma_root/Gremma/CoreTests/VideoAttentionCropTests.swift" "$gremma_test/Tests/TemporalVideoTests/"
cp "$gremma_root/Gremma/CoreTests/ActivityVideoModelStub.swift" "$gremma_test/Sources/TemporalVideoCore/"
cp "$gremma_root/Gremma/Gremma/Core/ActivityMemory.swift" "$gremma_test/Sources/TemporalVideoCore/"
cp "$gremma_root/Gremma/Gremma/Core/ActivityVideoIndexer.swift" "$gremma_test/Sources/TemporalVideoCore/"
cp "$gremma_root/Gremma/Gremma/Core/VideoAttentionCrop.swift" "$gremma_test/Sources/TemporalVideoCore/"
cp "$gremma_root/Gremma/Gremma/Runtime/RuntimeDeadlineGate.swift" "$gremma_test/Sources/TemporalVideoCore/"
cat > "$gremma_test/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "TemporalVideoValidation", platforms: [.macOS(.v13)], targets: [
    .target(name: "TemporalVideoCore"),
    .testTarget(name: "TemporalVideoTests", dependencies: ["TemporalVideoCore"])
])
SWIFT
export CLANG_MODULE_CACHE_PATH="$gremma_test/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$gremma_test/ModuleCache"
exec xcrun swift test --package-path "$gremma_test" --scratch-path "$gremma_test/Build" --cache-path "$gremma_test/Cache" --config-path "$gremma_test/Config" --security-path "$gremma_test/Security" --disable-sandbox "$@"
