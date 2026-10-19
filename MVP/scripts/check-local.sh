#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
mkdir -p .local-build/clang .local-build/modules .test-results
export CLANG_MODULE_CACHE_PATH="$project_root/.local-build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.local-build/modules"
swift --version > .test-results/swift-version.txt
swift run --disable-sandbox --package-path MVP/Core --scratch-path .local-build/core CoreChecks | tee .test-results/core-checks.txt
swift run --disable-sandbox --package-path MVP/Subscription --scratch-path .local-build/subscription SubscriptionChecks | tee .test-results/subscription-checks.txt
bash MVP/scripts/check-flow.sh
bash MVP/scripts/check-inputs.sh
bash MVP/scripts/check-network.sh
bash MVP/scripts/check-account.sh
bash MVP/scripts/check-callback.sh
swiftc -frontend -parse MVP/App/*.swift MVP/App/Account/*.swift
plutil -lint MVP/Resources/Info.plist MVP/Resources/en.lproj/InfoPlist.strings MVP/Resources/zh-Hans.lproj/InfoPlist.strings
xcodegen generate --spec MVP/project.yml
echo 'Portable checks passed. This is NOT an iOS build, simulator run, or local acceptance gate.'
