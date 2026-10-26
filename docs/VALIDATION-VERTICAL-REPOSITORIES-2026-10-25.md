# Vertical repository sidebar · 2026-10-25

用户确认采用侧边栏顶部的竖向已打开仓库列表。原横向标签行和胶囊标签已移除；此前标签方案的记录保留各自捕获时的状态。

## 当前实现

- 一个稳定的 NavigationSplitView 管理全局仓库列表、当前仓库导航和右侧内容。侧边栏宽度为 240 / 280 / 400 点的最小 / 理想 / 最大值，在仓库和选择页之间切换不更换分栏。
- 顶部 Open Repositories 使用原生 sidebar List，限制为约五行高度，独立滚动；程序化选择会 reveal 当前行。每行一个文件夹图标和名称，选中行或悬停显示关闭，忙碌行显示进度。加号和右键关闭保留入口；空选择页显示 New Tab。
- 仓库运行 Git 操作时，这一全局列表仍可切换到其他仓库，新建入口可用；忙碌仓库仍由原模型禁止关闭。
- 下方保留当前仓库的 Workspace / Branches / Tags / Related Repositories / Remotes；空选择页显示 All / Recent / Favorites / Groups。侧边栏底部 Filter 保留在状态栏上方。
- Command-T、Command-W、Control-Tab / Control-Shift-Tab 未修改，继续使用原工作区路由。各仓库独立草稿、查询、选择和历史缓存继续由原 RepositoryStore 保存；最后关闭回到选择页。
- 原生工具栏仍归工作区所有，状态栏仍横跨整个窗口，右下路径维持灰色可点击 Finder 入口。RepositoryDetailView、RepositoryPickerSidebarView、RepositoryStatusBar 分离视图职责，ContentView 保留独立使用模式。
- 没有修改 GitCore、版本规则、Xcode target 或共享 scheme。新增文件通过同步 Xcode groups 自动参与构建。

## 回归与后台验证

- 原生 App target 完整回归：**95 项通过、0 失败、6 条件跳过**。[摘要](evidence/vertical-repositories-app-summary.json)、[日志](evidence/vertical-repositories-app-tests.log)，结果包 `.build/xcode/VerticalRepositoriesAppTests.xcresult`。保留原仓库工作区 9 项真实隔离 Git 回归；横向宽度计算用例随旧视图删除，未将旧测试总数沿用。
- 全套回归后仅收尾调整关闭按钮样式、标签一致性和 Filter 的底部安全区域，并重新原生 build-for-testing；最终源码的显式离屏检查 **1 项通过**：[摘要](evidence/vertical-repositories-capture-summary.json)、[日志](evidence/vertical-repositories-capture.log)、[最终测试构建](evidence/vertical-repositories-test-build.log)。结果包 `.build/xcode/VerticalRepositoriesFinalCapture.xcresult`。
- 该离屏用例覆盖 1080 / 1420 / 2032 点、浅深色，读取实际 NSTableView，检查列表行数、滚动区域高度、选择及选中行可见、标题栏下的位置、Filter 未被状态栏覆盖。切换仓库及新建选择页后，全局原生列表和 NSSplitView 的对象身份保持；旧仓库 busy 时新仓库仍可选择。
- 检查恢复的工具栏控件不少于 14 个，宽窗口全部可见；Find 请求获得原生 first responder，切换后查询绑定到新仓库。用例中的隐藏窗口始终未显示，结束确认 App 未激活、可见窗口为 0。
- 6 个 skip 是显式 opt-in 的基准或组件捕获；本轮新侧边栏捕获已单独启用。既有拖放类型未导出的运行警告保留，未在本轮扩展修复。
- 最终 `./script/build_and_run.sh --verify` 构建、签名检查、暂存及后台启动成功。[日志](evidence/vertical-repositories-background-build.log)、[后台报告](evidence/vertical-repositories-background-verification.json)。未激活、可见窗口为 0，没有自动重启用户正在使用的实例。

## 图像与边界

真实行组件的离屏预览：[浅色](evidence/vertical-repositories/rows-light.png)、[深色](evidence/vertical-repositories/rows-dark.png)。捕获复用了产品的 RepositoryWorkspaceRow，选择底色由捕获容器提供，用于查看文字、图标和关闭按钮。

实际隐藏窗口布局：[工作区](evidence/vertical-repositories/workspace-1420-light.png)、[窄窗口及底部过滤栏](evidence/vertical-repositories/workspace-1080-light.png)、[仓库选择页](evidence/vertical-repositories/picker-light.png)。原生列表的部分选中材质在离屏缓存中显示为黑色，因此完整窗口图用于布局检查，不能作为前台选中材质的视觉验收。没有声称实际鼠标悬停、快捷键事件或 VoiceOver 已通过人工验收。

最终开发包 `dist/GitPico.app`：**0.01 / 20261025163606**，最低系统 26.0。[Bundle 元数据](evidence/vertical-repositories-bundle.json)、[八个源码与测试文件指纹](evidence/vertical-repositories-source-hashes.json)。实际主机 macOS 27.0.1 / Xcode 27.1，不代表 macOS 26 runtime 验收。本轮没有重跑 GitCore 全套，没有提交、推送、发布或创建 GitHub 仓库。
