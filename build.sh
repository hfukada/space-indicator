#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release 2>&1

APP="SpaceIndicator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/SpaceIndicator "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

echo "Done: $APP"
echo ""
echo "To run:    open $APP"
echo "To install: cp -r $APP /Applications/"
