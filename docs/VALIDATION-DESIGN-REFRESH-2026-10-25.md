# Design refresh · 2026-10-25 · Build 20261025234040

## 范围

全部主页面重新排布信息架构并统一视觉语言。未改 Git 读写逻辑、命令、快捷键语义和审核流程；所有原有入口仍可达（菜单、⌘ 快捷键、右键菜单、统一搜索）。

## 视觉系统

- 全局 AccentColor 取自 App 图标渐变的暖橙端（浅色 #E6621E / 深色 #F57C34），通过 `Resources/Assets.xcassets` 与 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` 下发；选中态、主按钮、链接统一使用。语义色分开：新增绿、删除红、修改蓝、警告琥珀，避免 accent 与删除红混淆。
- `Sources/GitPico/Views/DesignSystem.swift`：作者头像（10 色稳定色板，FNV-1a 哈希）、仓库字母图标、Chip、可复制 HashChip、DiffStat 条、PaneBar（统一 46 pt 标题栏）、卡片、MetadataRow、NoticeBanner、SheetTitle。
- 33 处弹窗/面板标题换成带图标的 SheetTitle；四类横幅（集成进行中、自动 stash、Git Flow、草稿保存失败）统一为 NoticeBanner。

## 功能入口重排

- 工具栏：原生工具栏控件从 15 个减为 12 个（含侧边栏开关），1080 / 1440 pt 宽度下全部可见（改版前 1080 pt 有 1 个进 overflow）。当前分支名直接显示在分支按钮上，Merge / Rebase / Interactive Rebase / Compare / Git Flow 并入分支菜单并新增「Switch to Branch」；Stash 与 Apply 合并为一个分段菜单按钮（点击保存，菜单应用）；Refresh 移到状态栏（⌘R 不变）。
- 侧边栏：顶部新增仓库卡片（名称、当前分支、↑↓，点击切换仓库，右键 Settings / Finder / 复制路径）。移除永远禁用的 Pull Requests；Settings 不再占导航行（⌘5、底栏齿轮、卡片右键、提交身份入口均可达）；Branches Review 与 Reflog 归入 Tools；Branches / Remotes / Tags / Related / Tools 分组可折叠并持久化；Working Copy、Stashes、Worktrees、Submodules 用原生 badge 计数；无远端、无标签时给出 Add Remote / New Tag 行。
- Working Copy：文件列表在上，提交框钉在底部；排序与显示选项收进标题栏菜单，Stage All 与计数（staged / unstaged）在标题栏；提交框为 Summary + 可展开 Description + 身份 + Amend + 选项菜单 + 主按钮「Commit N Files」。diff 底栏删除，空白/上下文选项进 diff 标题栏菜单，忽略空白时显示说明条。
- Commit / Stash 详情：标题与正文在最前，作者头像与相对时间一行，引用 chip，parent / base 为可复制 hash，committer / 日期 / tree 收入 Details。文件列表头为「N files changed + DiffStat + Expand All」。
- Worktrees / Submodules：维护类操作（Move Main Repository、Repair Pointers、Migration History、Management Backups）收入 ⋯ 菜单；主操作 Add 为主按钮；列表与详情改为卡片。
- Repositories 首页：Open Local / Clone / New 改为三张操作卡片，仓库行使用字母图标、~ 缩写路径、最近打开时间，Library 工具收入 ⋯ 菜单。
- 其余：Branches Review 加 base 选择器、ahead/behind 胶囊与统计卡片；Reflog 事件按类型着色并去掉重复前缀；Settings General 加仓库卡片、Commit Identity / Signing 分组和 Save Changes 主按钮；Compare 选项收进菜单；冲突解析的 Current / Incoming / Base 分色；统一搜索浮层加图标块与键帽提示；App 设置窗口加 diff 字号预览。

## 顺带修复

- detail 列内容会被底部状态栏压住（改版前 Branches Review 的 Show History / Check Out 被遮挡，新的底部提交框同样受影响）。detail 列现在按状态栏高度留出安全区。
- File History 原来只绑定了双击，单击无法切换 revision；补上单击选中，选中行改用系统选中底色，避免白字落在浅色底上。
- Repository Settings 不再把 Git 模板描述「Unnamed repository; edit this file…」当成用户内容展示；未修改时保存会原样写回模板文本。
- diff 预览隐藏重复的 `diff --git` / `index` / `---` / `+++` 头（复制 diff 仍是完整文本）。
- 仓库选择页顶部工具栏区域原本是一条平色暗带（2026-10-26，Build 20261026002019）：SwiftUI 渐变实际已画到窗口顶部，但 AppKit 在 detail 列顶部 52 pt 放置的 `NSTitlebarBackgroundView` 会覆盖它（离屏取样：纯红背景被压成 `(64,36,35)`，隐藏该层后为 `(230,74,67)`）。`.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` 对这层无效。现在仅在选择页显示时设置 `window.titlebarAppearsTransparent = true`，AppKit 自行隐藏该层，渐变连续到顶部；仓库页面恢复为 `false`，保留 detail 列滚动内容的顶部边缘效果。证据：`docs/evidence/design-refresh/picker-toolbar-band-fixed-dark.png`；`nativeWindowTabsSynchronizeSelectionCreationAndBusyClose()` 断言进入 / 离开选择页时的切换。

## 验证

- `GitPicoTests/renderDesignGalleryWithoutActivation()`（opt-in，`GITPICO_RENDER_DESIGN_GALLERY=1`）在临时目录生成带 bare origin、多作者、merge、tag、2 个 stash、混合改动的仓库及一个 merge 冲突仓库，在被抑制的原生窗口里截 12 个页面的浅/深色图。改版前后对比见 `docs/evidence/design-refresh/comparison-*.png`，深色总览见 `after-dark-overview.png`。
- `renderNativeWindowTabsWithoutActivation()` 重新运行通过：三标签、浅/深色、1080 / 1440 pt，12 个控件全部可见，草稿与文件选择在标签切换后保持。
- 完整 GitPico 方案测试：330 项，320 passed，0 failed，10 skipped（skipped 均为 opt-in 截图）。 2026-10-26 修复工具栏暗带后重跑：330 项，0 failed，10 skipped；`--verify` Build 20261026002019，isActive=false，visibleWindows=0。组件截图（历史行、工作区行、统一搜索）重新生成并检查。
- `./script/build_and_run.sh --verify`：基础与真实 App / 菜单启动验证通过，isActive=false，visibleWindows=0；版本 0.01，Build 20261025234040，LSMinimumSystemVersion 26.0，Info.plist 含 NSAccentColorName=AccentColor。`swift build` 通过。
- 只使用临时仓库，未触碰个人仓库或外部服务器。

## 已知限制

- 截图来自被抑制的离屏窗口：侧边栏选中行显示为黑块、主按钮按非活动窗口绘制为灰色、侧边栏图标未着色，都是离屏绘制假象，不代表前台外观。前台鼠标、键盘焦点、VoiceOver、实际 Liquid Glass 材质仍未验收。
- 工具栏分支按钮依赖把 Menu 包进容器视图以显示分支名；只在离屏截图中确认显示，前台交互待验收。
- 主机为 macOS 27.0.1，未宣称 macOS 26 运行验收。未提交或推送。
