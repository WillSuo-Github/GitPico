# 分支切换、Stash 和合并后的增量刷新 — 2026-10-25

沿用既有 Tower 对照界面，本轮优化操作完成后的等待和状态衔接。全部写入在临时仓库执行，测试宿主禁止激活和显示窗口，没有进行前台鼠标或像素一致性验收。

## 刷新策略

| 操作 | 立即更新 | 保留或延迟 |
| --- | --- | --- |
| Checkout / Create and Checkout | 工作区、索引、HEAD、分支标记、必要的文件浏览、Undo、Stash 列表和自动恢复提示 | HEAD 变化才重读引用、有界历史和上游差异；无关管理数据按需读取 |
| Stash 保存、Snapshot、应用/Pop、重命名、删除/清空、创建分支、文件/块/行应用 | 工作区、索引、完整 Stash 列表、选中项和恢复提示 | HEAD 稳定时保留历史缓存；Stash 创建分支按实际 HEAD 变化升级 |
| Merge / Rebase / Cherry-Pick / Revert；Resolve / Continue / Abort | 工作区、冲突、操作状态、Undo、自动 Stash 恢复、需要的历史/分支信息 | Worktree、子模块、Flow 等管理数据失效后按页面/动作读取 |
| 自动 Stash 确认弹窗 | 把原操作的刷新策略传入 Stash / Do Not Stash 两条执行路径 | Pull/Sync、交互式 Rebase 等原本完整刷新的入口维持原策略 |

- 新的 `workingTree` 策略复用上一轮增量快照，不调用完整 `snapshot`、全历史计数或关联仓库管理扫描。Git status 仍枚举整个工作区；这是数据依赖范围的增量刷新，不宣称只扫描目标文件。
- 实际 HEAD 的分支名或哈希变化时，读取引用、最多 500 条历史、ahead/behind 和身份，并失效历史页，防止旧 HEAD 装饰继续显示。相同 HEAD 下的 Stash-only 写入、失败操作和 no-op merge 保留缓存；HEAD 和操作状态均未改变时也保留已有 Undo 状态。历史预览按当前 scope 在后台重新校验。
- Stash 列表和自动恢复提示在解除 busy 前更新。普通 Worktree/子模块/Flow 管理数据不挡住完成反馈；依赖它们的页面与操作仍沿用 session/epoch 保护和后端状态校验。
- 每次操作成功或拒绝后只执行一次所选刷新；刷新也失败时保留原始 Git 错误并补充刷新错误，不自动再跑完整 reload。失败 merge/apply 仍发布真实冲突状态，失败 Pop 保留 Stash。
- 从历史页进入冲突工作区时取消旧历史请求，清除不适用的搜索，更新列表并选中冲突文件。解决冲突、中止和继续均走增量路径；自动 Stash 的 waiting / needsReview 状态及时显示，恢复不会隐式重放已应用内容。
- Worktree 管理数据已标记失效时，旧占用提示不再直接阻止 Checkout；后端仍实时验证目标引用和真实 Worktree 占用。未失效的提示维持既有禁用说明。
- 没有增加新的 Undo 类型；Stash/Checkout 的统一 Undo 仍是既有清单缺口。

## 定向回归

`WorkingTreeRefreshTests.swift` 新增 12 项临时仓库回归：

- 同哈希不同分支及不同 tip 的切换，当前分支、历史与 clean 文件浏览更新。
- Stash 保存 staged/unstaged/untracked、重命名、恢复 index 的 Pop、Snapshot、删除和缓存保留。
- 单文件 Stash 应用、从 Stash 创建并切换分支。
- Pop 冲突后立即显示冲突且保留原 Stash。
- Merge 冲突、Abort、内置 Resolve、Continue、合并父提交与 Undo；从有搜索的历史页正确转入冲突工作区。
- Fast-forward 与 no-op merge，稳定 HEAD 保留历史缓存。
- 自动 Stash 后 Checkout 并恢复 index；Merge 暂停后显示 waiting，Abort 后恢复 staged 工作；恢复冲突保留 needsReview 和保存内容。
- Checkout 被本地修改拒绝后保留差异，自动 Stash 请求携带正确刷新范围。
- 注入刷新失败后只读一次，原始写入错误和刷新错误同时保留。
- 失效 Worktree 提示不误阻止切换，真实占用仍由后端拒绝。

[初始 11 项定向结果](evidence/working-tree-refresh-focused-final.log)；最终 12 项包含在下方完整原生测试中。初次全量测试期间进一步修正历史搜索选项向工作区的传播；最终源码重新构建并验证。

## 性能与最终验收

### 独立策略对比

使用本轮最终源码，在相同配置的两个独立临时仓库分别启用旧的完整刷新策略和新的增量策略。不是旧二进制与新二进制的 A/B。600 条初始提交、120 个 preview 分支，加 checkout-target、merge-source 和 main，共 123 个本地分支；JSON 的 `branches: 122` 表示 main 以外的额外分支数。另有 tracked.txt 和 2,000 个忽略文件。合并要求 clean 工作区，因此这里没有未跟踪文件干扰。

每种策略执行两轮 Checkout 往返、Stash Save、恢复 index 的 Pop、Fast-forward Merge。计时包含实际 Git 写入，从 `perform` 调用到 `operationTask` 完成、模型解除 busy；不是刷新单步耗时，也不包含屏幕绘制。Checkout 四个样本，其余各两个样本。独立运行期间未同时执行本轮构建或其他测试。

