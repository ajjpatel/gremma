#!/bin/bash
set -euo pipefail
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/RuntimeValidation"
mkdir -p "$gremma_validation/Sources/RuntimeValidation" "$gremma_validation/Tests/RuntimeValidationTests" \
    "$gremma_validation/ModuleCache" "$gremma_validation/Cache" "$gremma_validation/Configuration" "$gremma_validation/Security"
cp "$gremma_workspace/Gremma/Gremma/Runtime/RuntimeDeadlineGate.swift" "$gremma_validation/Sources/RuntimeValidation/RuntimeDeadlineGate.swift"
cp "$gremma_workspace/Gremma/CoreTests/RuntimeDeadlineTests.swift" "$gremma_validation/Tests/RuntimeValidationTests/RuntimeDeadlineTests.swift"
cat > "$gremma_validation/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RuntimeValidation", platforms: [.macOS(.v13)], targets: [
    .target(name: "RuntimeValidation"),
    .testTarget(name: "RuntimeValidationTests", dependencies: ["RuntimeValidation"])
])
SWIFT
export CLANG_MODULE_CACHE_PATH="$gremma_validation/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$gremma_validation/ModuleCache"
exec /usr/bin/xcrun swift test --package-path "$gremma_validation" --scratch-path "$gremma_validation/Build" \
    --cache-path "$gremma_validation/Cache" --config-path "$gremma_validation/Configuration" \
    --security-path "$gremma_validation/Security" --disable-sandbox "$@"
