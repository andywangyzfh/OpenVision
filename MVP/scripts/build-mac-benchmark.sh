#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bench_build="${MVP_BENCH_BUILD_ROOT:-$project_root/.local-build/mac-benchmark}"
bench_app="$bench_build/OpenVision Benchmark.app"
mkdir -p "$bench_app/Contents/MacOS" "$bench_build/modules" "$bench_build/clang"
export CLANG_MODULE_CACHE_PATH="$bench_build/clang"
for module in SubscriptionCore OpenVisionCore; do
    if [[ "$module" == SubscriptionCore ]]; then source_dir=MVP/Subscription/Sources/SubscriptionCore; else source_dir=MVP/Core/Sources/OpenVisionCore; fi
    swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name "$module" "$source_dir"/*.swift \
      -emit-module-path "$bench_build/modules/$module.swiftmodule" -Xlinker -install_name -Xlinker "@rpath/lib$module.dylib" \
      -o "$bench_app/Contents/MacOS/lib$module.dylib"
done
swiftc -swift-version 6 -parse-as-library -I "$bench_build/modules" -L "$bench_app/Contents/MacOS" -lSubscriptionCore -lOpenVisionCore \
  -Xlinker -rpath -Xlinker @executable_path \
  MVP/App/Account/ChatGPTPlanClient.swift MVP/App/Account/ChatGPTSessionStore.swift \
  MVP/App/Account/PlanCredentialStorage.swift MVP/App/Account/PlanAuthCallback.swift MVP/Benchmarks/*.swift \
  -o "$bench_app/Contents/MacOS/OpenVisionBenchmark"
mkdir -p "$bench_app/Contents/Resources"
python3 - "$bench_app/Contents/Info.plist" "$project_root" <<'PYBUILD'
import hashlib,json,plistlib,subprocess,sys
from pathlib import Path
root=Path(sys.argv[2]); paths=[]
for folder in ['MVP/Subscription/Sources/SubscriptionCore','MVP/Core/Sources/OpenVisionCore','MVP/Benchmarks']:
 paths.extend((root/folder).glob('*.swift'))
for name in ['ChatGPTPlanClient','ChatGPTSessionStore','PlanCredentialStorage','PlanAuthCallback']:
 paths.append(root/('MVP/App/Account/'+name+'.swift'))
inputs={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
digest=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()
try:
 head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,stderr=subprocess.DEVNULL,text=True).strip()
 dirty=bool(subprocess.check_output(['git','status','--porcelain','--untracked-files=all','--','MVP'],cwd=root,text=True).strip())
except subprocess.CalledProcessError:head='not-a-git-checkout';dirty=True
info={'CFBundleExecutable':'OpenVisionBenchmark','CFBundleIdentifier':'org.openvision.local-benchmark','CFBundleName':'OpenVision Benchmark','CFBundleVersion':'1','CFBundlePackageType':'APPL','OpenVisionSource':'sha256:'+digest,'OpenVisionGitHead':head,'OpenVisionDirty':dirty,'NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
with open(sys.argv[1],'wb') as f:plistlib.dump(info,f)
(Path(sys.argv[1]).parent/'Resources/source-manifest.json').write_text(json.dumps({'input_sha256':inputs,'source_digest':digest,'git_head':head,'dirty':dirty},indent=2)+'\n')
PYBUILD

codesign --force --deep --sign - "$bench_app"
echo "Built without login or inference: $bench_app"
echo 'Launch only when the user can personally complete official sign-in and current-account usage checks.'
