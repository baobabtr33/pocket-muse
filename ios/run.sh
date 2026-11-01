#!/bin/bash
# Build Pocket Muse and install it on the connected iPhone.
#   ios/run.sh            build + install + launch
#   ios/run.sh --export   re-export the latest pack first (after pack.py --demo)
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--export" || ! -f Bundle/pack.json ]]; then
  (cd .. && TOKENIZERS_PARALLELISM=false uv run python export_ios.py)
fi

xcodegen -q
# mlx-swift ships a build-tool plugin (CudaBuild); Xcode asks to trust it once.
# -skipPackagePluginValidation trusts it for this command-line build.
xcodebuild -project PocketMuse.xcodeproj -scheme PocketMuse -configuration Release \
  -destination 'generic/platform=iOS' -clonedSourcePackagesDirPath .spm -derivedDataPath build \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation build > build.log 2>&1 \
  || { grep -E "error:|failed" build.log | sort -u | head -30; echo "Build failed. Full log: ios/build.log"; exit 1; }
echo "✓ Built"

APP=build/Build/Products/Release-iphoneos/PocketMuse.app
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ {print $3; exit}')
[[ -z "$DEVICE" ]] && { echo "No paired iPhone found. Connect it and unlock it."; exit 1; }
echo "Installing on $DEVICE (about 1.4 GB, takes a minute) ..."
xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
xcrun devicectl device process launch --device "$DEVICE" com.baobabtr33.pocketmuse > /dev/null
echo "✓ Pocket Muse running on your iPhone"
