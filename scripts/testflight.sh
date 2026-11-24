#!/bin/zsh
# Sends Navi for iPhone (the app and its keyboard) to TestFlight.
#
# Needs: Xcode signed in to an Apple account on team 77SAW76597
# (Xcode → Settings → Accounts) with the Admin or App Manager role, and an app
# for com.donovanhiland.navi.ios in App Store Connect. Xcode registers the
# bundle IDs and the App Group, makes the distribution certificate and the
# profiles, and uploads with that account. No passwords here.
#
# Usage: scripts/testflight.sh [build-number]
# The build number defaults to the current time (yyyyMMddHHmm), so every
# upload is newer than the last. The version comes from iOS/project.yml.
set -euo pipefail

root=${0:A:h:h}
cd "$root/iOS"
team=77SAW76597
build=${1:-$(date +%Y%m%d%H%M)}
work="$root/build.noindex/testflight"
archive="$work/NaviPhone.xcarchive"

if [[ ! $build =~ '^[0-9]+$' ]]; then
  echo "The build number must be digits only, got: $build" >&2
  exit 1
fi

rm -rf "$work"
mkdir -p "$work"

echo "› Archiving build $build"
xcodegen generate >/dev/null
xcodebuild -project NaviPhone.xcodeproj -scheme NaviPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -derivedDataPath "$root/build.noindex/ios" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build" -quiet archive

cat > "$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "› Signing for the App Store and uploading"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
  -exportPath "$work/upload" -allowProvisioningUpdates

echo "› Build $build uploaded. Apple checks it (about 5–30 minutes), then it shows in"
echo "  App Store Connect → Navi → TestFlight. Add testers there."
