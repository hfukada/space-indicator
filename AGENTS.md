# SpaceIndicator

A macOS menu bar app bundling three small utilities: a virtual desktop (Space) indicator, a linear-scroll toggle, and a Claude Code usage monitor.

## Project structure

```
Package.swift                          Swift package manifest
Info.plist                             App bundle metadata (LSUIElement=true, no dock icon)
build.sh                               Build + package into SpaceIndicator.app
Sources/SpaceIndicator/main.swift      AppKit app entry point: Space indicator + scroll toggle menu
Sources/SpaceIndicator/ClaudeUsage.swift  Second status item: Claude Code usage monitor
```

## How it works

### Space indicator (main.swift)
- Uses private CoreGraphics APIs (`CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`) — there is no public API for reading Space info on macOS.
- Listens for `NSWorkspace.activeSpaceDidChangeNotification` to detect space switches.
- Shows a plain number (or `·`-joined numbers per display) in the menu bar. No dock icon.

### Linear scroll toggle (main.swift)
- Menu item that toggles scroll acceleration via the private `IOHIDSetScrollAcceleration` IOKit call (linear when on, default acceleration when off).
- State persisted in `UserDefaults` (`linearScroll` key), defaults to enabled on first launch.

### Claude usage monitor (ClaudeUsage.swift)
- A separate status bar item (sparkles icon) showing current session usage %, click to open a popover.
- Runs `claude -p '/usage'` and parses the "Current session" / "Current week" percentage lines, on a 5-minute timer. The popover shows the last cached result from that timer rather than fetching on click.
- Also scans `~/.claude/projects/**/*.jsonl` transcripts for per-message token usage to render a 24-hour bar chart; this chart does refetch each time the popover opens.

Menu: Linear Scroll toggle, separator, Quit.

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
