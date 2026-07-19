# XiangqiPilot

XiangqiPilot is a macOS application for assisting Chinese chess (xiangqi) analysis and play.

## Requirements

- macOS 14 or later
- Full Xcode 26 or later (`xcode-select` must point to `/Applications/Xcode.app/Contents/Developer`)
- Screen Recording and Accessibility permissions may be required for desktop capture and click execution

## Project structure

- `Sources/XiangqiCore` — board model, move rules, game state, and search engine
- `Sources/XiangqiPilotApp` — macOS application and user interface
- `Vendor/Pikafish` — optional local Pikafish executable and NNUE network files (not committed)
- `Tests` — unit and safety tests
- `scripts` — local test, build, and signing helpers

## Build and test

```bash
scripts/test.sh
scripts/setup-local-signing.sh # one time per development Mac
scripts/build-app.sh
```

`build-app.sh` deliberately refuses ad-hoc signing. The local signing helper
creates a non-exportable, Code Signing-only identity so Screen Recording and
Accessibility grants continue to match after rebuilds.

When a verified Pikafish build is placed at `Vendor/Pikafish/pikafish`, the
packager signs and embeds it automatically. Pikafish is GPL-3.0 software from
<https://github.com/official-pikafish/Pikafish>; distributions that include it
must also satisfy its source and license obligations. If it is absent or fails
to start, the application automatically falls back to the built-in engine.

Install and always launch the packaged application from a stable path:

```bash
ditto "dist/棋局驾驶舱.app" "/Applications/棋局驾驶舱.app"
open "/Applications/棋局驾驶舱.app"
```

When migrating an older ad-hoc build, reset only this bundle's stale entries
once, then grant both permissions to the newly signed application:

```bash
tccutil reset ScreenCapture com.jacksun.xiangqi-pilot
tccutil reset Accessibility com.jacksun.xiangqi-pilot
```

## Status

This project is under active development.
