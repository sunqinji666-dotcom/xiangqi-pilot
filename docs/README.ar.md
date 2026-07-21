# XiangqiPilot

> قمرة قيادة لألعاب اللوح على macOS: تراقب أولاً وتتحقق، ثم تعمل فقط عندما يكون ذلك آمناً.

[简体中文](../README.md) · [English](README.en.md) · [日本語](README.ja.md) · **العربية**

إعداد وتواصل: **Jacksun (孙秦吉)** · [qinji@jack-sun.com](mailto:qinji@jack-sun.com)

يساعد XiangqiPilot في الشطرنج الصيني وGomoku: يتعرّف على النافذة، ويعاير اللوح، ويتحقق من الوضع، ويقترح نقلات المحرك. النقر اختياري ولا يتم إلا بعد فحص النافذة وهندسة اللوح والوضع والنقلة وحداثة الإطار قبل العمل وبعده. إنه ليس برنامج أتمتة أعمى.

يتطلب macOS 14+ وXcode 26+، ويوصى بـ Apple Silicon. شغّل `scripts/test.sh` ثم ابنِ محلياً عبر `scripts/setup-local-signing.sh` و`scripts/build-app.sh`. امنح إذني تسجيل الشاشة وإمكانية الوصول فقط عند الحاجة.

الترخيص: [MIT License](../LICENSE). تبقى مكوّنات مثل Pikafish خاضعة لشروطها الخاصة؛ راجع [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
