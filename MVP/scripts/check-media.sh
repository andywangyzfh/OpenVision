#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
media_build="${MVP_MEDIA_BUILD_ROOT:-$project_root/.local-build/media}"
mkdir -p "$media_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$media_build/clang"
# Compile the actual service; only its output-playback/remote-command effects are injected.
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
  -module-name OpenVisionCore MVP/Core/Sources/OpenVisionCore/*.swift \
  -emit-module-path "$media_build/OpenVisionCore.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libOpenVisionCore.dylib -o "$media_build/libOpenVisionCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$media_build" -L "$media_build" -lOpenVisionCore \
  -Xlinker -rpath -Xlinker "$media_build" \
  MVP/App/BluetoothMediaTriggerService.swift MVP/App/AppleBluetoothMediaDriver.swift MVP/MediaChecks/*.swift \
  -o "$media_build/MediaChecks"
"$media_build/MediaChecks" 2>&1 | tee .test-results/media-checks.txt
