# XiangqiPilot

> 先觀察、再驗證局面，確認安全後才執行的 macOS 棋盤遊戲駕駛艙。

[简体中文](../README.md) · **繁體中文** · [English](README.en.md) · [日本語](README.ja.md)

作者與聯絡方式：**Jacksun（孙秦吉）** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

XiangqiPilot 可協助中國象棋與五子棋：辨識目標視窗、校準棋盤、驗證局面、提供引擎候選，以及在多重檢查通過後進行可選的點擊。它不是盲目自動化腳本；點擊前會檢查視窗、棋盤幾何、局面、候選走法和畫面是否過期，點擊後也會再確認結果。

需要 macOS 14+、Xcode 26+，建議使用 Apple Silicon。可先執行 `scripts/test.sh`，再以 `scripts/setup-local-signing.sh` 和 `scripts/build-app.sh` 在本機建構。僅在需要相關功能時授與螢幕錄製與輔助使用權限。

本專案採用 [MIT License](../LICENSE)。Pikafish 等第三方元件保留各自條款，請參閱 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
