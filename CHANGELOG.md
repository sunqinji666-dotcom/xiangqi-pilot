# XiangqiPilot 变更日志

## 版本规则
- 主版本.次版本.修订号（如 v0.2.0）
- 每次修改代码必须递增版本号
- 回滚方法：`git checkout <版本号对应的commit>` 或按下方说明手动还原

---

## v0.3.0 — 象棋巫师连续对局同步与安全校验
**日期：** 2026-07-19
**改动内容：**
- 新增象棋巫师可访问性树与 Vision 双通道棋谱读取
- 支持根据最新棋谱行解析唯一合法走法，并识别胜负和棋终局提示
- 支持连续两步局面变化的同步，避免第二步因高亮、装饰或对手应手而丢失
- 增强棋盘校准：窗口平移时更新点击坐标，只有缩放时才要求重新校准
- 加强自动执行、重复设防、目标窗口和状态转换的安全门控
- 补充棋谱解析、连续变化、终局提示、窗口平移和点击执行测试
- 新增验证截图：`docs/validation/xiangqi-auto-win-2026-07-20.png`

---

## v0.1.0（基线）
- 当前代码状态，53 个测试全部通过
- 已知问题：第二步执行时识别失败（见 v0.2.0 修复）

---

## v0.2.0 — 修复"第二步不走"
**日期：** 2026-07-20
**问题：** 第一步执行成功后，系统立刻调用 analyzeCurrentPosition()，此时 sideToMove 已翻转为对方。自动模式下会尝试替对方走棋，与象棋巫师自身 AI 冲突，导致画面变化 → 点击失败或识别漂移。
**改动文件：** `Sources/XiangqiPilotApp/Runtime/PilotRuntime.swift`
**改动内容：**
- execute() 方法末尾：删除 `await analyzeCurrentPosition()`
- 替换为 `presentation.phase = .observing`，进入观察等待
- 对方走棋后由 reconcileTrustedPosition() 检测变化并自动触发分析
**回滚方法：** 将 `presentation.phase = .observing` 改回 `await analyzeCurrentPosition()`

---
