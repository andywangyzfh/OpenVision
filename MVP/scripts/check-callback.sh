#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
callback_build="$project_root/.local-build/callback"
mkdir -p "$callback_build/clang" .test-results
export CLANG_MODULE_CACHE_PATH="$callback_build/clang"

# Compile the actual production callback helpers and actual SubscriptionCore. Only synthetic
# HTTP on 127.0.0.1 is used; this never starts a browser or exchanges OAuth/user credentials.
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module \
    -module-name SubscriptionCore MVP/Subscription/Sources/SubscriptionCore/*.swift \
    -emit-module-path "$callback_build/SubscriptionCore.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libSubscriptionCore.dylib \
    -o "$callback_build/libSubscriptionCore.dylib"
swiftc -swift-version 6 -parse-as-library \
    -I "$callback_build" -L "$callback_build" -lSubscriptionCore \
    -Xlinker -rpath -Xlinker "$callback_build" \
    MVP/App/Account/PlanAuthCallback.swift MVP/CallbackChecks/*.swift \
    -o "$callback_build/CallbackChecks"
"$callback_build/CallbackChecks" | tee .test-results/callback-checks.txt
