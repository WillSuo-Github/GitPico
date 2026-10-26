# History graph spacing · 2026-10-25

- 用户截图显示提交图谱的彩色线路与头像/文字之间有较大空白。原因是 HistoryPresentation 为整页提交计算最宽图谱，CommitRow 的每一行都预留该宽度，最多 110 点。
- CommitRow 现在以当前 GraphRow.laneCount 计算所需宽度，仍受已加载图谱及原有上限约束。单线行 29 点、双线行 42 点；相较 110 点的原预留，单线头像和文字左移 81 点。分支增减时，信息列随当前行图谱宽度调整。
- 图谱线路的横坐标、父子关系和颜色算法没有修改；GraphCell、GitCore 和历史缓存未修改。无图谱、搜索结果和文件历史保持原布局。
- 现有 opt-in 组件捕获改为传入 110 点的整页图谱宽度，复现该问题。修正前后均使用相同 380 点宽的真实 CommitRow，2× PNG；覆盖浅/深色、Medium/Small、选中/未选中、非活动选择和无图谱。组件捕获 1 项通过，0 failed。未重复整套 App / Core 回归。
- evidence/history-spacing/comparison-light.png 和 comparison-dark.png：左侧修正前，右侧修正后。该证据是隔离组件捕获，不冒充用户个人仓库或完整窗口的运行截图。
- 最终 --verify 的基础启动及真实 App / 菜单启动均通过，isActive=false、visibleWindows=0；单/多标签显示和菜单上下文检查通过。没有前台鼠标测试。
- 本地完整 app 为 dist/GitPico.app，版本 0.01，Build 20261025204750，最低部署 26.0；codesign deep / strict 通过。主机 macOS 27.0.1，未宣称 macOS 26 运行验收。没有提交或推送。
