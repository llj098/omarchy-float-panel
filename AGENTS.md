# Project constraints

## C++ / Lua boundary

- 本项目的 C++ native code 只作为 bridge：暴露 Lua 无法直接取得的原始 compositor 事实，或提供不包含业务决策的通用底层机制。
- C++ 不得实现 placement、geometry、persistence、workspace mode、window eligibility、应用分类或其他业务策略；不得加入应用 class/title 特例。
- 所有业务判断、状态管理和策略执行必须放在 Lua 侧，以便审计、测试和修改时不依赖 Hyprland C++ ABI。
- 只有在 Lua/公开 Hyprland API 经源码核实确实无法实现、且属于极特殊情况时，才考虑扩展 C++；扩展必须保持应用无关和最小化，并在实施前明确说明必要性、边界和替代方案，取得用户确认。
