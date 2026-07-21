# XiangqiPilot

> Un cockpit de jeux de plateau pour macOS : il observe, vérifie, puis n’agit que lorsque c’est sûr.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **Français**

Créé par **Jacksun (孙秦吉)** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

XiangqiPilot aide pour le xiangqi et le gomoku : détection de fenêtre, calibration du plateau, validation de position et suggestions du moteur. Les clics sont facultatifs et exigent des vérifications de la fenêtre, de la géométrie, de la position, du coup et de la fraîcheur de l’image avant et après l’action. Ce n’est pas un script aveugle.

macOS 14+, Xcode 26+ et Apple Silicon sont recommandés. Lancez `scripts/test.sh`, puis `scripts/setup-local-signing.sh` et `scripts/build-app.sh` pour construire localement. N’accordez les autorisations d’enregistrement d’écran et d’accessibilité qu’en cas de besoin.

Licence : [MIT License](../LICENSE). Pikafish et les autres composants tiers conservent leurs propres conditions ; voir [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
