#!/bin/bash
set -euo pipefail
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/ActivityValidation"
mkdir -p "$gremma_validation/Sources/ActivityValidation" "$gremma_validation/Tests/ActivityValidationTests" \
    "$gremma_validation/ModuleCache" "$gremma_validation/Cache" "$gremma_validation/Configuration" "$gremma_validation/Security"
cp "$gremma_workspace/Gremma/Gremma/Core/QueryPerformance.swift" "$gremma_validation/Sources/ActivityValidation/QueryPerformance.swift"
cp "$gremma_workspace/Gremma/Gremma/Core/ActivityMemory.swift" "$gremma_validation/Sources/ActivityValidation/ActivityMemory.swift"
cp "$gremma_workspace/Gremma/Gremma/Core/ActivityRepository.swift" "$gremma_validation/Sources/ActivityValidation/ActivityRepository.swift"
cp "$gremma_workspace/Gremma/CoreTests/ActivityMemoryTests.swift" "$gremma_validation/Tests/ActivityValidationTests/ActivityMemoryTests.swift"
cat > "$gremma_validation/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ActivityValidation", platforms: [.macOS(.v13)], targets: [
    .target(name: "ActivityValidation", linkerSettings: [.linkedLibrary("sqlite3")]),
    .testTarget(name: "ActivityValidationTests", dependencies: ["ActivityValidation"])
])
SWIFT
export CLANG_MODULE_CACHE_PATH="$gremma_validation/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$gremma_validation/ModuleCache"
exec /usr/bin/xcrun swift test --package-path "$gremma_validation" --scratch-path "$gremma_validation/Build" \
    --cache-path "$gremma_validation/Cache" --config-path "$gremma_validation/Configuration" \
    --security-path "$gremma_validation/Security" --disable-sandbox "$@"
