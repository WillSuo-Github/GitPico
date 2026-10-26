# Compact toolbar · 2026-10-25

顶部标签按用户指定的 Safari Compact 方向收进原生窗口工具栏，移除独立的 35 点标签行。[Apple 对 Compact 的说明](https://support.apple.com/guide/safari/tabs-ibrw1045/mac)用于确认标签与工具栏合为一行的结构，没有操作用户 Safari 的设置或窗口。

## 行为和范围

- RepositoryWorkspaceView 在原生 principal toolbar item 放置标签，隐藏重复标题；窗口最小尺寸保持 1080 × 680。
- 当前标签更宽，名称居中；关闭按钮、Find 和 Refresh 放在标签内。Command-F 展开原生 NSSearchField，保持查询绑定、清除和焦点请求，Esc/返回按钮收起搜索。切换标签撤销旧请求，继续保留各仓库查询和缓存。
- 标签根据窗口宽度显示完整的一组，选中标签始终可见；Show All Tabs 保留所有标签的入口。新建和关闭继续使用原有工作区模型与 Command-T / Command-W / Control-Tab。
- Fetch / Pull / Push 保留常驻入口。Repository Actions 按 Quick Actions、Branches and Integration、Stash、Recovery 分组，保留原有禁用条件及审核表单。
- 仓库选择页使用 NavigationSplitView，缩小标题和按钮，并为底部动作保留安全区域；离屏捕获发现的底部遮挡已修复。
- 本轮只改四个 View 和捕获/布局测试，沿用上一轮尚未提交的标签功能。没有新增 Git 写操作或改动 GitCore。

## 验证

- 原生完整 App target：**96 通过、0 失败、6 条件跳过**。[摘要](evidence/compact-toolbar-app-summary.json)、[日志](evidence/compact-toolbar-app-tests.log)。结果包 `.build/xcode/CompactToolbarAppTests.xcresult`。参数化运行在设备明细里展开为更多实例，采用顶层逻辑测试数，不重复累加。
- 全套回归后收尾调整了窗口最小尺寸、选择页底部安全区域和捕获脚本；最终源码重新原生 build-for-testing，并通过 **2 项定向检查**：[摘要](evidence/compact-toolbar-capture-summary.json)、[日志](evidence/compact-toolbar-capture-tests.log)、[构建](evidence/compact-toolbar-native-build.log)。结果包 `.build/xcode/CompactToolbarSafeCapture.xcresult`。布局用例在全套回归中也运行过，不将两次数字相加。
- 布局用例覆盖 1 / 2 / 3 / 12 / 100 标签、首尾及中间选择、4 档可用宽度，检查当前标签和完整可见组不越界。
- 离屏检查使用真实 NSHostingController / NSWindow / NSToolbar，窗口从未 orderFront，校验 principal item 未被原生 overflow 隐藏；1080 / 1420 点、浅深色、9 个标签、搜索实际获得 first responder、切换后旧搜索字段移除、选择页与底部动作均捕获。用例结束确认未激活且零可见窗口。
- 6 个 skip 是显式 opt-in 的旧基准和组件捕获，其中本轮 compact 捕获已单独启用。既有拖放类型未导出警告仍保留；没有把该警告归为本轮通过的新功能。
- `./script/build_and_run.sh --verify` 最终构建、签名检查、暂存和后台启动成功：[日志](evidence/compact-toolbar-background-build.log)、[后台报告](evidence/compact-toolbar-background-verification.json)。报告为 isActive=false、visibleWindows=0。

## 图像与边界

真实工具栏离屏结果：[浅色顶部](evidence/compact-toolbar/header-1420-light.png)、[深色顶部](evidence/compact-toolbar/header-1420-dark.png)、[窄窗口](evidence/compact-toolbar/header-1080-light.png)、[标签内搜索](evidence/compact-toolbar/search-1080-dark.png)、[选择页](evidence/compact-toolbar/picker-light.png)。全部在未显示的原生窗口中捕获；完整图的原生侧边栏材质会显示为黑色，因为离屏缓存不能读取窗口后方的系统合成背景。这不是前台整窗截图，也不替代实际鼠标和视觉验收。

最终开发包 `dist/GitPico.app`：**0.01 / 20261025145232**，最低系统 26.0。[Bundle 元数据](evidence/compact-toolbar-bundle.json)、[五个源码与测试文件指纹](evidence/compact-toolbar-source-hashes.json)。实际主机 macOS 27.0.1 / Xcode 27.1，macOS 26 runtime 尚未验收。没有自动重启用户当前实例，没有提交、推送或创建 GitHub 仓库。
