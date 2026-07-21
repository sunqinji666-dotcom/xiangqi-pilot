# XiangqiPilot

> Um cockpit de jogos de tabuleiro para macOS: observa, valida e só age quando é seguro.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **Português (Brasil)**

Criado por **Jacksun (孙秦吉)** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

XiangqiPilot auxilia no xadrez chinês e no Gomoku: reconhece a janela, calibra o tabuleiro, valida a posição e sugere lances do motor. Cliques são opcionais e exigem verificações da janela, geometria, posição, lance e atualidade da imagem antes e depois da ação. Não é automação cega.

Requer macOS 14+ e Xcode 26+; Apple Silicon é recomendado. Execute `scripts/test.sh` e depois use `scripts/setup-local-signing.sh` e `scripts/build-app.sh` para compilar localmente. Conceda gravação de tela e acessibilidade somente quando necessário.

Licença: [MIT License](../LICENSE). Pikafish e outros componentes de terceiros mantêm seus próprios termos; consulte [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
