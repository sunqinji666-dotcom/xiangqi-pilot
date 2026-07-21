# XiangqiPilot

> Ein macOS-Cockpit für Brettspiele: erst beobachten, dann prüfen und nur bei Sicherheit handeln.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **Deutsch**

XiangqiPilot unterstützt chinesisches Schach und Gomoku: Fenstererkennung, Brettkalibrierung, Positionsprüfung und Engine-Vorschläge. Klicks sind optional und erfordern vor und nach der Aktion Prüfungen von Fenster, Geometrie, Stellung, Zug und Bildaktualität. Es ist kein blindes Automatisierungsskript.

Erfordert macOS 14+, Xcode 26+; Apple Silicon wird empfohlen. Führe `scripts/test.sh` aus und baue anschließend lokal mit `scripts/setup-local-signing.sh` und `scripts/build-app.sh`. Erteile Bildschirmaufnahme- und Bedienungshilfenrechte nur bei Bedarf.

Lizenz: [MIT License](../LICENSE). Für Pikafish und andere Drittkomponenten gelten deren eigene Bedingungen; siehe [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
