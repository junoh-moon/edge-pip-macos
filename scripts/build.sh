#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="${EDGE_PIP_BUILD_DIR:-build}"
app="$build_dir/Edge PiP.app"
bin="$app/Contents/MacOS"
mkdir -p "$bin" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"
cp Resources/{AppIcon.icns,MenuBarTemplate.pdf,PiPTitles.txt} "$app/Contents/Resources/"

if [[ -n "${EDGE_PIP_RELEASE_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$EDGE_PIP_RELEASE_VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${EDGE_PIP_BUILD_NUMBER:?}" "$app/Contents/Info.plist"
fi

read -r -a archs <<< "${EDGE_PIP_ARCHS:-$(uname -m)}"
for arch in "${archs[@]}"; do
    target="$arch-apple-macos15.0"
    slice="$build_dir/slices/$arch"
    mkdir -p "$slice"
    xcrun swiftc -target "$target" -Osize Sources/*.swift -o "$slice/EdgePiP"
    for helper in EdgePiPRelay EdgePiPGuard; do
        xcrun clang -target "$target" -Os "Sources/$helper.c" -o "$slice/$helper"
    done
done
for name in EdgePiP EdgePiPRelay EdgePiPGuard; do
    slices=()
    for arch in "${archs[@]}"; do slices+=("$build_dir/slices/$arch/$name"); done
    xcrun lipo -create "${slices[@]}" -output "$bin/$name"
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
