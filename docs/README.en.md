# XiangqiPilot

> A macOS board-game cockpit that observes first, verifies the position, then acts only when it is safe.

[简体中文](../README.md) · [繁體中文](README.zh-TW.md) · **English** · [日本語](README.ja.md)

XiangqiPilot helps with Chinese chess and Gomoku: window-aware capture, board calibration, position validation, engine suggestions, and optional guarded clicks. It is deliberately not a blind automation script. Before any click, it checks the target window, board geometry, game state, candidate move, and frame freshness; after a click, it verifies the result again.

Requires macOS 14+, Xcode 26+, and preferably Apple Silicon. Run the test suite with `scripts/test.sh`, then use `scripts/setup-local-signing.sh` and `scripts/build-app.sh` to build locally. Grant Screen Recording and Accessibility permission only when you choose to use their related capabilities.

The project is released under the [MIT License](../LICENSE). Third-party components such as Pikafish retain their own terms; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
