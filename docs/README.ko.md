# XiangqiPilot

> 먼저 보드를 관찰하고 상태를 검증한 뒤, 안전할 때만 실행하는 macOS 보드게임 콕핏.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **한국어**

XiangqiPilot은 중국 장기와 오목을 돕습니다. 대상 창 인식, 보드 보정, 상태 검증, 엔진 후보 수 제안, 그리고 여러 안전 검사를 통과한 경우에만 선택적 클릭을 수행합니다. 맹목적인 자동화 스크립트가 아닙니다. 클릭 전 창, 보드 형상, 게임 상태, 후보 수, 프레임 최신성을 확인하고 클릭 후에도 결과를 검증합니다.

macOS 14+, Xcode 26+가 필요하며 Apple Silicon을 권장합니다. `scripts/test.sh`를 실행한 뒤 `scripts/setup-local-signing.sh`와 `scripts/build-app.sh`로 로컬 빌드하세요. 화면 기록과 손쉬운 사용 권한은 필요한 기능에서만 허용하세요.

이 프로젝트는 [MIT License](../LICENSE)로 공개됩니다. Pikafish 등 제3자 구성 요소는 자체 조건을 따릅니다. [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)를 참고하세요.
