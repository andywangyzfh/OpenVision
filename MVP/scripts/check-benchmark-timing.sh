#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
benchmark_build="$project_root/.local-build/benchmark-timing"
mkdir -p "$benchmark_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$benchmark_build/clang"
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name SubscriptionCore MVP/Subscription/Sources/SubscriptionCore/*.swift \
    -emit-module-path "$benchmark_build/SubscriptionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libSubscriptionCore.dylib \
    -o "$benchmark_build/libSubscriptionCore.dylib"
swiftc -swift-version 6 -parse-as-library \
    -I "$benchmark_build" -L "$benchmark_build" -lSubscriptionCore \
    -Xlinker -rpath -Xlinker "$benchmark_build" \
    MVP/App/Account/ChatGPTPlanClient.swift MVP/App/Account/ChatGPTSessionStore.swift MVP/App/Account/PlanCredentialStorage.swift \
    MVP/NetworkChecks/MockTransport.swift MVP/BenchmarkChecks/*.swift -o "$benchmark_build/BenchmarkTimingChecks"
"$benchmark_build/BenchmarkTimingChecks" 2>&1 | tee .test-results/benchmark-timing-checks.txt
