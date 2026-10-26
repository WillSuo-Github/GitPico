# Separate repository tab strip · 2026-10-25

按用户最新要求，仓库标签移出原生工具栏，放到其下独立的 38 点内容行。上一份 Compact toolbar 记录保留当时实现；本记录描述当前布局。

## 当前行为

- 多标签分享整行可用宽度，移除 900 点标签区域上限和每个非活动标签的 180 点上限。当前标签略宽；宽度不足时保留完整标签和 Show All Tabs 入口，不露出半截。单标签最多 360 点，避免将一个短名称拉成整行。
- 工具栏恢复 Quick Actions、Undo / Redo、Fetch / Pull / Push、Branches、Integrate、Save / Apply Stash、Refresh 和原生 Find 字段。搜索字段为 180 点，隐藏与标签重复的可见标题，使最低窗口宽度下仍能显示搜索字段；NSWindow 标题仍来自原有 navigationTitle。
- RepositoryToolbar 由工作区持有，切换仓库更新绑定；内容视图仍按标签身份重建，保留各自模型和缓存。独立使用的 ContentView 保留原工具栏入口。关闭、新建和 Control-Tab 沿用原工作区模型。
- 取消未发布的 ToolbarAvailableWidth 桥接。标签行只读自身实际宽度，不读取或占用 NSToolbar 的剩余宽度。
- 窗口最低高度增加到 718 点，容纳新增 38 点行和原来 680 点内容。最低宽度保持 1080。

## 验证

原生 build-for-testing 成功，[构建日志](evidence/separate-tab-strip-build.log)。随后 **3 项定向检查通过、0 失败**：[摘要](evidence/separate-tab-strip-summary.json)、[日志](evidence/separate-tab-strip-tests.log)，结果包 `.build/xcode/SeparateTabStripStable.xcresult`。

- 标签布局覆盖 1 / 2 / 3 / 12 / 100 标签及每个选择位置、5 档可用宽度。当前标签始终可见，多标签使用全部可用行宽，宽度不越界。
- 离屏原生 NSWindow / NSToolbar 捕获覆盖 1080、1420、2032 点与浅深色。每个已打开仓库场景都检查恢复了至少 14 个带 view 的工具栏控件；2032 点场景检查全部控件均在 visibleItems 中。1080 点实际搜索字段存在且可接收焦点。
- 原生搜索请求获得 first responder；切换标签后字段绑定到新仓库查询，继续检查选择页和关闭返回。另有独立桥接回归核对绑定更新、过期焦点请求取消。
- 捕获从未显示窗口，结束断言未激活且零可见窗口。中间捕获发现的窄窗口搜索字段缺位已通过标题和字段尺寸调整修复；工具栏移到工作区，避免切换标签时跟内容一起重建。捕获等待原生布局过渡后再检查字段。

顶部实际离屏结果：[2032 点浅色](evidence/separate-tab-strip/header-2032-light.png)、[1080 点深色](evidence/separate-tab-strip/header-1080-dark.png)、[选择页](evidence/separate-tab-strip/picker-2032-light.png)。完整图片中的原生侧边栏材质在离屏缓存里可能显示黑色；这些是隐藏窗口捕获，不是前台人工视觉或鼠标验收。

最终开发包 `dist/GitPico.app`：**0.01 / 20261025152249**，最低系统 26.0。[元数据](evidence/separate-tab-strip-bundle.json)、[五个源码与测试文件指纹](evidence/separate-tab-strip-source-hashes.json)。[后台构建与启动](evidence/separate-tab-strip-background-build.log)、[后台报告](evidence/separate-tab-strip-background-verification.json)确认 isActive=false、visibleWindows=0。

本轮未改 GitCore，未重跑完整 GitCore 或 App 全套，不把上一轮 96 项通过计入本轮结果。实际主机 macOS 27.0.1 / Xcode 27.1，不代表 macOS 26 runtime 验收。没有自动重启用户正在使用的实例，没有提交、推送或创建 GitHub 仓库。
