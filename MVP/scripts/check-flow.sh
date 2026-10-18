#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
flow_build="$project_root/.local-build/flow"
mkdir -p "$flow_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$flow_build/clang"

# Compile the actual production packages and VM. Only platform/transport services are replaced.
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name OpenVisionCore MVP/Core/Sources/OpenVisionCore/*.swift \
    -emit-module-path "$flow_build/OpenVisionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libOpenVisionCore.dylib \
    -o "$flow_build/libOpenVisionCore.dylib"
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name SubscriptionCore MVP/Subscription/Sources/SubscriptionCore/*.swift \
    -emit-module-path "$flow_build/SubscriptionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libSubscriptionCore.dylib \
    -o "$flow_build/libSubscriptionCore.dylib"
swiftc -swift-version 6 -parse-as-library \
    -I "$flow_build" -L "$flow_build" -lOpenVisionCore -lSubscriptionCore \
    -Xlinker -rpath -Xlinker "$flow_build" \
    MVP/App/ConversationViewModel.swift MVP/FlowChecks/*.swift \
    -o "$flow_build/FlowChecks"
"$flow_build/FlowChecks" | tee .test-results/flow-checks.txt
