#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bin_path="$(swift build -c release --show-bin-path)"

output="$PWD/build"
mkdir -p "$output"
staging="$(mktemp -d "$output/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

app="$staging/StockDashboard.app"
widget="$app/Contents/PlugIns/StockDashboardWidget.appex"
mkdir -p "$app/Contents/MacOS" "$widget/Contents/MacOS"
cp Bundle/App-Info.plist "$app/Contents/Info.plist"
cp Bundle/Widget-Info.plist "$widget/Contents/Info.plist"
cp "$bin_path/StockDashboard" "$app/Contents/MacOS/"
cp "$bin_path/StockDashboardWidget" "$widget/Contents/MacOS/"

codesign --force --sign - --entitlements Bundle/Local.entitlements "$widget"
codesign --force --sign - --entitlements Bundle/Local.entitlements "$app"
codesign --verify --deep --strict "$app"

rm -rf "$output/StockDashboard.app"
mv "$app" "$output/"
printf '%s\n' "$output/StockDashboard.app"
