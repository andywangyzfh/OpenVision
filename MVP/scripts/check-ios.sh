#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
mkdir -p .test-results
# An App Store installation does not always replace the active CLT selection.
# Prefer the installed full Xcode for this process; leave the system selection unchanged.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  selected_developer="$(xcode-select -p 2>/dev/null || true)"
  case "$selected_developer" in
    */CommandLineTools) export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
  esac
fi
if ! xcodebuild -version > .test-results/xcode-version.txt 2>&1; then
  echo 'BLOCKED: full Xcode with iOS Simulator is required; Command Line Tools are insufficient.' >&2
  exit 2
fi
if ! xcodebuild -checkFirstLaunchStatus > .test-results/xcode-first-launch.txt 2>&1; then
  cat .test-results/xcode-first-launch.txt >&2
  echo 'BLOCKED: open Xcode, review its license yourself, and finish first-launch component installation.' >&2
  exit 2
fi
xcodegen generate --spec MVP/project.yml
device_id="$(xcrun simctl list devices available -j | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for v in d["devices"].values() for x in v if x.get("isAvailable") and x["name"].startswith("iPhone")]; print(p[0]["udid"] if p else "")')"
if [ -z "$device_id" ]; then
  echo 'BLOCKED: install an iPhone iOS simulator runtime in Xcode Settings > Components.' >&2
  exit 2
fi
echo "$device_id" > .test-results/simulator-destination.txt
result_path="$project_root/.test-results/MVP-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test -project MVP/OpenVisionMVP.xcodeproj -scheme OpenVisionMVP \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath .local-build/ios -clonedSourcePackagesDirPath .local-build/packages \
  -resultBundlePath "$result_path" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  | tee .test-results/ios-tests.txt
echo 'Simulator build/UI tests passed. Review every remaining A/S acceptance row before approving the local gate.'
