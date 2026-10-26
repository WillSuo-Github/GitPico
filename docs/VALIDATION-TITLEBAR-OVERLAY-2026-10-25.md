# Titlebar overlay · 2026-10-25

用户截图中，仓库选择页顶部标题被一条半透明区域覆盖。后台原生窗口捕获复现了相同位置的遮挡。

## 原因和修正

- 这是系统标题栏背景和 scroll pocket，不是业务遮罩、加载状态或付费限制。NSWindow 移除 fullSizeContentView 后，SwiftUI NavigationSplitView 仍创建高 66 点的 NSTitlebarBackgroundView，却在内容区内部绘制；根 NSHostingView 的 top safeAreaInsets 为 0，页面标题落在这层背景下面。
- 恢复 fullSizeContentView，交还原生窗口标题栏安全区计算；同一捕获窗口的根 NSHostingView top safeAreaInsets 变为 66，标题栏材质留在真正的工具栏区域。仓库选择页标题、副标题恢复清晰。NavigationSplitView 明确使用 balanced 布局。
- 单纯隐藏 toolbar background 或 scroll-edge effect 没有修正边界；不保留这些试验。手动移除原生 tracking separator 的试验也已撤销，避免改变工具栏按钮的位置。
- 多标签遵循原生分栏布局，标签行位于侧边栏右侧，保留全部工具栏操作。此前为了让标签栏跨过侧边栏而移除 fullSizeContentView 的方案会导致这次遮挡，已经撤销。当前没有宣称仍实现跨整个窗口的标签行。
- 单标签隐藏、多标签显示、关闭回一个隐藏、原生拆分窗口、草稿保护和原有快捷键保留。

## 证据

- evidence/titlebar-overlay/before 和 after：相同 1440 × 980 点、2× PNG 的深色选择页截图，以及原生视图层级/安全区记录。picker-header-comparison.png 将修改前后标题区放在同一张图中；左侧修改前，右侧修改后。
- 修正后的三仓库工作区另捕获 1080 / 1440 点宽、浅色/深色四个状态。1440 点下 16 个工具栏控件全部可见。opt-in 捕获用例保留新选择页路径，便于复查此问题。
- 4 项相关测试通过：3 项原生窗口生命周期及 1 项离屏捕获。未重复整套 App / Core 回归。本批没有 GitCore 修改。
- 最终 --verify 的基础启动和真实 App / 菜单启动均通过，两个验证进程均未激活、可见窗口数为 0；单/多标签显示状态和真实菜单上下文检查通过。
- 本地 app 为 dist/GitPico.app，版本 0.01，Build 20261025185028，最低部署 26.0。codesign deep / strict 通过。没有提交或推送。
- 主机为 macOS 27.0.1；没有抬起前台窗口测试，也没有宣称已在 macOS 26 上运行。隐藏窗口的侧边栏选中材质仍可能在 bitmap 中显示黑块，此问题与本次有明确位置/安全区证据的标题遮挡不同；活动态颜色和真实鼠标行为仍未验收。
