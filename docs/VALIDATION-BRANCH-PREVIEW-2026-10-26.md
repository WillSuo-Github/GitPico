# Branch preview rendering - 2026-10-26 - Build 20261026114147

## Scope and changes

本轮针对左侧点击分支查看历史，只读取历史，不执行 checkout。性能复现和验收写入全部发生在临时本地仓库。

- 显式导航取消固定 40 ms 等待，改为让出当前 actor 执行机会并检查取消；输入搜索仍保留 250 ms 防抖。保留快速切换取消、代际校验和外部引用移动后的重新解析。
- 准备好的历史带有实例标识，相同缓存实例在后台验证后不重复发布。月份分组改用月份和连续段序号标识，跨月交错仍保证唯一。
- 被抑制进程的采样显示 SwiftUI List 的差分、自动行高测量和单元格布局占用主线程。改用固定行高的 NSTableView，按 ID 插入、删除和复用共享行，只绘制可见行。右键 NSHostingMenu 按需创建。Store 继续拥有数据和选择，Coordinator 仅保存表格索引。
- 保留原生选择、键盘导航、分组/紧凑模式、返回定位、提交拖动/拖放和右键动作。拖动复用原有仓库会话 token 校验，外部拖出禁用。Load More 放在列表底部固定位置。
- 右侧 CommitDetailView 改为 LazyVStack，将仓库可用性判断移到 ForEach 外，避免为大提交一次创建全部文件行。统计仍使用完整数据，Expand All 的 diff 随文件行出现而加载。

## Measurement

Debug、被抑制的 1200 x 850 pt 原生窗口；3000 条基础提交、120 个分支，每页最多 500 条历史。依次访问三个分支，再重复两轮。以下重复访问取后 6 次的中位数。任务计时以异步任务完成为界，不等于显示完成。

主线程间隔由每 5 ms 调度的 MainActor 任务测量：记录每次访问中的最大实际间隔，再取样本中位数。它包含调度和渲染影响，不是精确帧耗时或显示帧率。

| Experiment / revisit measurement | Before | After |
| --- | ---: | ---: |
| Empty-change commit, history task | 137.3 ms | 44.5 ms |
| Empty-change commit, maximum MainActor interval | 82.0 ms | 30.6 ms |
| 500-file commit, detail task | 639.2 ms | 48.4 ms |
| 500-file commit, maximum MainActor interval | 617.2 ms | 36.1 ms |

空改动实验对比原始版本与原生表格/差分更新阶段，早于最终详情懒加载和小幅文字绘制调整。500 文件实验在已经采用原生表格的版本上隔离对比 eager 详情与最终 lazy 详情，不把它称为全量原始版本对比。最终重复访问的同步导航耗时中位数为 0.13 ms，首次加载仍有 Git/磁盘成本。

只测 Store、不挂载视图的原始对照中，首次约 68-75 ms，缓存重复访问低于 0.04 ms；它不能证明界面丝滑，所以补充了带窗口内容布局的测量。原始数据、各阶段说明和汇总见 `evidence/branch-preview/*.json`。500 文件场景的最终浅/深色截图已经检查，见 `history-light.png`、`history-dark.png`。

## Verification

- GitPicoTests 全部运行，并选跑 Core 的 branchesTagsScopeAndMergeGraph：113 passed，0 failed，11 opt-in skipped。新测试覆盖表格选择、分组/行高、滚动定位、数据切换、busy、拖动 token 和菜单构造；原有缓存失效、快速切换、迟到结果、导航恢复和拖放测试通过。
- 新增观察测试确保缓存重新验证不重复发布；分组测试覆盖不同 tip 的共享月份与跨月交错。
- 单独运行 opt-in 渲染性能测试、500 文件性能测试，以及 12 页浅/深色离屏画廊。
- `./script/build_and_run.sh --verify` 通过。staged app 为 `dist/GitPico.app`，版本 `0.01`，Build `20261026114147`；基础与原生启动报告均为 isActive=false、visibleWindows=0，原生报告 repositoryReady=true。
- 主机为 macOS 27.0.1，最低部署保持 26.0；没有宣称 macOS 26 实机验收。没有在个人仓库或外部服务器执行验收写入。
- 验证在提交前完成。源码哈希和结构化结果保存在 `evidence/branch-preview/`，提交与远端同步结果以 Git 历史为准。

离屏测量和截图不代表前台鼠标、键盘、VoiceOver 或帧率验收；没有宣称所有仓库零延迟。
