#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    printf 'Usage: %s [--test | --test-syphon | --test-all]\n' "$0"
}

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

products="$PWD/.build/TestProducts"
derived_data="$PWD/.build/TestDerivedData"
case "${1:-}" in
    "")
        products="$PWD/.build"
        derived_data="$PWD/.build/DerivedData"
        action=(build)
        ;;
    --test) action=(-parallel-testing-enabled NO -only-testing:BeamerProjectorTests/PDFTests test) ;;
    --test-syphon) action=(-parallel-testing-enabled NO -only-testing:BeamerProjectorTests/SyphonTests test) ;;
    --test-all) action=(-parallel-testing-enabled NO test) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "Beamer Projector.xcodeproj" -scheme "Beamer Projector" \
    -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived_data" CONFIGURATION_BUILD_DIR="$products" "${action[@]}"
if [[ "${1:-}" == "" ]]; then
    printf '%s\n' "$PWD/.build/Beamer Projector.app"
fi
