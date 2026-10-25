# 分支预览缓存和工具栏 — 2026-10-24

本轮针对“单击不同分支预览历史就卡顿”，没有把点击预览改成 checkout。预览通过本地 Git 读取提交，原路径也没有网络 Fetch；问题是每次导航都会完整刷新仓库。

## 根因和改动

- 原 `navigate` 调用完整 `refresh`，串行触发工作区、引用、提交计数、自动 Stash、远程配置、Undo/Rebase、Worktree/Submodule、Git Flow 等加载；`isBusy` 同时禁用侧栏。现在单独请求有界提交历史，不触发这些扫描。
- 新 `CommitHistoryPage` 先解析不可变提交，再读取 `limit + 1` 条以判断还有没有下一页，不执行每次预览的完整 `rev-list --count`。单页最多 20,000 条，界面在上限提示缩小搜索。
- 当前仓库会话内保留最多 16 页 / 20,000 条提交的 LRU；键包含引用范围、实际 tip、搜索、顺序、第一父提交模式、页大小。缓存页同步显示，再后台核对 tip。发生变化则读取新页；显式 Refresh、Git 写操作后的 reload、打开仓库均清空缓存。缓存不跨应用重启。
- 快速连点采用 40 ms 合并，搜索采用 250 ms 合并；新请求取消旧历史/详情读取，并按仓库会话、导航目标、请求代次及选项拒绝迟到结果。GitProcess 的可取消行为仅对显式启用的读取生效，写流程保留原有当前步骤完成语义。
- 图布局、月份分组随历史页缓存，在后台准备；侧栏树仅在引用/组织/过滤输入变化时后台重建。不可变提交详情另保留小型会话缓存。刷新取消详情加载后，仍选中的提交会重新加载详情。
- 工具栏使用统一紧凑系统样式，按导航、Quick Actions、Undo/Redo、网络、分支/整合、Stash、刷新/搜索分组。Git Flow 放入整合菜单，Synchronize 保留于 Repository 菜单。Save/Apply Stash 图标方向修正。搜索使用小型 NSSearchField 桥接，由 SwiftUI Binding 持有查询，AppKit 负责原生编辑/清除/焦点行为。

## 可复现的前后对比

使用真实、可销毁的临时 Git 仓库：600 条提交、120 个分支、2,000 个未跟踪文件。依次预览 branch-5、branch-70、branch-105，再重复同样顺序。计时从调用 `navigate` 到首条提交选中且侧栏不 busy，不等待提交详情或屏幕绘制。前后使用同一 fixture 与指标；后台运行，HEAD 前后相同。

| 预览 | 改动前 | 改动后 |
| --- | ---: | ---: |
| 首次 · branch-5 | 3113.227 ms | 220.567 ms |
| 首次 · branch-70 | 3154.991 ms | 212.540 ms |
| 首次 · branch-105 | 3146.897 ms | 210.178 ms |
| 缓存 · branch-5 | 3108.888 ms | 0.072 ms |
| 缓存 · branch-70 | 3136.952 ms | 0.015 ms |
| 缓存 · branch-105 | 3088.867 ms | 0.010 ms |

缓存指标表示模型能在同一主执行器调用中发布页面，不是鼠标到屏幕的延迟或帧率，也不表示后台没有 Git 命令：稳定后的引用检查仍会执行，测试确认 tip 未变时不会重读历史页。该仓库不是大型真实项目，不据此宣称所有仓库流畅。

原始数据：[before](evidence/branch-preview-before.json)、[after](evidence/branch-preview-after.json)；运行日志：[before](evidence/branch-preview-before.log)、[after](evidence/branch-preview-after.log)。复现命令：

```sh
GITPICO_RUN_PREVIEW_BENCHMARK=1 \
GITPICO_PREVIEW_BENCHMARK_REPORT=/tmp/gitpico-preview.json \
swift test --filter branchPreviewPerformanceBenchmark
```

## 回归与交付

覆盖缓存同步命中与读取次数、外部移动 tip、刷新/写后失效、不同过滤/分页、快速导航、迟到错误/仓库切换、内存上限、详情取消恢复、嵌套 remote 名称的侧栏树；GitCore 覆盖固定 tip、分页、查询、第一父提交、合并/annotated tag、unborn、无效参数和读取取消。测试的 Git 写入仅发生在可销毁仓库。

- 完整原生 scheme 回归：249 项通过、0 失败、1 项按条件跳过（可选性能基准）。其中 GitCore 200 项、App 49 项。见 [完整日志](evidence/history-preview-native-tests.log)、[xcresult 摘要](evidence/history-preview-native-summary.json)。本机结果包 `.build/xcode/HistoryPreviewTests.xcresult`。
- 完整回归后补充了详情取消恢复、嵌套 remote 侧栏和 Git 写后缓存失效三个边缘用例及修正；最终源码重新 `build-for-testing`，完整 App target 52 项及读取取消 1 项共 53 项通过、0 失败、1 项性能基准按条件跳过。见 [最终构建](evidence/history-preview-final-build.log)、[最终专项日志](evidence/history-preview-final-native-tests.log)、[最终摘要](evidence/history-preview-final-native-summary.json)。本机结果包 `.build/xcode/HistoryPreviewFinalTests.xcresult`。两轮有重叠，不把 249 + 53 当作独立测试总数。
- 最终源码的 Git 写后失效、保留选择的详情重载和读取取消也经 [SwiftPM 定向检查](evidence/history-preview-last-fixes.log)通过；隔离性能基准单独启用运行并通过，未把常规跳过当作性能验证。
- 后台 `--verify` 构建、完整暂存及启动检查通过：[构建日志](evidence/history-preview-background-build.log)、[后台报告](evidence/history-preview-background-verification.json)。验证进程为禁止激活模式、不活跃、可见窗口 0；它没有结束已运行的 GitPico，报告写入后自身退出。
- 最终开发包位于 `dist/GitPico.app`，版本 **0.01 / 20261024230311**。原生产品与暂存包的全部文件和符号链接一致，[bundle 元数据](evidence/history-preview-bundle-metadata.json)、[签名验证](evidence/history-preview-signature.log)、[Mach-O 最低版本](evidence/history-preview-deployment-target.log)均通过。最低系统为 26.0，SDK 为 27.0。
- [静态检查](evidence/history-preview-static-checks.log)：19 个本轮源码/测试/脚本文件没有尾随空白问题，shell 语法检查通过。保留原有未跟踪项目内容，没有源码提交或发布。

## 验收边界

参考已有的本地 Tower 截图 `parity-tower-overview.png` 和 GitPico 对照图；没有新打开或激活 Tower、GitPico、Xcode 或浏览器窗口，没有前台鼠标/键盘验收。因此工具栏编译和路由覆盖不等同于实时像素、原生焦点、溢出菜单、浅色模式或实际绘制性能验收。

保持版本 0.01、最低 macOS 26.0。实际构建/测试主机为 macOS 27.0.1 / Xcode 27.1，不能代替 macOS 26 运行验收。完整 Tower 功能与交互一致性仍未达成。
