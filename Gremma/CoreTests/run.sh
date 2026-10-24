#!/bin/bash
set -euo pipefail

# Run the unchanged core XCTest suite on macOS, without building the iOS app.
# Generated package, compiler caches, and build products stay in the ignored .build directory.
# Additional Swift test arguments are accepted, for example: ./Gremma/CoreTests/run.sh --filter RoomQualifier
gremma_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gremma_validation="$gremma_workspace/.build/CoreValidation"
gremma_sources="$gremma_validation/Sources/GremmaCore"
gremma_tests="$gremma_validation/Tests/GremmaCoreTests"

mkdir -p "$gremma_sources" "$gremma_tests" "$gremma_validation/ModuleCache" \
    "$gremma_validation/Cache" "$gremma_validation/Configuration" "$gremma_validation/Security"

for gremma_file in MemoryObservation.swift MemoryRepository.swift Reading.swift VoiceCommandRouter.swift ObservationDecoder.swift VideoIndexQueue.swift; do
    cp "$gremma_workspace/Gremma/Gremma/Core/$gremma_file" "$gremma_sources/$gremma_file"
done
cp "$gremma_workspace/Gremma/CoreTests/GremmaCoreTests.swift" "$gremma_tests/GremmaCoreTests.swift"
cp "$gremma_workspace/Gremma/CoreTests/VoiceCommandRouterTests.swift" "$gremma_tests/VoiceCommandRouterTests.swift"
cp "$gremma_workspace/Gremma/CoreTests/ObservationDecoderTests.swift" "$gremma_tests/ObservationDecoderTests.swift"
cp "$gremma_workspace/Gremma/CoreTests/VideoLibraryTests.swift" "$gremma_tests/VideoLibraryTests.swift"

cat > "$gremma_validation/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GremmaCoreValidation",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "GremmaCore", sources: [
            "MemoryObservation.swift", "MemoryRepository.swift", "Reading.swift", "VoiceCommandRouter.swift", "ObservationDecoder.swift", "VideoIndexQueue.swift"
        ]),
        .testTarget(name: "GremmaCoreTests", dependencies: ["GremmaCore"], sources: ["GremmaCoreTests.swift", "VoiceCommandRouterTests.swift", "ObservationDecoderTests.swift", "VideoLibraryTests.swift"])
    ]
)
SWIFT

export CLANG_MODULE_CACHE_PATH="$gremma_validation/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$gremma_validation/ModuleCache"

exec /usr/bin/xcrun swift test \
    --package-path "$gremma_validation" \
    --scratch-path "$gremma_validation/Build" \
    --cache-path "$gremma_validation/Cache" \
    --config-path "$gremma_validation/Configuration" \
    --security-path "$gremma_validation/Security" \
    --disable-sandbox "$@"
