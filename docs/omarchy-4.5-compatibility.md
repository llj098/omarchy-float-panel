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

## Titlebar chrome（2026-11-11）

本插件新增可选的 `chrome = "titlebar"`：不再使用隐形的 hover drag strip，而是复用 Omarchy 4.5 的 `omarchy-hyprland-titlebars` 作为 titlebar 渲染层。它不是官方 floating workspace 模式的一部分：Float/Tiling 状态、几何持久化、最小化存储和 Alt-Tab 仍由本插件管理。

配置方式（`~/.config/hypr/hyprland.lua`，必须在插件的 `dofile` 之前）：

```lua
pcall(hl.plugin.load, "/usr/lib/omarchy-hyprland-titlebars/titlebars.so")
float_panel_options = { chrome = "titlebar" }
dofile((os.getenv("HOME") or "") .. "/.config/omarchy/plugins/fatlj.float-panel/hypr/float-panel.lua")
```

- 预加载行是必需的。在 config 求值过程中加载 titlebars 会让它递归 reload 同一份 config；插件自身不加载该包，只在 `hl.plugin.hyprbars` 已存在时配置它。缺少包或未预加载时保留 hover strip，并通过通知/日志提示。
- titlebar 的 `workspace_tag` 由插件打的 `fatlj-float-titlebar` tag 限定；Tiling、special minimized store 和 auxiliary menu/tooltip 窗口不带该 tag。
- titlebar 是主表面之上的 top decoration，并预留 `bar_height`（默认 30px）。插件的 floating bounds 对带 tag 的窗口增加同样的 top inset，所以窗口内容不会钻到 bar 下面；切换回 `hover` 时会显式 reclaim 这 30px，避免窗口永久缩小或停在下方。
- 按钮动作仍走 Lua：close 标准关闭；minimize 写 `special:omarchy-minimized-N`；maximize/双击走几何最大化。不要换成官方 dock 的共享 `special:minimized` store。

### 已验证

- 嵌套合成器（Hyprland 0.56.2）：同时加载 `hyprbars` 与 `float-panel-native`，窗口 tag 为 `fatlj-float-titlebar`，`plugin:hyprbars:enabled=true`、`workspace_tag=fatlj-float-titlebar`、`bar_height=30`；窗口主表面 `at.y` 从 9 变为 39，`size.y` 从 342 变为 312，外框保持工作区高度。
- 真实桌面（会话锁屏状态，只读 geometry/tag 核对）：titlebar 模式下窗口 `at.y=42`、`size.y=1266`；切换 `chrome="hover"` 后恢复 `at.y=12`、`size.y=1296`；切回 titlebar 再次变为 `42/1266`。窗口 tag 随模式正确增删。
- 嵌套合成器里通过 `hyprctl dispatch 'fatlj_float_panel.titlebar_action("0x…", "maximize")'` 验证按钮动作路径：窗口获得 `float-panel-geometric-max-v1…` tag，并落到带 30px inset 的完整 floating bounds；`"minimize"` 则移动到 `special:omarchy-minimized-1`。动作字符串本身由 `add_button` 注册，单元测试覆盖了三条命令都带 `%WINDOW%`。
- `scripts/validate.sh` 覆盖 titlebar setup、tag、inset、几何最大化/最小化路由和回退契约。

### 尚未验证

- 锁屏状态下无法做指针级验收：titlebar 按钮点击、拖动、双击、顶部 resize 的实际像素/输入路径仍需解锁后在专用 workspace 复测。
- 不要把 `chrome="titlebar"` 与官方 `Super+L` / Workspace Layout 的 floating 模式同时使用；官方 `titlebars()` 会改写全局 `workspace_tag` 和按钮动作，且其 placement/tag 策略与本插件冲突。

## Client minimize/maximize requests（2026-11-12）

Hyprland 0.56.2 的 `CWindow::onUpdateState()` 只消费 fullscreen 和 maximize；`requestsMinimize` 虽然由 XDG/X11 状态设置，但没有消费路径。Omarchy 另有全局 `o.window(".*", { suppress_event = "maximize" })`，所以客户端自绘按钮在默认配置下表现为 no-op。

本插件的 native bridge 现在把 `requestsMinimize` 作为 `float_panel.minimize_request` 事件转发给 Lua；Lua 在窗口已映射且位于 regular workspace 时把它移到 `special:omarchy-minimized-N`（与 `Super+M` 同一存储），并用每个 window token 去重，客户端发回 `false` 时清除。窗口打开后的 maximize 请求在 Float workspace 上转成几何最大化/还原；Tiling 保留 Omarchy 的抑制。嵌套合成器用 X11 `xdotool ... windowminimize` 验证了窗口进入 `special:omarchy-minimized-1`；Wayland 的 `set_minimized` 走同一条状态事件。

## CSD 应用的窗口按钮（2026-11-12）

GTK CSD 应用（Nautilus、Lollypop）会在自己的 headerbar 画窗口按钮；Omarchy titlebar 再画一套就会重复。两种 owner 只能选一个：

- 排除（默认，保留应用自己的 chrome）：应用自己画 close/maximize/minimize。本插件只负责让它在 Float workspace 浮动并清掉自己的 tag，绝不代为 unmaximize、resize 或 move。Lollypop、Chromium、Electron、Qt 都会自己记住最大化状态：应用请求 maximize 时 Hyprland 原生处理，窗口就是最大化，中间按钮显示“还原”；点“还原”后窗口回到浮动尺寸，按钮变“最大化”。此前插件在应用背后 unmaximize 并缩到 80%，才导致窗口未最大化却长期显示“还原”。
- 由本插件 titlebar 接管：设置 `gtk-decoration-layout=appmenu:`（同时写 `gtk-3.0`/`gtk-4.0/settings.ini` 和 gsettings），去掉应用自己的按钮，并从 `titlebar.exclude` 移除该类；此时 maximize 走 `maximize-geometric`。
- Chromium 系（Brave/Chrome）：它们自己的 tab strip 按钮与插件 titlebar 会重复，因此保留在 `titlebar.exclude`；Brave 若需要 maximize，应在浏览器设置里启用 "Use system title bar and borders"，让浏览器不再画自己的按钮，再从 exclude 移除。
- WeChat：保留 exclude。实测其 Qt headerbar 的最大化按钮只发出 `maximize_request=false`，最小化按钮不发出任何协议请求；compositor 无法区分用户点击与工具包状态，不能用 toggle 兜底（会震荡）。需要应用侧改为标准 xdg_toplevel 请求，或改用 `Super+M`/`Super+Up`。
- 不要全局清空 GTK 按钮后又让应用自己拥有窗口控制；也不要对 false-only 的客户端做“false 当 toggle”的兜底，它会因客户端状态回写持续震荡。
