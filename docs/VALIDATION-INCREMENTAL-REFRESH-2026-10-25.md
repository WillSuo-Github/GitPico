# 暂存、取消暂存和提交后的增量刷新 — 2026-10-25

本轮不改已有 Tower 对照布局，专门移除写后等待完整仓库刷新的路径。全部测试在后台临时仓库执行，没有激活应用窗口。

## 刷新边界

| 触发 | 立即读取/更新 | 按需读取 |
| --- | --- | --- |
| 整文件、分块、逐行暂存/取消；已审核 Force Add | Git status、HEAD、操作状态、当前文件/side/差异；需要文件浏览时更新索引 flags 和条目 | 子模块索引状态、Workflow/LFS 设置 |
| Commit / Amend | 上述状态，加引用、最多 500 条已加载历史、上游 ahead/behind、身份和 Undo；清除受影响历史缓存 | Worktree、子模块、Stash、远程、组织和 Workflow |
| 管理页面/操作 | 读取它需要且已失效的数据，成功后清除该范围 dirty 标记 | 不读取无关范围 |
| 显式 Refresh、其他仓库管理写入 | 保留完整 reload 校准 | — |

- 索引写入保留稳定 HEAD 下的历史页和不可变提交详情缓存。失败写入也用增量路径重新同步真实状态，不自动退回全套扫描。外部 checkout/HEAD 改变会升级到头部/引用/历史更新，避免继续显示旧分支。
- 工作区 status 仍由 Git 枚举整个工作区，保留未选中文件和钩子产生的变更；“增量”按数据依赖域拆分，不声称只扫描被点击的路径。默认变更列表不枚举全部索引文件；全部文件/assume-unchanged 模式读取索引标志，忽略/策略相关浏览按需要重新枚举。
- 新文件从 untracked 到 staged、取消暂存、提交后变成 clean，仍保留正确 tracked/ignored/assume-unchanged/skip-worktree 信息。只读浏览不把忽略文件隐式加入 Stage All。
- HEAD 在状态读取前后核对，发生变化最多重试三次，持续变动则报告刷新错误。没有宣称与任意外部 Git 写入构成跨进程原子事务。
- Commit 刷新不调用完整 `snapshot`、全历史 `rev-list --count` 或 Worktree/Submodule/Flow 加载。历史超出已加载页时，`historyCountIsExact` 为 false，数量是已加载下界；完整校准仍可得到完整总数。
- 本地操作状态通过一次 Git administrative-directory 查询后检查 marker；使用当前 Worktree 的 Git 目录，避免错误读取主仓库的 MERGE/REBASE 状态。
- 模型按仓库 session / metadata epoch 接受结果；新写入或完整校准会使旧后台读取失效。需要管理数据的页面/动作按需读取，依赖读取失败时会提示错误，动作仍保留各自的预览/过时状态校验；Workflow 错误不会挡住独立的远程更新。

## 同仓库前后对比

独立临时仓库：600 条初始提交、120 个分支、2,000 个未跟踪文件，另有一个用于写入的 tracked 文件。两轮各执行 Stage → Unstage → Stage → Commit，取同类平均。计时从操作调用到 `operationTask` 完成且模型解除 busy，包含真实 Git 写入和所需刷新；之后另等当前差异任务，未把屏幕绘制或差异绘制延迟计作该指标。

| 操作 | 改动前 | 改动后 | 平均缩短 |
| --- | ---: | ---: | ---: |
| 暂存 | 3.033 s | 0.608 s | 79.9% |
| 取消暂存 | 3.114 s | 0.703 s | 77.4% |
| 提交 | 3.900 s | 2.205 s | 43.5% |

[before 数据](evidence/incremental-refresh-before.json)、[before 日志](evidence/incremental-refresh-before.log)、[after 数据](evidence/incremental-refresh-after.json)、[after 日志](evidence/incremental-refresh-after.log)。两次是相同 fixture/指标，普通 Debug 构建，不据此宣称真实大型仓库或 UI 帧率均已达标。

