#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
inputs_build="${MVP_INPUTS_BUILD_ROOT:-$project_root/.local-build/inputs}"
mkdir -p "$inputs_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$inputs_build/clang"
# This boundary must remain camera-free. These are the exact production sources under test.
python3 - <<'PY'
from pathlib import Path
for name in ['GlassesInputService.swift', 'DATInputDriver.swift', 'GlassesInputSettingsView.swift']:
    source=Path('MVP/App',name).read_text()
    for forbidden in ['import MWDATCamera', '.addCamera(', '.capturePhoto(', '.requestPermission(']:
        assert forbidden not in source, (name,forbidden)
source=Path('MVP/App/DATInputDriver.swift').read_text()
assert 'InputsConfiguration(sources: [.captouch], consumeBack: false)' in source
print('PASS: production inputs boundary uses explicit captouch only and contains no camera/permission fallback calls')
PY
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
  -module-name OpenVisionCore MVP/Core/Sources/OpenVisionCore/*.swift \
  -emit-module-path "$inputs_build/OpenVisionCore.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libOpenVisionCore.dylib -o "$inputs_build/libOpenVisionCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$inputs_build" -L "$inputs_build" -lOpenVisionCore \
  -Xlinker -rpath -Xlinker "$inputs_build" \
  MVP/App/GlassesInputService.swift MVP/App/DATInputDriver.swift MVP/InputsChecks/*.swift \
  -o "$inputs_build/InputsChecks"
"$inputs_build/InputsChecks" 2>&1 | tee .test-results/inputs-checks.txt
