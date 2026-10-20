#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
network_build="$project_root/.local-build/network"
mkdir -p "$network_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$network_build/clang"

swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name SubscriptionCore MVP/Subscription/Sources/SubscriptionCore/*.swift \
    -emit-module-path "$network_build/SubscriptionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libSubscriptionCore.dylib \
    -o "$network_build/libSubscriptionCore.dylib"
swiftc -swift-version 6 -parse-as-library \
    -I "$network_build" -L "$network_build" -lSubscriptionCore \
    -Xlinker -rpath -Xlinker "$network_build" \
    MVP/App/Account/ChatGPTPlanClient.swift MVP/App/Account/ChatGPTSessionStore.swift MVP/App/Account/PlanCredentialStorage.swift \
    MVP/NetworkChecks/*.swift -o "$network_build/NetworkChecks"
"$network_build/NetworkChecks" 2>&1 | tee .test-results/network-checks.txt
