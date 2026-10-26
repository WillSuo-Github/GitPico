# Icon-only repository toolbar · 2026-10-25

用户明确将仓库窗口工具栏改为仅图标。NativeRepositoryWindows 将 NSToolbar.displayMode 设为 iconOnly，已有原生捕获检查同步更新。菜单名称、无障碍标签及已有帮助仍保留；为后退/前进补充 Back / Forward 快捷键悬停说明。搜索框继续作为输入控件显示文字，仓库标签继续显示仓库名。

- 现有 opt-in 原生窗口捕获用例 1 passed。浅/深色 × 1080/1440 点宽，以及深色单标签仓库选择页截图已检查。1440 点下 16 个工具栏控件全部可见，按钮下方不再显示文字；图标模式减少了原生工具栏占用高度。标签循环后草稿、文件选择和 hosting view 保持。
- 截图位于 evidence/toolbar-icons/。这是禁止 presentation 的原生窗口捕获，没有前台激活或鼠标悬停验收。原有非活动 sidebar 材质 bitmap 黑块和拖放 UTType runtime warning 未在本次扩大修复。
- 捕获后追加的源码仅为后退/前进的两个 help 字符串，最终构建包含它们；未新建重复实现逻辑的单元测试，也未重复整套 App / Core 回归。
- 最终 --verify 的基础启动及真实 App / 菜单启动均通过，isActive=false、visibleWindows=0；单/多标签显示规则、菜单上下文和 New Tab / Close Tab 仍通过。
- 版本 0.01，Build 20261025212227，最低部署 26.0；完整 app 为 dist/GitPico.app，codesign deep / strict 通过。执行主机 macOS 27.0.1，未宣称 macOS 26 运行验收。没有提交或推送。
- 本次明确用户偏好覆盖早期设计图的 icon-and-label 工具栏；历史验证文档保留其捕获时的模式。
