#!/bin/bash
set -euo pipefail
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/ReminderValidation"
mkdir -p "$gremma_validation/Sources/ReminderValidation" "$gremma_validation/Tests/ReminderValidationTests" \
    "$gremma_validation/ModuleCache" "$gremma_validation/Cache" "$gremma_validation/Configuration" "$gremma_validation/Security"
cp "$gremma_workspace/Gremma/Gremma/Core/ActivityMemory.swift" "$gremma_validation/Sources/ReminderValidation/ActivityMemory.swift"
cp "$gremma_workspace/Gremma/Gremma/Core/MedicineReminderPlan.swift" "$gremma_validation/Sources/ReminderValidation/MedicineReminderPlan.swift"
cp "$gremma_workspace/Gremma/CoreTests/MedicineReminderPlanTests.swift" "$gremma_validation/Tests/ReminderValidationTests/MedicineReminderPlanTests.swift"
cat > "$gremma_validation/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReminderValidation", platforms: [.macOS(.v13)], targets: [
    .target(name: "ReminderValidation"),
    .testTarget(name: "ReminderValidationTests", dependencies: ["ReminderValidation"])
])
SWIFT
export CLANG_MODULE_CACHE_PATH="$gremma_validation/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$gremma_validation/ModuleCache"
exec /usr/bin/xcrun swift test --package-path "$gremma_validation" --scratch-path "$gremma_validation/Build" \
    --cache-path "$gremma_validation/Cache" --config-path "$gremma_validation/Configuration" \
    --security-path "$gremma_validation/Security" --disable-sandbox "$@"
