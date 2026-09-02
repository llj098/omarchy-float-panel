# Project constraints

## C++ / Lua boundary

- 本项目的 C++ native code 只作为 bridge：暴露 Lua 无法直接取得的原始 compositor 事实，或提供不包含业务决策的通用底层机制。
- C++ 不得实现 placement、geometry、persistence、workspace mode、window eligibility、应用分类或其他业务策略；不得加入应用 class/title 特例。
- 所有业务判断、状态管理和策略执行必须放在 Lua 侧，以便审计、测试和修改时不依赖 Hyprland C++ ABI。
- 只有在 Lua/公开 Hyprland API 经源码核实确实无法实现、且属于极特殊情况时，才考虑扩展 C++；扩展必须保持应用无关和最小化，并在实施前明确说明必要性、边界和替代方案，取得用户确认。

## Terminology

- 面向用户的说明、诊断结论、日志解读和文档默认只使用 Hyprland 的统一抽象术语，例如 window、parent、transient、window type、application-specified placement、workspace、monitor 和 geometry。
- 不并列展开不同显示协议的底层对应关系；应用明确指定位置时统一称为 `application-specified placement`，不得在普通说明中使用 `PPosition`、`USPosition` 等底层协议术语。
- 只有用户明确询问底层协议，或问题只能通过特定协议字段定位时，才说明该实现细节；说明后必须立即回到 Hyprland 统一窗口模型。

## Logging

- 所有运行时诊断日志必须通过官方 widget 相同的 QML `console.info()` 路径写入 systemd journal，并统一使用 `[fatlj.float-panel]` 前缀；Lua 仅通过 Hyprland 内置 custom IPC event 发送隐私安全日志行，由唯一 AppSwitcher 实例的独立 event socket 接收并输出。
- 禁止创建项目私有日志文件、调用 `systemd-cat` 子进程、为日志扩展 C++ bridge，或在插件中实现容量限制与轮转；保留和轮转统一由 journald 配置管理。
- 调试日志由 `~/.local/state/omarchy/float-panel-debug` marker 统一启停；reflow 只在 work area 或窗口 geometry 实际变化时记录，每个变化窗口只写一条，no-op 检查不得写日志；正式日志不得记录窗口标题、输入文本、聊天/页面内容、图片内容或其他用户内容。
