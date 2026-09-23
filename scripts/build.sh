#!/bin/sh
# Builds deskdash and wraps it in deskdash.app (bundle ID local.deskdash), which is what the login service runs
# (scripts/install-service.sh).
#
# Why an app bundle: macOS Local Network privacy tracks a bare executable by its Mach-O UUID, which changes with
# every build, so each rebuild silently lost the permission ("Local network prohibited"). For an app registered
# with LaunchServices, macOS looks up the current executable by bundle ID and keeps the permission.
#
# The new bundle is assembled beside the old one and swapped in by rename, so a running service keeps its
# (old) executable until the service restarts.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

app=deskdash.app
staging=$app.new
rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS"
cp .build/release/deskdash "$staging/Contents/MacOS/deskdash"
cp Support/Info.plist "$staging/Contents/Info.plist"
plutil -lint -s "$staging/Contents/Info.plist"
codesign --force --sign - --identifier local.deskdash "$staging"

rm -rf "$app.old"
[ -d "$app" ] && mv "$app" "$app.old"
mv "$staging" "$app"
rm -rf "$app.old"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "built $PWD/$app"
