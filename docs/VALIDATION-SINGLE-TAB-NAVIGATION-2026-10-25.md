# Single-tab repository navigation · 2026-10-25

## 最终行为

- 文件夹按钮、File / Repositories 和对应 Quick Action 都在来源标签内部显示仓库选择页，不调用 newTab，不开启多标签。单标签时原生标签栏继续隐藏。
- 普通打开、最近仓库、Quick Open、Worktree/Submodule 的正常打开、Clone/New 完成后的打开均复用来源标签；另开标签由显式 New Tab（Command-T；已有多标签栏中的原生 +）触发。默认新建占位页只维持至少一个标签，不会产生多标签。
- 选择页保留当前仓库的 Store、草稿、导航、已选文件/提交、历史缓存和窗口身份，提供 Back to Repository。返回或重新选择同一个规范化仓库不重新加载历史。标题/图标切为 Repositories，状态栏切为选择页状态。
- 选择页不展示旧仓库的 Git 工具栏/操作提示，禁用其 Git 命令与提交快捷键。打开中或正在写入 Git 时，普通切换被保护，仍可以显式 Command-T 创建另一个标签。
- 真正切换到另一仓库前保存原仓库草稿；新仓库恢复自己的草稿，普通切换不把前一仓库的草稿移过去。迁移重开仍保留迁移草稿。保存失败或仓库校验失败保留原仓库；不会用新标签绕开保护。
- 保留规范化路径去重：目标已在其他显式标签打开时聚焦它，空选择标签可以收起。关闭标签后来自其旧 Store 的迟到打开/选择/创建回调被忽略，不能替换另一标签。

## 验证和范围

- App 目标回归 99 passed、0 failed、7 opt-in skipped；包括窗口、草稿、历史缓存、打开失败、忙碌、迁移和 Clone/New 选择请求。LFS 的已有 20 秒等待曾在并发负载下超时，因此本次单独安排运行，不更改逻辑或阈值。
- 补充验证 3 passed：LFS 单项、关闭来源的迟到回调保护，以及当前真实窗口的 opt-in 捕获。共 102 项不同检查通过；参数化展开的设备计数不当作额外独立测试。
- 补充保护和菜单忙碌条件在主回归后加入，使用最终构建执行对应补充检查和真实菜单启动检查；未重复完整 App 回归。
- 原生捕获同时覆盖多标签工作区的浅/深色及两种宽度，以及由文件夹进入的单标签选择页。检查同一 NSWindow / 标签身份、单标签无标签行、返回草稿和选择保持。隐藏窗口的 sidebar 材质 bitmap 可能出现黑块，未将其当作活动态视觉验收。
- 最终 --verify 通过两个启动检查：基础无窗口启动及真实 App / 菜单。repositoriesMenuReusesCurrentTab=true；单标签隐藏、显式 New Tab 显示多标签、Close Tab 后重新隐藏，菜单上下文均通过。isActive=false、visibleWindows=0，没有抢前台。
- 全部 Git 接受性写入使用可丢弃本地仓库，没有个人仓库或外部服务器写入。GitCore 未修改，本批未重复全量 Core 回归。原拖放 UTType 未导出的 runtime warning 仍在，本批不扩大修复。

## 构建

版本 0.01，Build 20261025215156，最低部署 26.0。完整 app 为 dist/GitPico.app，codesign deep / strict 通过。源文件哈希、测试摘要/日志、截图和实际启动 JSON 位于 evidence/single-tab-navigation/。主机 macOS 27.0.1，未宣称 macOS 26 运行验收；无前台鼠标或真实焦点验收。未提交或推送。
