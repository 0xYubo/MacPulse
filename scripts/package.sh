#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/dist"
app_dir="$output_dir/MacPulse.app"

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/macpulse-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/macpulse-swiftpm-cache"

cd "$project_dir"
swift build -c release

mkdir -p "$app_dir/Contents/MacOS"
cp ".build/release/MacPulse" "$app_dir/Contents/MacOS/MacPulse"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
