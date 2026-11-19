#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(python3 scripts/release-version.py)"
tag="v$version"
sha="$(git rev-parse HEAD)"
repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
out="build/releases/$version"
dmg="Edge-PiP-$version-macOS.dmg"
ext="Edge-PiP-Controls-$version.zip"
(cd "$out" && shasum -a 256 -c SHA256SUMS.txt)
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    if [[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" == true ]]; then
        target="$(gh release view "$tag" --repo "$repo" --json targetCommitish --jq .targetCommitish)"
        [[ "$target" == "$sha" ]] || { echo "Draft belongs to another commit." >&2; exit 1; }
    else
        [[ "$(gh api "repos/$repo/commits/$tag" --jq .sha)" == "$sha" ]] || {
            echo "Release belongs to another commit." >&2; exit 1
        }
        for name in "$dmg" "$ext" SHA256SUMS.txt; do
            gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | grep -Fxq "$name"
        done
        exit 0
    fi
else
    gh release create "$tag" --repo "$repo" --target "$sha" --draft \
        --title "Edge PiP $version" --generate-notes
fi
gh release upload "$tag" --repo "$repo" --clobber "$out/$dmg" "$out/$ext" "$out/SHA256SUMS.txt"
gh release edit "$tag" --repo "$repo" --draft=false
