# XiangqiPilot

> まず盤面を観察し、局面を検証してから、安全なときだけ実行する macOS 用ボードゲーム・コックピット。

[简体中文](../README.md) · [繁體中文](README.zh-TW.md) · [English](README.en.md) · **日本語**

作者・お問い合わせ：**Jacksun（孙秦吉）** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

XiangqiPilot は中国象棋と五目並べを支援します。対象ウィンドウの認識、盤面キャリブレーション、局面検証、エンジン候補、そして複数の安全確認を通過した場合のみ任意のクリックを行います。盲目的な自動化スクリプトではありません。クリック前にウィンドウ、盤面形状、局面、候補手、フレームの鮮度を確認し、クリック後も結果を検証します。

macOS 14+、Xcode 26+、Apple Silicon 推奨です。まず `scripts/test.sh` を実行し、`scripts/setup-local-signing.sh` と `scripts/build-app.sh` でローカルビルドしてください。画面収録とアクセシビリティの権限は必要な機能を使うときだけ許可します。

本プロジェクトは [MIT License](../LICENSE) で公開されています。Pikafish などの第三者コンポーネントには各自の条件が適用されます。 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) を参照してください。
