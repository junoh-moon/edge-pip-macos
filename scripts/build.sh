#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/Edge PiP.app"
bin="$app/Contents/MacOS"
mkdir -p "$bin" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"
cp Resources/{AppIcon.icns,MenuBarTemplate.pdf,PiPTitles.txt} "$app/Contents/Resources/"

target="$(uname -m)-apple-macos15.0"
xcrun swiftc -target "$target" -Osize Sources/*.swift -o "$bin/EdgePiP"
for helper in EdgePiPRelay EdgePiPGuard; do
    xcrun clang -target "$target" -Os "Sources/$helper.c" -o "$bin/$helper"
done

sign() {
    local path="$1" identifier="$2"
    if [[ -n "${EDGE_PIP_SIGNING_SHA1:-}" ]]; then
        /usr/bin/codesign --force --sign "$EDGE_PIP_SIGNING_SHA1" --timestamp=none \
            --identifier "$identifier" --requirements "=designated => identifier \"$identifier\" and certificate leaf = H\"$EDGE_PIP_SIGNING_SHA1\"" "$path"
    else
        /usr/bin/codesign --force --sign - --identifier "$identifier" "$path"
    fi
}
sign "$bin/EdgePiPRelay" local.edgepip.companion.relay
sign "$bin/EdgePiPGuard" local.edgepip.companion.guard
sign "$app" local.edgepip.companion
/usr/bin/codesign --verify --strict --deep "$app"