| 操作 | 完整刷新策略 | 增量刷新策略 | 平均缩短 |
| --- | ---: | ---: | ---: |
| Checkout | 2.368 s | 1.977 s | 16.5% |
| Stash Save | 2.402 s | 1.319 s | 45.1% |
| Stash Pop | 3.071 s | 1.977 s | 35.6% |
| Fast-forward Merge | 3.471 s | 3.052 s | 12.1% |

[完整策略数据](evidence/working-tree-refresh-before.json)、[日志](evidence/working-tree-refresh-before.log)；[增量策略数据](evidence/working-tree-refresh-after.json)、[日志](evidence/working-tree-refresh-after.log)；[汇总](evidence/working-tree-refresh-comparison.json)。两次 opt-in benchmark 均通过。Merge 的写入、恢复检查点和 Undo 记录仍有耗时，没有将其称为瞬时操作。

```sh
GITPICO_RUN_TREE_REFRESH_BENCHMARK=1 \
GITPICO_TREE_REFRESH_BENCHMARK_REPORT=/tmp/gitpico-tree-refresh.json \
swift test --filter workingTreeRefreshPerformanceBenchmark
```

添加 `GITPICO_TREE_REFRESH_BASELINE=1` 可选择完整策略。

### 原生测试

- 初次完整 scheme：GitCore **209 项全部通过**，App **85 通过、1 失败、5 条件跳过**。唯一失败是新增的历史搜索转入合并冲突用例：合并完成后旧历史 query 过滤掉了 snapshot 的提交。修正为转入工作区时恢复导航选项并清除不适用的搜索；对应路径的 [定向回归](evidence/working-tree-refresh-redirect-fix.log)通过。见 [首次结果摘要](evidence/working-tree-refresh-first-summary.json)、[分 target 结果](evidence/working-tree-refresh-first-test-tree.json)、[完整日志](evidence/working-tree-refresh-native-tests.log)。
- 最终源码重新原生 `build-for-testing`，并重跑完整 App target：**86 通过、0 失败、5 条件跳过**，包含本轮全部 12 项和既有暂存/预览/拖放/恢复回归。GitCore 本轮没有源码改动，采用前述 209 项通过结果；合计 **Core 209 + 最终 App 86 = 295 项通过**，不声称初次完整 scheme 全绿。见 [最终测试构建](evidence/working-tree-refresh-final-test-build.log)、[App 日志](evidence/working-tree-refresh-app-tests.log)、[摘要](evidence/working-tree-refresh-app-summary.json)、[测试树](evidence/working-tree-refresh-app-test-tree.json)。本机结果包分别在 `.build/xcode/WorkingTreeRefreshTests.xcresult` 和 `.build/xcode/WorkingTreeRefreshAppTests.xcresult`。
- 5 条件跳过分别是旧的暂存刷新基准、分支预览基准、历史/工作区组件离屏捕获和新的 working-tree 基准；本轮需要的新基准已按上述策略单独启用通过。其他 4 项 opt-in 检查本轮未开启。
- 原生结果仍记录 `com.willsuo.GitPico.drag` 未在宿主 Info.plist 导出的运行时警告；本轮未处理此独立问题，也不据后台测试宣称新的拖放视觉验收。

### 开发包与后台验证

- `dist/GitPico.app`：**0.01 / 20261025122418**，最低系统 **26.0**。执行 `./script/build_and_run.sh --verify` 完成构建、暂存和后台启动；[构建日志](evidence/working-tree-refresh-background-build.log)、[bundle 元数据](evidence/working-tree-refresh-bundle-metadata.json)。没有修改源 Info.plist、工程 Build Number 或营销版本。
- [后台报告](evidence/working-tree-refresh-background-verification.json)：GitPico `isActive: false`、`visibleWindows: 0`，验证 PID 已退出，没有停止用户已运行实例。未激活 Tower、Xcode、浏览器或 GitPico 窗口。
- 原生产物与暂存包的 12 个文件/符号链接条目一致；[11 个相关源码/测试指纹](evidence/working-tree-refresh-source-hashes.json)与已测试源码一致。另有 [空白检查](evidence/working-tree-refresh-static-checks.log)、[签名检查](evidence/working-tree-refresh-signature.log)、[Mach-O 最低系统](evidence/working-tree-refresh-deployment-target.log)。
- 没有提交、推送、Archive、发布或公证。保留整棵已有未跟踪项目内容。

## 验收边界

- 显式 Refresh、Fetch/Pull/Sync、迁移及其他管理写入仍可能使用完整校准。未把本轮提升推广到所有 Git 操作。
- 外部进程或任意钩子修改非 HEAD 的无关引用、配置时，不保证每次本地写入后全局同步；通过对应管理页面或显式 Refresh 校准。HEAD 前后检查也不构成跨进程原子事务。
- 当前 Debug、模型 busy 解除时间不等于屏幕绘制耗时或真实大型仓库承诺。没有前台焦点、鼠标菜单或逐像素 Tower 一致性验收。
- 最低系统保持 macOS 26.0；实际 macOS 27.0.1 / Xcode 27.1 的结果不能代替 macOS 26 runtime 验收。
