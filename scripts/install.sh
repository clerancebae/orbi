#!/bin/zsh
# Builds Orbi (Release), installs it to /Applications, and relaunches it.
# Usage: scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Orbi.xcodeproj -scheme Orbi -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build -quiet

# Quit any running copy (installed, build folder, or Xcode's) so only one menu bar icon exists.
osascript -e 'tell application id "com.berke.Orbi" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do pgrep -f "Orbi.app/Contents/MacOS/Orbi" >/dev/null || break; sleep 0.25; done
pkill -f "Orbi.app/Contents/MacOS/Orbi" 2>/dev/null || true

rm -rf /Applications/Orbi.app
cp -R build/Build/Products/Release/Orbi.app /Applications/
# Make sure LaunchServices routes orbi:// to the installed copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Orbi.app
open /Applications/Orbi.app
echo "Installed and launched /Applications/Orbi.app"
