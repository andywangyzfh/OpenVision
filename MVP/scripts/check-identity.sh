#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
identity_build="${MVP_IDENTITY_BUILD_ROOT:-/private/tmp/openvision-identity-transport-checks}"
mkdir -p "$identity_build/clang" "$identity_build/modules" .test-results
export CLANG_MODULE_CACHE_PATH="$identity_build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$identity_build/modules"

# Production metadata verifier + production no-redirect URLSession policy. Issuer/JWKS traffic
# is intercepted by URLProtocol; actual HTTP is loopback-only between two fixture ports.
# Synthetic bearer/refresh strings only. No browser, real OAuth, external server or user token.
swift test --disable-sandbox --package-path MVP/Subscription \
    --scratch-path "$identity_build/build" --filter IdentityTransportTests \
    | tee .test-results/identity-transport-checks.txt
