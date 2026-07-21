# XiangqiPilot

> Un centro de control para juegos de tablero en macOS: observa, verifica y actúa solo cuando es seguro.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **Español**

Creado por **Jacksun (孙秦吉)** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

XiangqiPilot ayuda con ajedrez chino y Gomoku: reconoce la ventana, calibra el tablero, valida la posición y ofrece sugerencias del motor. Los clics son opcionales y requieren comprobaciones de ventana, geometría, posición, jugada y actualidad de la imagen antes y después de actuar. No es un script de automatización ciega.

Requiere macOS 14+, Xcode 26+ y se recomienda Apple Silicon. Ejecuta `scripts/test.sh`, después `scripts/setup-local-signing.sh` y `scripts/build-app.sh` para compilar localmente. Concede permisos de grabación de pantalla y accesibilidad solo cuando los necesites.

Licencia: [MIT License](../LICENSE). Pikafish y otros componentes de terceros conservan sus propias condiciones; consulta [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
