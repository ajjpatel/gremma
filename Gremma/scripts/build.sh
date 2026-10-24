#!/bin/zsh
set -eu
gremma_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$gremma_root"
export PATH="$gremma_root/.build/tools:$PATH"
export GIT_LFS_SKIP_SMUDGE=1
python3 Gremma/generate_project.py
exec xcodebuild \
  -project Gremma/Gremma.xcodeproj -scheme Gremma -configuration Debug \
  -destination "${1:-generic/platform=iOS}" \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -scmProvider system \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