```sh
GITPICO_RUN_REFRESH_BENCHMARK=1 \
GITPICO_REFRESH_BENCHMARK_REPORT=/tmp/gitpico-refresh.json \
swift test --filter writeRefreshPerformanceBenchmark
```

## 定向验证

- [增量与延迟数据用例](evidence/incremental-refresh-focused-tests.log)：索引/历史缓存保留、不读损坏的无关 Undo 存储、提交 HEAD/引用/上游和有界历史、unborn/detached/外部 checkout、索引 flags/clean 新文件、linked Worktree 操作 marker、失败 index.lock 后同步、迟到旧 session 拒绝、按需更新 Worktree/Stash 和独立元数据失败。
- [忽略文件 Force Add](evidence/incremental-refresh-force-add.log)：已有审核计划执行后走索引增量路径，浏览从 ignored 更新成 tracked/staged。
- [按需读取失败反馈](evidence/incremental-refresh-metadata-failure.log)：损坏 Git Flow 数据保留错误/dirty 标记，远程仍刷新；依赖该范围的管理动作有错误反馈。
- [原交互回归](evidence/incremental-refresh-functional.log)：多选、逐行往返、稳定 HEAD 下历史缓存保留和提交成功/Undo 故障反馈维持。

## 最终原生结果和开发包

- 原生 `build-for-testing` 成功后执行完整 scheme：**283 项通过、0 失败、4 项按条件跳过**。其中 GitCore 209 项、App 74 项；原生宿主检查仍确认 prohibited activation、未激活、无可见窗口和真实 bundle 版本/最低系统值。见 [最终测试构建](evidence/incremental-refresh-final-test-build.log)、[完整日志](evidence/incremental-refresh-native-tests.log)、[xcresult 摘要](evidence/incremental-refresh-native-summary.json)、[分 target 结果](evidence/incremental-refresh-native-test-tree.json)。本机结果包 `.build/xcode/IncrementalRefreshTests.xcresult`。
- 四项常规 skip 是写后刷新基准、分支预览基准、历史行和工作区行离屏捕获；针对最终源码 [单独启用并全部通过](evidence/incremental-refresh-explicit-checks.log)。[最终写后基准](evidence/incremental-refresh-final-benchmark.json)是并行显式检查中的运行证明；前后比较表使用上面的独立 before/after 运行，不混用两种运行负载。
- 最终 `dist/GitPico.app`：**0.01 / 20261025010509**，最低系统仍为 26.0。原生产品与暂存包全部文件和符号链接相同，本轮 15 个源码/测试文件 SHA256 与已测试文件相符。见 [bundle 元数据](evidence/incremental-refresh-bundle-metadata.json)、[源码指纹](evidence/incremental-refresh-source-hashes.json)、[空白检查](evidence/incremental-refresh-static-checks.log)。
- [后台构建/验证](evidence/incremental-refresh-background-build.log)、[运行报告](evidence/incremental-refresh-background-verification.json)：GitPico isActive false、visibleWindows 0。报告当时前台为 macOS UserNotificationCenter，GitPico 没有激活；验证进程写完报告后已退出，未停止用户已运行实例。
- [签名](evidence/incremental-refresh-signature.log)及 [Mach-O 部署目标](evidence/incremental-refresh-deployment-target.log)通过，minos 26.0 / SDK 27.0。没有 Archive、分发、公证或前台验收。
- 保留既有未跟踪项目内容，没有源代码提交、推送或发布。


## 验收边界

其他仓库管理、切换分支、迁移、Stash 等写操作继续使用完整 reload，不把本轮速度提升推广到所有 Git 操作。非 HEAD 的无关引用/配置由外部进程或自定义钩子改变时，不保证在每次索引写入后立即全局同步；使用对应管理页面或显式 Refresh 校准。

沿用无窗口测试宿主与 `--verify`：不激活、不显示窗口，也不停止用户已运行实例。没有实际鼠标/键盘、菜单焦点或屏幕绘制帧率验收。版本固定 0.01，最低系统 26.0；实际 macOS 27.0.1 / Xcode 27.1 运行不能代替 macOS 26 验收。
