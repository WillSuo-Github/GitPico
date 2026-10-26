# Single-tab visibility · 2026-10-25

- 单个原生窗口标签隐藏标签栏，同一窗口组有两个及以上标签时显示；关闭回到一个或拆出单独窗口时重新隐藏。Command-T 和 File / New Tab 入口保留。
- 移除创建窗口时无条件 toggleTabBar，tabbingMode 改为 automatic。根据 NSWindowTabGroup.windows 的实际数量同步显示，观察原生成员变更以覆盖关闭、拆分和重新加入。
- 修改现有原生生命周期用例中的断言：初始隐藏、两个显示、关闭回一个隐藏、拆出单标签隐藏、重新添加显示。相关 3 项后台测试全部通过，0 failed；本批未重复完整 App / Core 回归。
- 最终 --verify 的两个验证进程均未激活、可见窗口数为零。真实菜单路径的 singleTabBarHidden、multipleTabBarVisible、singleTabBarHiddenAfterClose 均为 true，New Tab / Close Tab 和菜单上下文验证保持通过。
- 本地 staged app：dist/GitPico.app；版本 0.01，Build 20261025182632，最低部署 26.0。codesign deep / strict 验证通过。
- 执行主机为 macOS 27.0.1；未进行前台鼠标、活动态视觉或 macOS 26 运行验收。原有拖放 UTType 未导出的 runtime warning 仍在，本批未扩大到类型注册修复。
- 证据见 evidence/single-tab-visibility/。上一批 native-window-tabs 证据保持其捕获时的单标签显示规则；本次报告记录新的隐藏规则。
