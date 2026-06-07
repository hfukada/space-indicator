# SpaceIndicator

A minimal macOS menu bar app that displays the current virtual desktop (Space) number.

## Project structure

```
Package.swift                     Swift package manifest
Info.plist                        App bundle metadata (LSUIElement=true, no dock icon)
build.sh                          Build + package into SpaceIndicator.app
Sources/SpaceIndicator/main.swift Single-file AppKit app
```

## How it works

- Uses private CoreGraphics APIs (`CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`) — there is no public API for reading Space info on macOS.
- Listens for `NSWorkspace.activeSpaceDidChangeNotification` to detect space switches.
- Shows a plain number in the menu bar. No dock icon.
- Single menu item: Quit.

## Build & run

```bash
./build.sh        # compiles and creates SpaceIndicator.app
open SpaceIndicator.app
```

## Install

```bash
cp -r SpaceIndicator.app /Applications/
# Then add to Login Items in System Settings → General → Login Items
```

## Notes

- macOS 13+ required (built against macOS 26 SDK).
- The private CGS APIs are undocumented but stable across macOS versions in practice.
- On multi-monitor setups, shows the Space index within the active display's space list.
