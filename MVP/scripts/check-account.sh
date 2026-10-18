#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
account_build="$project_root/.local-build/account"
mkdir -p "$account_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$account_build/clang"
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name SubscriptionCore MVP/Subscription/Sources/SubscriptionCore/*.swift \
    -emit-module-path "$account_build/SubscriptionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libSubscriptionCore.dylib \
    -o "$account_build/libSubscriptionCore.dylib"
swiftc -swift-version 6 -parse-as-library \
    -I "$account_build" -L "$account_build" -lSubscriptionCore \
    -Xlinker -rpath -Xlinker "$account_build" \
    MVP/App/Account/ChatGPTSessionStore.swift MVP/App/Account/PlanCredentialStorage.swift \
    MVP/AccountChecks/*.swift -o "$account_build/AccountChecks"
"$account_build/AccountChecks" 2>&1 | tee .test-results/account-checks.txt
