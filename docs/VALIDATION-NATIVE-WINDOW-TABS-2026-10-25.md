# Native repository window tabs · 2026-10-25

用户选择设计方案 1：使用真正的 macOS 窗口标签，在完整工具栏下面放置横跨窗口的仓库标签栏。此前自绘横向标签和侧边栏竖向仓库列表不再作为当前实现；历史验证记录保留原状态。

## 实现

- RepositoryNativeWindow / RepositoryWindowController 承担原生窗口、标签及 responder 生命周期；NativeRepositoryWindows 同步 NSWindowTabGroup 和 RepositoryWorkspace。SwiftUI 继续提供内容、工具栏、命令和 Settings。
- 每个仓库拥有独立且稳定的 NSHostingController、RepositoryStore、提交草稿、文件/提交选择、导航和历史缓存。切换原生标签不重新创建内容视图，也不为了切换触发完整仓库刷新。
- 标签栏使用系统名称、文件夹/选择页图标、完整路径 tooltip 和忙碌进度。工具栏保留全部操作，采用系统 icon-and-label 样式；缩短 Actions、Undo、Redo、Stash、Apply 标题，完整含义保留在菜单和帮助中。
- 侧边栏只展示当前仓库的导航。移除 fullSizeContentView，并将原生 sidebar split item 的 allowsFullHeightLayout 设为 false，使标签栏覆盖整个窗口，侧边栏从标签栏下方开始。
- Command-T、原生 + 和 newWindowForTab 创建选择页；Command-W 走实际窗口关闭；Control-Tab / Control-Shift-Tab 按原生标签的视觉顺序切换，并限制在当前原生标签组内。支持系统重排和拆分窗口，来自另一窗口组的仓库打开请求归入来源组。
- 忙碌仓库及无法保存草稿的仓库禁止关闭；最后一个仓库关闭回到选择页，最后一个空选择页可以关闭窗口，再次打开应用恢复选择页。关闭最后空选择页后新建不会留下隐藏的幽灵标签。完整标签会话恢复仍未实现。
- 原生窗口管理器提供禁止 presentation 的测试模式，拦截 orderFront / makeKeyAndOrderFront 等路径。即使 AppKit 在设置 selectedWindow 时尝试显示窗口，测试窗口仍不出现。

## 验证

- 完整 App target 串行回归：98 passed、0 failed、6 skipped；其中 3 个新增原生生命周期用例均通过。设备统计的 101 次通过包含参数化展开，不能当作 101 个独立测试。见 `evidence/native-window-tabs/app-summary.json`、`app-tests.log`。
- 首轮并发回归：97 passed、1 failed、6 skipped，失败为已有 LFS 状态测试的 20 秒等待超时。未更改 LFS 代码或放宽阈值；单项复测 1 passed，随后完整串行回归全部通过。首次失败和单项结果保留在 `first-app-summary.json` / `lfs-focused-summary.json`。
- 新增生命周期覆盖原生与模型双向选择、原生新建入口、忙碌关闭拒绝、草稿损坏保护、最后选择页关闭/重开、原生重排、独立窗口组、从非当前组打开仓库。全部使用隔离本地仓库，并检查应用未激活、可见窗口为零。
- 独立 opt-in 离屏捕获：1 passed。1440 × 900 / 1080 × 900 点，浅色/深色，共四张真实原生窗口截图。宽窗口 16 个工具栏控件全部可见；1080 点时系统将 1 个控件放入原生 overflow。循环标签后，原 NSHosting view、文件选择和提交草稿保持。见 `render-summary.json`、`native-tabs-*.png/json`。
- 最终 `./script/build_and_run.sh --verify` 通过基础无窗口启动及真实 SwiftUI App / 菜单启动。后者在临时仓库中检查 New Tab、Close Tab、快捷键、原生标签选择，以及“已打开仓库 Refresh 可用 → 新选择页禁用 → 返回仓库可用”。SwiftUI 菜单内容按需构建，验证器通过 menuNeedsUpdate 回调模拟打开前更新；单纯 NSMenu.update 只能验证项目，不能作为新菜单内容证据。
- 两个最终验证进程均 isActive=false、visibleWindows=0，前台仍为 Codex。没有启动或抬起 GitPico、Tower 或浏览器进行前台鼠标测试。
- 完整 App 回归后，唯一追加的源码改动位于仅由验证参数启用的 NativeStartupVerification，增加隔离仓库和菜单上下文检查；最终打包已实际执行并通过该路径。临时命令观察包装试验未保留。
- 测试报告仍包含拖放 UTType `com.willsuo.GitPico.drag` 未导出的 runtime warning；这不是测试失败，本批未修改拖放类型注册。
- GitCore 源码未修改，本批没有重复全量 Core 测试；Git 写入只发生在测试临时仓库中。

## 构建

- 本地完整 app：`dist/GitPico.app`。
- Marketing version：`0.01`。
- Build：`20261025180905`，由构建脚本按 Asia/Shanghai 日期时间生成。
- Bundle minimum：`26.0`。
- 完整 signed bundle 已重新 staging，codesign deep / strict 验证通过；未手工修改源 Info.plist、工程或 marketing version。
- `evidence/native-window-tabs/bundle.json` 记录最终可执行文件 SHA-256，`source-hashes.json` 记录本工作区改动源码范围及基线 commit。没有创建提交、推送或 GitHub 仓库。

## 视觉验收范围

`../design-qa.md` 保留完整来源/实现组合对照及修正历史。布局结构已通过离屏捕获确认，最终视觉结果仍标记 blocked：禁止前台测试的条件下，系统非活动窗口材质在 bitmap 中出现黑色选中块，无法据此接受真实活动态颜色、键盘焦点或鼠标拖动手感。该现象不是已确认的前台 UI 缺陷，也没有用硬编码选中颜色掩盖它。

选定概念为真正的原生窗口标签；macOS 27 系统标签轮廓与生成图的经典连体边角不同。现有工作区的完整功能、侧边栏区段、提交表单和用户保存的并排差异偏好保留，没有宣称整个编辑器逐像素复刻。

验证主机为 macOS 27.0.1。最低部署版本仍为 macOS 26.0，未宣称已在 macOS 26 上运行验收。前台实看、真实鼠标拖放、VoiceOver 和完整会话恢复仍未验收。
