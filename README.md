# XiangqiPilot

XiangqiPilot is a macOS application for assisting Chinese chess (xiangqi) analysis and play.

## Requirements

- macOS 14 or later
- Swift 5.10 or later
- Screen Recording and Accessibility permissions may be required for desktop capture and click execution

## Project structure

- `Sources/XiangqiCore` — board model, move rules, game state, and search engine
- `Sources/XiangqiPilotApp` — macOS application and user interface
- `Tests` — unit and safety tests
- `scripts` — local test, build, and signing helpers

## Build and test

```bash
swift test
swift build
```

For the app packaging flow, see the scripts in `scripts/`.

## Status

This project is under active development.
