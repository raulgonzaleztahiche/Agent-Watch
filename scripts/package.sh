#!/usr/bin/env bash
# Builds the app and packs it for distribution: dist/AgentWatch-<version>-arm64.zip plus its SHA-256.
# Usage: scripts/package.sh [version]
#
# Apple Silicon only, ad-hoc signed (no Apple certificate): it runs fine, but macOS Gatekeeper asks
# whoever downloads it to allow it once. See "Install from a release" in the README.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
ZIP="dist/AgentWatch-${VERSION}-arm64.zip"

[ "$(uname -m)" = "arm64" ] || { echo "Build on an Apple Silicon Mac: the app is arm64 only." >&2; exit 1; }

scripts/build-app.sh "$VERSION"

# ditto keeps the code signature and the bundle's metadata intact; a plain zip may not.
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent dist/AgentWatch.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

# Prove the zip is good: unpack it elsewhere and check the signature survived.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict "$CHECK/AgentWatch.app"

echo "Packed $ZIP"
cat "$ZIP.sha256"
