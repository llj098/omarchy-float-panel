# Omarchy 4.5 兼容性与面板消失排查

核查日期：2026-11-08。对象是 `fatlj.float-panel`，不是把 Omarchy 4.5 官方 floating 模式作为替代实现。

## 环境与结论

| 项目 | 本机版本 / 结果 |
| --- | --- |
| Omarchy / settings | 4.5.0-3；2026-11-05 从 4.0.6 升级 |
| Hyprland | 0.56.2-4，commit `efb50993780079460b0cbed1363e2166a2de1d9f`；4.5 升级当日没有变更 |
| Aquamarine / Hyprutils | 0.15.1 / 0.14.2 |
| Quickshell | 0.3.2.r7.g2b4501a-1；在 4.5 之前已安装 |
| Qt | 6.12；QML 使用现有 `BarWidget` / `WidgetButton` / `BarIconButton` API |
| Native bridge | 本次没有修改、替换或热卸载 native 插件；不能用 Shell socket 缺陷推断 compositor 崩溃 |

4.5 的 bar 插件 manifest、多个 widget 实例和 keepLoaded overlay 接口仍适用。`listPlugins` 的 `active:false` 不等于插件崩溃：它并不是每个 bar widget 的存活状态。`shell debugBarGeometry` 才能区分 widget 是否存在、是否可见以及是否有尺寸。

4.5 会按 monitor 分配不同的 workspace 编号段。旧代码把 Float 状态当作 workspace 名称白名单，未记录的 workspace 即使有窗口也隐藏 TaskList。这是“消失”路径，不是进程退出。新实现默认让所有普通 workspace 使用本插件的 Float，新建 workspace 注册原生 Float rule；手动 Tiling 作为显式例外持久保存。空 workspace 的 TaskList 仍按设计隐藏，Float Toggle 保持显示。

### 官方 floating 的冲突边界

`default/hypr/workspace-modes.lua` 是另一套状态和 placement 策略：有自己的 float rule、窗口 tag、geometry、input 设置及 titlebars。不要在同一 workspace 同时开启两套 floating 管理。保留官方 dwindle/scrolling 作为底层 tiled layout，使用本插件的 `Super+Shift+T` 或 Float Toggle 管理 Float/Tiling；官方 `Super+L` / Workspace Layout 菜单并不是本插件的模式开关。

检查时官方保存的 workspace 模式是 scrolling，没有加载 hyprbars，只有 float-panel native bridge。没有擅自改写系统 Lua、官方模式文件或 C++ 业务策略。

模式和 geometry 仍按 workspace 名称持久化；4.5 若重新编号 workspace，旧名称的 Tiling 例外/geometry 不会自动迁移到新名称。隐藏窗口仍按其来源 workspace ID 编码；如发生编号变更，旧 special workspace 的恢复方式见 README。这些不是已验证的自动迁移能力。

## 可复现的 Socket 崩溃缺陷

源码依据：[Quickshell 2b4501a socket.cpp](https://github.com/quickshell-mirror/quickshell/blob/2b4501a/src/io/socket.cpp)。

`Socket::onSocketError()` 发出 QML `error` 信号之后仍访问 `this->socket`。若 `onError` 同步设置 `connected = false`，断开信号会重入 `onSocketDisconnected()`，后者将该指针清空；返回错误回调后继续使用它，会崩溃。

旧 TaskList 的 `onError` 直接断开自身；旧 AppSwitcher 的 `onError` 调用 `resetRequest()`，也会同步断开发出错误的请求 socket。在本机独立、无桌面窗口的 Quickshell 测试中，同样的同步清理路径在 peer close 后产生 `QObject::disconnect: Unexpected nullptr parameter` 和 `Quickshell has crashed`。改成 `Qt.callLater()` 后，首次连接失败与连续两次 peer disconnect 均能恢复。

修复：

- 请求 socket 的错误清理延后到 native 错误回调返回后，避免重入销毁。
- 唯一 AppSwitcher 的独立 event socket 使用有限退避自动重连（250ms 至 4s，仅断线期间运行）。
- event stream 丢失时取消旧 selection，不在重连后重放过期 focus 操作。
- 请求快照先于 event stream 恢复时，等待连接完成信号，而不是丢弃快照。focus handoff 仍严格等待 `closelayer`，没有引入 focus/geometry timer。
- FileView 非“文件不存在”的读取错误保留已知模式，不把临时失败误判成状态重置。

旧 event socket 在下一次 Alt-Tab 时已有手动连接尝试；问题不是绝对无法重连，而是缺少自动恢复及连接时序保护。

**证据边界：** 用户描述的是自己的面板退出。现存 journal 没有给出该次故障对应的 Shell core；因此上述是已复现、已修复的确定缺陷，不能声称解释了每一次历史消失。保留的 2026-11-07 Hyprland core 在 Aquamarine 退出清理路径，和这里的 Shell socket 缺陷不能混为一谈。升级时间上的相关性不证明缺陷由 4.5 新引入。

## 验证与诊断

```bash
./scripts/validate.sh
omarchy-shell shell debugBarGeometry
omarchy-shell shell call fatlj.float-panel status '{}'
journalctl --user -t omarchy-shell -g 'fatlj\.float-panel'
```

`status` 是只读方法，返回 event socket 连接、overlay lifecycle、pending snapshot 状态。debug marker 开启后，新增 `tasklist.state` / `tasklist.unloaded` / `switcher.unloaded` / socket lifecycle 记录，用于区分隐藏、宿主卸载与连接丢失。所有运行时诊断仍走带 `[fatlj.float-panel]` 前缀的 QML `console.info()` → journal，不写私有日志，也不记录窗口标题或内容。

自动测试覆盖旧模式文件迁移、默认 Float、新 monitor workspace、Tiling 持久化、named workspace、Lua geometry 回归、真实 Quickshell Socket 错误/重连及 Alt-Tab 生命周期。测试的 Quickshell 使用 offscreen、独立 runtime/cache 和临时 Unix socket，不连接用户 compositor；它不等同于真实桌面的多天稳定性验收。

## 更新与回滚

Lua、TaskList、TaskListModel、AppSwitcher、`ReconnectingEventSocket.qml` 必须作为一组更新。模式文件 v2 保存显式 Tiling 例外，旧的正向 Float 列表会自然迁移为默认 Float。不要在新 QML 与旧 Lua 混用时判断模式是否正确。

更新完成、文件 watcher 稳定后 reload Hyprland 配置并重启一次 Omarchy Shell；不需要重启桌面或热卸载 native bridge。回滚到旧版本时，必须同时恢复备份的旧 `float-panel-workspaces` 文件，因为旧版不理解 v2。geometry 文件格式未改变。
